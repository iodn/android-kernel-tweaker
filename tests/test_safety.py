"""Regression tests using copied scripts and fake kernel nodes; no root required."""
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SHELL = shlex.split(os.environ.get('AKTUNE_TEST_SHELL', 'busybox sh'))


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='aktune-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mod = self.root / 'module'
        self.data = self.root / 'data'
        for source in [*REPO.glob('common/*.sh'), REPO / 'tweaks/daemon.sh']:
            dest = self.mod / source.relative_to(REPO)
            dest.parent.mkdir(parents=True, exist_ok=True)
            script = source.read_text()
            # Redirect every absolute kernel/device path into this fixture.
            script = re.sub(r'/(?:sys|proc|dev)/',
                            lambda match: str(self.root) + match.group(), script)
            if source.name == 'daemon.sh':
                assert script.endswith('main "$@"\n')
                script = script.removesuffix('main "$@"\n')
            dest.write_text(script)
        shutil.copy(REPO / 'common/config.default.props', self.mod / 'common')
        self.node('/proc/sys/kernel/random/boot_id', 'test-boot-1')
        self.node('/proc/self/mountinfo', '')
        (self.root / 'dev').mkdir(exist_ok=True)
        (self.root / 'dev/null').symlink_to('/dev/null')
        self.env = dict(os.environ, AKTUNE_DATA_DIR=str(self.data))

    def node(self, name, value):
        path = self.root / name.lstrip('/')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(str(value) + '\n')
        return path

    def read(self, name):
        return (self.root / name.lstrip('/')).read_text().strip()

    def run_sh(self, body, expected=0):
        runner = self.mod / 'tweaks/test-runner.sh'
        runner.write_text('. "${0%/*}/daemon.sh"\naktune_prepare_dirs\n' + body + '\n')
        result = subprocess.run(SHELL + [str(runner)], env=self.env, text=True,
                                capture_output=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout.strip()

    def config(self, text):
        self.data.mkdir(exist_ok=True)
        (self.data / 'config.props').write_text(text)

    def cpu(self, governor='schedutil', single=False):
        base = '/sys/devices/system/cpu/cpufreq/policy0'
        self.node(base + '/scaling_governor', governor)
        self.node(base + '/scaling_available_governors', 'interactive schedutil')
        self.node(base + '/cpuinfo_max_freq', 2000000)
        for name, value in ([('rate_limit_us', 10000)] if single else
                            [('up_rate_limit_us', 10000), ('down_rate_limit_us', 30000)]):
            self.node(base + '/schedutil/' + name, value)
        self.node(base + '/schedutil/iowait_boost_enable', 1)
        return self.root / base.lstrip('/')

    def test_write_helpers_do_not_clobber_caller_and_restore_first_value(self):
        node = self.node('/sys/test/value', 10)
        output = self.run_sh(f'''
p=policy-path; path=caller-path; cur=caller-value
write_node "{node}" 20 || exit 1
write_node "{node}" 30 || exit 2
printf '%s %s %s\\n' "$p" "$path" "$cur"
baseline_restore_node "{node}" || exit 3
cat "{node}"
''')
        self.assertEqual(output, 'policy-path caller-path caller-value\n10')
        log = (self.data / 'logs/aktune.log').read_text()
        self.assertLess(log.index('Try:'), log.index('Set:'))
        self.assertEqual(len((self.data / 'state/baseline.tsv').read_text().splitlines()), 1)

    def test_unreadable_or_empty_nodes_are_not_written(self):
        node = self.node('/sys/test/empty', '')
        self.run_sh(f'write_node "{node}" 20', expected=1)
        self.assertEqual(node.read_text(), '\n')

    def test_mismatch_is_failure_but_baseline_restore_is_allowed(self):
        node = self.node('/sys/test/value', 10)
        self.run_sh(f'''
read_node() {{
  local value
  value="$(cat "$1")"
  [ "$value" = 20 ] && value=21
  echo "$value"
}}
write_node "{node}" 20 && exit 1
blocked_has "{node}" || exit 2
write_node "{node}" 30 && exit 3
baseline_restore_node "{node}" || exit 4
''')
        self.assertEqual(node.read_text().strip(), '10')

    def test_bracketed_active_value_does_not_switch_scheduler(self):
        node = self.node('/sys/test/scheduler', 'none [mq-deadline] kyber')
        self.run_sh(f'write_node "{node}" mq-deadline')
        self.assertEqual(node.read_text().strip(), 'none [mq-deadline] kyber')
        self.assertEqual((self.data / 'state/baseline.tsv').read_text(), '')

    def test_config_validation_crlf_and_missing_final_newline(self):
        self.config('bad=1-2\r\nnegative=-1\noverflow=99999999999999\nzeroes=00008\nlast=42')
        output = self.run_sh('''
get_prop_int bad 7
get_prop_int negative 7
get_prop_int overflow 7
get_prop_int zeroes 7
get_prop_int last 7
get_prop_range last 7 0 40
''')
        self.assertEqual(output.splitlines(), ['7', '7', '7', '8', '42', '7'])

    def test_cpu_split_limits_restore_and_keep_iowait(self):
        cpu = self.cpu()
        output = self.run_sh(f'''
apply_schedutil_policy "{cpu}" little on
cat "{cpu}/schedutil/up_rate_limit_us" "{cpu}/schedutil/down_rate_limit_us"
apply_schedutil_policy "{cpu}" little off
cat "{cpu}/schedutil/up_rate_limit_us" "{cpu}/schedutil/down_rate_limit_us"
''')
        self.assertEqual(output.splitlines(), ['6000', '20000', '10000', '30000'])
        self.assertEqual((cpu / 'schedutil/iowait_boost_enable').read_text().strip(), '1')

    def test_cpu_single_limit_and_homogeneous_tier(self):
        cpu = self.cpu(single=True)
        output = self.run_sh(f'''
policy_tier "{cpu}" 2000000
apply_schedutil_policy "{cpu}" little on
cat "{cpu}/schedutil/rate_limit_us"
apply_schedutil_policy "{cpu}" little off
cat "{cpu}/schedutil/rate_limit_us"
''')
        self.assertEqual(output.splitlines(), ['little', '6000', '10000'])

    def test_vendor_governor_is_preserved(self):
        cpu = self.cpu('interactive')
        self.run_sh(f'apply_schedutil_policy "{cpu}" little on')
        self.assertEqual((cpu / 'scaling_governor').read_text().strip(), 'interactive')
        self.assertEqual((cpu / 'schedutil/up_rate_limit_us').read_text().strip(), '10000')

    def test_uclamp_units_and_all_topapp_paths_restore(self):
        native = self.node('/dev/stune/top-app/uclamp.min', 0)
        other = self.node('/dev/cpuset/top-app/uclamp.min', 64)
        v2 = self.node('/sys/fs/cgroup/top-app/cpu.uclamp.min', '0.00')
        maximum = self.node('/sys/fs/cgroup/top-app/cpu.uclamp.max', '60.00')
        output = self.run_sh(f'''
HAS_UCLAMP=1
apply_uclamp_profile on
cat "{native}" "{other}" "{v2}" "{maximum}"
apply_uclamp_profile off
cat "{native}" "{other}" "{v2}" "{maximum}"
''')
        self.assertEqual(output.splitlines(), ['128', '128', '12.50', '60.00',
                                               '0', '64', '0.00', '60.00'])

    def test_uclamp_does_not_lower_vendor_minimum(self):
        native = self.node('/dev/stune/top-app/uclamp.min', 256)
        v2 = self.node('/sys/fs/cgroup/top-app/cpu.uclamp.min', '30.00')
        self.run_sh('HAS_UCLAMP=1; apply_uclamp_profile on')
        self.assertEqual(native.read_text().strip(), '256')
        self.assertEqual(v2.read_text().strip(), '30.00')

    def test_gpu_uses_supported_frequencies_under_cap_and_restores(self):
        gpu = '/sys/class/devfreq/kgsl-3d0'
        self.node(gpu + '/available_frequencies', '600000000 400000000 200000000')
        self.node(gpu + '/max_freq', 400000000)
        self.node(gpu + '/min_freq', 200000000)
        self.node(gpu + '/governor', 'vendor-governor')
        self.config('gpu.tuning.enable=1\ngpu.min_freq_pct.on=60\n')
        self.run_sh('HAS_GPU_DEVFREQ=1; apply_gpu_profile on')
        self.assertEqual(self.read(gpu + '/min_freq'), '400000000')
        self.assertEqual(self.read(gpu + '/governor'), 'vendor-governor')
        self.run_sh('HAS_GPU_DEVFREQ=1; apply_gpu_profile off')
        self.assertEqual(self.read(gpu + '/min_freq'), '200000000')
        self.config('gpu.tuning.enable=1\ngpu.min_freq_pct.on=90\n')
        self.run_sh('HAS_GPU_DEVFREQ=1; apply_gpu_profile on')
        self.assertEqual(self.read(gpu + '/min_freq'), '200000000')

    def test_gpu_does_not_invent_frequency_without_table(self):
        gpu = self.root / 'sys/class/devfreq/kgsl-3d0'
        self.node('/sys/class/devfreq/kgsl-3d0/max_freq', 600000000)
        self.node('/sys/class/devfreq/kgsl-3d0/min_freq', 200000000)
        self.run_sh(f'gpu_set_minfreq_percent "{gpu}" 50')
        self.assertEqual((gpu / 'min_freq').read_text().strip(), '200000000')

    def storage(self):
        disk = self.root / 'sys/devices/mmc/mmcblk0'
        partition = disk / 'mmcblk0p25'
        self.node('/sys/devices/mmc/mmcblk0/mmcblk0p25/partition', 25)
        dm0 = self.root / 'sys/devices/virtual/block/dm-0'
        dm1 = self.root / 'sys/devices/virtual/block/dm-1'
        for dev in (disk, dm0, dm1):
            (dev / 'queue').mkdir(parents=True, exist_ok=True)
            for key, value in [('read_ahead_kb', '256'), ('scheduler', 'none [cfq]'),
                               ('nomerges', '0'), ('nr_requests', '128'), ('iostats', '1')]:
                (dev / 'queue' / key).write_text(value + '\n')
        for parent, child in [(dm0, dm1), (dm1, partition)]:
            (parent / 'slaves').mkdir()
            (parent / 'slaves' / child.name).symlink_to(child)
        devblock = self.root / 'sys/dev/block'
        devblock.mkdir(parents=True)
        (devblock / '253:0').symlink_to(dm0)
        (devblock / '179:25').symlink_to(partition)
        self.node('/proc/self/mountinfo', '1 0 253:0 / /data rw - ext4 /dev/block/dm-0 rw\n'
                  '2 0 179:25 / / rw - ext4 /dev/block/by-name/system rw')
        return [dev / 'queue' for dev in (disk, dm0, dm1)]

    def test_storage_resolves_stacked_dm_partition_and_deduplicates(self):
        queues = self.storage()
        output = self.run_sh('_io_collect_targets').split()
        self.assertCountEqual(output, [str(q) for q in queues])
        self.config('io.read_ahead.enable=1\nio.read_ahead_kb.on=128\n')
        self.run_sh('apply_io_profile on')
        for q in queues:
            self.assertEqual((q / 'read_ahead_kb').read_text().strip(), '128')
            self.assertEqual((q / 'scheduler').read_text().strip(), 'none [cfq]')
            self.assertEqual((q / 'nomerges').read_text().strip(), '0')
            self.assertEqual((q / 'iostats').read_text().strip(), '1')
        self.run_sh('apply_io_profile off')
        for q in queues:
            self.assertEqual((q / 'read_ahead_kb').read_text().strip(), '256')

    def test_legacy_preset_does_not_enable_risky_writes(self):
        self.cpu('interactive')
        self.storage()
        self.config('gpu.min_freq_pct.on=40\nio.nomerges.on=2\nio.nr_requests.on=256\n'
                    'io.iostats.disable=1\nsched.upmigrate.on=75\ntouchboost.ms=200\n')
        risky = {
            '/proc/sys/kernel/sched_latency_ns': '10000000',
            '/proc/sys/kernel/sched_upmigrate': '95',
            '/proc/sys/kernel/printk': '6 6 1 7',
            '/proc/sys/vm/min_free_kbytes': '67584',
            '/proc/sys/vm/dirty_ratio': '20',
            '/proc/sys/vm/page-cluster': '3',
            '/sys/block/zram0/comp_algorithm': '[lz4] lzo',
            '/sys/class/devfreq/kgsl-3d0/governor': 'vendor',
            '/sys/class/devfreq/kgsl-3d0/min_freq': '200000000',
            '/sys/module/cpu_boost/parameters/input_boost_ms': '40',
        }
        for path, value in risky.items():
            self.node(path, value)
        self.run_sh('HAS_CPUFREQ=1; HAS_GPU_DEVFREQ=1; apply_profile on; apply_profile off')
        for path, value in risky.items():
            self.assertEqual(self.read(path), value, path)
        self.assertEqual((self.data / 'state/baseline.tsv').read_text(), '')
        self.assertFalse((self.data / 'state/apply_pending').exists())

    def test_boot_change_discards_old_baselines_and_blocklist(self):
        self.run_sh('aktune_prepare_boot_state')
        state = self.data / 'state'
        (state / 'baseline.tsv').write_text('/sys/example\t100\n')
        (state / 'blocked.tsv').write_text('/sys/example\tfailed\n')
        self.node('/proc/sys/kernel/random/boot_id', 'test-boot-2')
        self.run_sh('aktune_prepare_boot_state')
        self.assertEqual((state / 'baseline.tsv').read_text(), '')
        self.assertEqual((state / 'blocked.tsv').read_text(), '')
        self.assertEqual((state / 'baseline.previous.tsv').read_text(), '/sys/example\t100\n')

    def test_previous_boot_interrupted_profile_prevents_new_writes(self):
        cpu = self.cpu()
        self.run_sh('printf "older-boot on\\n" > "$STATE_DIR/apply_pending"')
        self.run_sh('main --oneshot', expected=1)
        self.assertEqual((cpu / 'schedutil/up_rate_limit_us').read_text().strip(), '10000')
        self.assertIn('Tuning paused:', (self.data / 'logs/aktune.log').read_text())
        self.assertTrue((self.data / 'state/apply_pending').exists())

    def test_single_writer_lock_rejects_second_owner(self):
        self.run_sh('acquire_daemon_lock || exit 1; acquire_daemon_lock && exit 2; exit 0')
        self.assertEqual(list((self.data / 'state').glob('daemon.*.lock')), [])

    def test_explicit_sleep_beats_stale_display_state(self):
        self.run_sh('''
dumpsys() { echo 'mInteractive=false Display Power: state=ON'; }
is_screen_on && exit 1
exit 0
''')

    def test_stable_idle_uses_one_probe_and_no_confirmation_sleep(self):
        counter = self.node('/probe-count', '')
        self.run_sh(f'''
last_effective=off
is_screen_on() {{ echo probe >> "{counter}"; return 1; }}
sleep() {{ echo unexpected-sleep >> "{counter}"; }}
stable_screen_state
''')
        self.assertEqual(counter.read_text().strip(), 'probe')

    def test_boot_timeout_is_failure(self):
        self.run_sh('''
getprop() { echo 0; }
akt_sleep() { :; }
wait_boot_completed 2
''', expected=1)

    def test_full_profile_cycles_restore_all_enabled_controls(self):
        self.cpu()
        self.storage()
        self.node('/dev/stune/top-app/uclamp.min', 0)
        self.node('/sys/fs/cgroup/top-app/cpu.uclamp.min', '0.00')
        self.node('/sys/class/devfreq/kgsl-3d0/governor', 'vendor')
        self.node('/sys/class/devfreq/kgsl-3d0/available_frequencies', '600000000 400000000 200000000')
        self.node('/sys/class/devfreq/kgsl-3d0/max_freq', 600000000)
        self.node('/sys/class/devfreq/kgsl-3d0/min_freq', 200000000)
        self.node('/sys/module/cpu_boost/parameters/input_boost_ms', 40)
        self.node('/sys/kernel/cpu_input_boost/enabled', 0)
        self.node('/sys/devices/system/cpu/cpufreq/boost', 0)
        self.node('/proc/sys/kernel/sched_boost', 0)
        self.config('gpu.tuning.enable=1\ngpu.min_freq_pct.on=60\n'
                    'io.read_ahead.enable=1\nio.read_ahead_kb.on=128\n'
                    'touchboost.enable=1\ncpu.cpufreq_boost.enable=1\nsched.boost.enable=1\n')
        files = [path for name in ('sys', 'proc', 'dev')
                 for path in (self.root / name).rglob('*')
                 if path.is_file() and not path.is_symlink()]
        before = {path: path.read_text() for path in files}
        self.run_sh('''
HAS_CPUFREQ=1; HAS_UCLAMP=1; HAS_GPU_DEVFREQ=1
apply_profile on
apply_profile off
apply_profile on
apply_profile off
''')
        self.assertEqual({path: path.read_text() for path in files}, before)
        self.assertFalse((self.data / 'state/apply_pending').exists())

    def test_modes_and_framebuffer_state(self):
        self.node('/sys/class/graphics/fb0/blank', 4)
        output = self.run_sh('''
effective_state_from_mode aggressive
effective_state_from_mode strict
effective_state_from_mode auto
''')
        self.assertEqual(output.splitlines(), ['on', 'off', 'off'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
