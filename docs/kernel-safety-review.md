# Kernel tuning investigation — 2026-09-08

The objective is responsive interactive use with minimal extra idle power. The changes in v2.2 remove unvalidated global overrides and repair concrete shell/interface errors. They have not established a device-level performance improvement or identified the exact Mi A1 crash.

## What the report establishes

The supplied Mi A1 / LineageOS 20 logs show AUTO and AGGRESSIVE applying the ON profile and rebooting soon afterward. STRICT reaches later tuning stages. The last recorded successful ON write is `sched_latency_ns=6000000`.

In v2.1, the following blocks execute next: touchboost, GPU, I/O, and memory. Logging occurs after successful writes, so the next attempted write is absent if it crashes the kernel. A delayed fault caused by an earlier write also remains possible. The timestamps alone cannot distinguish a scheduler fault, GPU driver fault, watchdog reset, or another cause.

`UCLAMP=0` in this report means the cgroup bug found during review does **not** explain this particular device's crash. No panic stack, pstore record, exact kernel build, or device trace was supplied.

The inspected [LineageOS msm8953 device configuration](https://github.com/LineageOS/android_device_xiaomi_msm8953-common/blob/lineage-20/BoardConfigCommon.mk) points to its msm8953 kernel tree. The inspected [LineageOS qcom msm8953 lineage-20 kernel](https://github.com/LineageOS/android_kernel_qcom_msm8953/blob/lineage-20/Makefile) is a 4.9 tree. This does not identify the reporter's exact installed kernel or commit; obtain `uname -a` and the ROM build fingerprint before matching a fault to source.

## Findings and changes

| Finding | Consequence | Change |
| --- | --- | --- |
| Shared shell variables in sysfs helpers overwrite caller variables such as `p` and `cur` | A policy path can change midway through CPU tuning | Scope write/read/restore helper variables locally |
| cgroup v2 receives 0–1024 clamp values | The interface expects percentages; values can be rejected or misinterpreted | Convert only top-app minimum requests and preserve maximum clamps |
| OFF leaves some ON clamps and CPU settings active | Performance requests can survive screen-off | Restore all controls modified by the current implementation |
| Detached timed boost writers survive their caller | An old writer can reapply a minimum after OFF | Remove asynchronous boost workers; serialize tuning |
| GPU percentage multiplication overflows in mksh's arithmetic | Requested GPU floors can be calculated incorrectly | Divide before multiplication and test with mksh |
| GPU governors are selected by availability/name | Availability does not establish driver compatibility | Keep the vendor governor; require opt-in for supported minimum frequencies |
| Generic scheduler timings and migration thresholds are forced | Different vendor schedulers have different assumptions | Preserve vendor values |
| Memory reserves and writeback settings are chosen without device measurements | They can conflict with the ROM's memory policy | Preserve VM, reclaim, compaction, and ZRAM configuration |
| ON sets `nomerges=2`, switches scheduler, changes depth, and disables I/O statistics | Changes trade throughput, latency, and observability without workload evidence | Preserve these controls; leave read-ahead as an optional experiment |
| Storage discovery assumes one device-mapper layer and whole-disk names | Encrypted `/data` backed by eMMC partitions can be missed | Resolve mount major/minor identifiers, partitions, and backing-device chains |
| Baselines persist indefinitely | Old values can be replayed after a ROM/kernel update | Scope baselines and blocked nodes to the current boot |
| Logging follows writes and kernel console logging is suppressed | The potentially failing operation may be invisible | Keep kernel logging and log stages/attempts before writes |

Linux documents cgroup v2 minima/maxima as percentages, with maximum clamps limiting minimum requests. AKTune now requests a modest top-app minimum without changing global or background clamps. Android also has its own vendor-overridable task profiles, which the module leaves in place. Sources: [Linux cgroup v2 CPU interface](https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu-interface-files), [AOSP cgroup abstraction](https://source.android.com/docs/core/perf/cgroups).

The Qualcomm `msm-adreno-tz` governor assumes an Adreno-specific extended device profile and manages private data and partner-governor events. This supports avoiding generic governor substitution; it is not evidence that this governor caused the reported reset. Source: [LineageOS governor implementation](https://github.com/LineageOS/android_kernel_qcom_msm8953/blob/lineage-20/drivers/devfreq/governor_msm_adreno_tz.c).

Linux describes `min_free_kbytes` as an allocator watermark input and warns about unsuitable settings. Dirty-byte and dirty-ratio controls also interact: writing one disables its counterpart. RAM capacity alone does not justify replacing a vendor's reserve or writeback policy. Source: [Linux VM sysctls](https://docs.kernel.org/admin-guide/sysctl/vm.html).

`nomerges=2` disables request merging. Queue depth and completion affinity control different latency/throughput tradeoffs, while read-ahead is the amount of speculative file data fetched. No single setting is an established speed improvement for every eMMC/UFS workload. Preserving vendor defaults is the starting point for measurement. Source: [Linux block queue controls](https://www.kernel.org/doc/html/v5.15/block/queue-sysfs.html).

Schedutil is driven by scheduler utilization, includes I/O-wait boosting, and has a rate limit to control governor overhead. AKTune adjusts exposed rate limits only when schedutil is already selected and restores them at screen-off; it does not disable I/O-wait boosting. Source: [Linux CPU frequency scaling](https://docs.kernel.org/admin-guide/pm/cpufreq.html#schedutil).

## Screen-off battery behavior

AUTO releases AKTune's CPU, top-app, optional GPU, touchboost, and read-ahead requests on the confirmed OFF transition. It preserves Android's treatment of background work rather than imposing extremely slow CPU ramp rates or caps on background groups. Stable polls no longer run the second confirmation probe, and profiles are not continually rewritten.

The daemon uses ordinary sleeps and does not acquire a wakelock. It still has polling overhead while Android is awake, and a poll/confirmation can delay its response to a screen transition. Existing vendor controls remain responsible for immediate touch and wake responsiveness.

Android already applies Doze and app standby optimizations. Preserving these mechanisms and removing a module's lingering boosts is a sound battery objective, but only a controlled comparison can establish whether AUTO consumes less energy than an unmodified ROM. Source: [AOSP power management](https://source.android.com/docs/core/power/mgmt).

## Collecting a crash report

If the affected device still reboots, disable AKTune in Magisk and reboot before attempting more tuning. Do not repeatedly force AGGRESSIVE to reproduce a crash without first preserving available evidence.

After the unexpected reboot, run these commands in a root shell. They only collect information locally. Some ROMs lack pstore or last_kmsg; a missing file is useful information too.

```sh
su
umask 077
report=/data/local/tmp/aktune-report
mkdir -p "$report"
uname -a > "$report/kernel.txt"
getprop ro.build.fingerprint > "$report/build.txt"
getprop ro.boot.bootreason > "$report/bootreason.txt"
getprop sys.boot.reason >> "$report/bootreason.txt"
cp -R /data/adb/aktune/logs "$report/"
cp -R /data/adb/aktune/state "$report/"
cp /data/adb/aktune/config.props "$report/"
cp -R /sys/fs/pstore "$report/" 2> "$report/pstore-copy-errors.txt"
cat /proc/last_kmsg > "$report/last_kmsg.txt" 2> "$report/last-kmsg-errors.txt"
dmesg > "$report/current-dmesg.txt" 2> "$report/dmesg-errors.txt"
```

Pstore/ramoops can preserve a previous kernel panic when the device kernel is configured for it. Current `dmesg` is from the new boot and cannot replace the previous panic log. Missing pstore data does not rule out a crash. Source: [Linux ramoops documentation](https://docs.kernel.org/admin-guide/ramoops.html).

Review logs before sharing them; they can contain device and application details. Include the exact module version, mode, charging state, whether the whole phone rebooted, and other active tuning modules.

The new `apply_pending` marker pauses tuning if a reboot interrupts profile application. It does not detect every crash, and ordinary writes may be lost during power failure. Preserve it with the logs. After reviewing the evidence and choosing to retry, remove `/data/adb/aktune/state/apply_pending`, then use the Action button or reboot.

## Validation and acceptance criteria

Host tests use isolated files and exercise write verification, restoration, config validation, native/v2 clamps, CPU governors and rate interfaces, mksh GPU arithmetic, GPU caps, stacked storage, legacy presets, boot-scoped state, mode selection, and the interrupted-profile guard. They do not emulate kernel driver side effects, SELinux, a Power HAL, or a real panic.

Before promoting this candidate to a stable release:

1. Start with AKTune disabled and measure repeatable app launches and scrolling. Record frame-time/jank metrics, device temperature, and battery conditions.
2. Reboot with the new default AUTO config. Repeat the same workload at comparable temperature and charge level; do not compare a cold run against a thermally throttled run.
3. Exercise repeated screen ON/OFF transitions, charging, calls, camera, music playback, notifications, and an active download with the screen off. Verify ON/OFF completion in logs and restoration of captured controls.
4. Compare several unplugged idle periods against the disabled-module baseline with the same radios, apps, and connectivity. Measure battery drain and suspend residency where the device exposes them. Expect normal measurement noise.
5. Test the Mi A1 first with optional GPU/touch/storage hooks disabled. Also test representative newer UCLAMP kernels and eMMC/UFS storage layouts. Acceptance requires no resets or new errors, working background services, no repeatable idle regression, and a repeatable responsiveness benefit on at least the claimed supported devices.
6. Enable at most one optional experiment per comparison. Retain it only if the measured benefit outweighs temperature, power, and latency costs.

There is no measured basis yet for claiming universal speed improvements, longer battery life than stock, or a confirmed fix for the Mi A1 reboot.
