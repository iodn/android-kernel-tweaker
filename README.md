# AKTune (Android Kernel Tweaker)

AKTune is an adaptive Magisk module for common Android kernel/sysfs controls. It aims to improve interactive responsiveness and release its performance requests when the screen turns off, allowing the device's existing idle and power management to operate.


## Runtime modes

Use Magisk's **Action** button to cycle **AUTO > AGGRESSIVE > STRICT > AUTO**.

| Mode | Screen ON | Screen OFF |
| --- | --- | --- |
| AUTO (default) | Interactive tuning | Restore values captured before tuning |
| AGGRESSIVE | Interactive tuning | Interactive tuning |
| STRICT | Restore captured values | Restore captured values |

Use **AUTO** for adaptive performance and idle battery behavior. AGGRESSIVE deliberately keeps interactive requests active even with the screen off. STRICT releases AKTune's requests; it does not force slower CPU speeds or restrict background tasks.

Mode changes apply on the next daemon poll, with confirmation of screen transitions. The default interval is eight seconds. The Action button keeps the running daemon alive to avoid overlapping writes.

## What is tuned

| Control | Interactive behavior | Screen OFF in AUTO / STRICT |
| --- | --- | --- |
| CPU | Adjust bounded rate limits only when the vendor already selected `schedutil`; supports split and single rate-limit interfaces | Restore captured rate limits |
| Top-app CPU clamp | Raise the minimum to the configured target when supported; preserve higher vendor minima and all maximum clamps | Restore each changed top-app minimum |
| GPU | Optional minimum frequency from the device's supported table, subject to its current explicit maximum | Restore the captured minimum |
| Storage | Optional read-ahead experiment on mounted devices and their backing queues | Restore captured read-ahead |
| Vendor boost hooks | Explicit opt-in | Restore captured values |

GPU governor switching, scheduler migration/latency overrides, global CPU clamp limits, fixed memory reserves, VM writeback changes, ZRAM reconfiguration, I/O scheduler switching, forced queue depth, disabled request merging, and kernel log suppression have been removed.

The module keeps CPU/GPU maximum frequencies and thermal controls intact. It leaves CPU placement, memory reclaim, Doze, notifications, and background services to Android. Existing CPU governors, I/O-wait boosting, disk statistics, and disk request merging are preserved.

Removing AKTune's requests at screen-off can reduce its additional idle power use. This does not establish a battery-life improvement over the stock ROM, which already manages power. On a kernel without supported controls, the module may make few or no changes.

## Install or upgrade

1. Build or obtain the module ZIP and install it through Magisk.
2. Reboot before testing. A reboot is required when upgrading from v2.0/v2.1 to clear the removed legacy tweaks.
3. Keep AUTO selected and optional experiments disabled for the first test.

Configuration persists at `/data/adb/aktune/config.props`. New GPU, touchboost, and read-ahead enable flags default to disabled even if an older config contains their old numerical values. Removed keys are ignored; other existing supported values are retained.

To adopt all new defaults, back up your config, copy the shipped preset, then reboot:

```sh
su
cp /data/adb/aktune/config.props /data/adb/aktune/config.props.backup
cp /data/adb/modules/aktune/common/config.default.props /data/adb/aktune/config.props
reboot
```

## Configuration

See [common/config.default.props](common/config.default.props) for supported settings and ranges. Edit the persistent copy, then reboot to ensure a consistent test.

- `daemon.interval_sec`: polling interval, 2–300 seconds; default 8.
- `daemon.debounce_ms`: minimum interval between automatic transitions; default 1200.
- `uclamp.top.min.interactive`: 0–1024; default 128. Converted to percentage units for cgroup v2.
- `cpu.schedutil.on.{little,big,prime}.{up,down}`: microseconds, 500–1000000. CPU tiers are frequency-based heuristics; homogeneous policies use the little preset.
- `gpu.tuning.enable=1` and `gpu.min_freq_pct.on`: optional supported GPU floor. Both must be configured for a nonzero floor.
- `io.read_ahead.enable=1` and `io.read_ahead_kb.on`: optional read-ahead, 0–512 KiB. Measure app launch and storage behavior before retaining a change.
- `touchboost.enable`, `cpu.cpufreq_boost.enable`, `sched.boost.enable`: optional vendor hooks, disabled by default.
- `net.tcp_low_latency.enable`, `net.tcp_timestamps.disable`: legacy experiments, disabled in the new preset. These are not a general networking performance recommendation.

Legacy `daemon.boost_ms`, `uclamp.top.min.boost`, CPU OFF-rate settings, migration thresholds, GPU OFF floors, and all I/O settings except the read-ahead controls above are ignored. Timed asynchronous boosts were removed because they could outlive screen-off or a daemon restart.

## State, logging, and recovery

State is stored under `/data/adb/aktune`:

- `logs/aktune.log`: kernel identification, mode/profile transitions, stages, attempted writes (`Try:`), verified writes (`Set:`), and failures.
- `state/baseline.tsv`: original values captured before the first change in this boot.
- `state/baseline.previous.tsv`: the previous baseline database, kept for investigation.
- `state/blocked.tsv`: rejected or mismatched writes, skipped for the rest of this boot; baseline restoration is still attempted.
- `state/daemon.pid` and a boot-specific lock: enforce one tuning writer, including manual oneshot runs.
- `state/apply_pending`: a profile that started but did not finish.

Baselines and blocked nodes reset for each boot, so an old ROM/kernel's values are not replayed after an update. Restoration is best-effort: vendor services can also change these controls, and the kernel may reject a restore.

If a new boot finds an unfinished profile from an older boot, tuning pauses. This is a limited reboot guard, not proof of a kernel crash. Power loss during application can also trigger it; crashes after profile completion are outside its coverage. Writes to the log and marker are not guaranteed to survive sudden power loss.


To inspect activity:

```sh
su -c 'tail -n 100 /data/adb/aktune/logs/aktune.log'
```

## Lifecycle and manual use

`post-fs-data.sh` prepares directories and permissions. `service.sh` waits for Android boot completion, then starts `tweaks/daemon.sh`. Profiles are applied only on state/mode transitions. Stable screen states need one probe per poll; transitions receive a second confirmation. Dumpsys fallbacks use timeouts, and the daemon does not acquire a wakelock.

`aktune.sh` performs one interactive tuning pass through the same guarded implementation. It refuses to compete with a running daemon. AUTO is the normal workflow; a manual oneshot does not monitor subsequent screen-off events.


## More Apps by KaijinLab!

| App                                                               | What it does                                                                   |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **[IR Blaster](https://github.com/iodn/android-ir-blaster)**      | Control and test infrared functionality for compatible devices.                |
| **[USBDevInfo](https://github.com/iodn/android-usb-device-info)** | Inspect USB device details and behavior to understand what's really connected. |
| **[GadgetFS](https://github.com/iodn/gadgetfs)**          | Experiment with USB gadget functionality (hardware-adjacent, low-level).       |
| **[TapDucky](https://github.com/iodn/tap-ducky)**                  | A security/testing tool for controlled keystroke injection workflows.          |
| **[HIDWiggle](https://github.com/iodn/hid-wiggle)**                | A mouse jiggler built with USB gadget functionalities.           
| **[AKTune (Android Kernel Tweaker)](https://github.com/iodn/android-kernel-tweaker)**                | Adaptive Android kernel auto-tuner for CPU/GPU/scheduler/memory/I-O. (Magisk Module).|
