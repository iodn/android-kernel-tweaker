# AKTune (Android Kernel Tweaker)

AKTune is an adaptive Magisk module that tunes common Android kernel/sysfs knobs to improve real-world responsiveness and UI smoothness while keeping idle behavior relaxed.

Unlike static "one profile 24/7" tuners, AKTune can run in multiple runtime modes and apply profiles dynamically in a safe, capability-aware way.

## Runtime modes (AUTO / AGGRESSIVE / STRICT)

AKTune supports **3 modes**, switchable anytime using Magisk's **Action** button:

- **AUTO** (default)
  - Screen **ON** → **Aggressive profile**
  - Screen **OFF** → **Strict profile**
  - This is the intended "fast when you use it, calm when you don't" behavior.

- **AGGRESSIVE**
  - Always runs the **Aggressive profile**
  - Ignores screen state

- **STRICT**
  - Always runs the **Strict profile**
  - Ignores screen state

### Switching modes (Magisk Action button)

AKTune includes an `action.sh` script for Magisk Manager.

Each tap cycles:

**AUTO → AGGRESSIVE → STRICT → AUTO**

The current mode is also printed clearly inside Magisk's output window and takes effect immediately (the daemon is restarted automatically).

## Key design goals

### Cross-device compatibility
Only touches nodes that exist on your device. No hardcoded SoC layouts.
Every time AKTune changes a sysfs/proc node for the first time, it saves the original value so it can restore it later.

### Configurable behavior (no code edits)
Users can tune behavior via:
`/data/adb/aktune/config.props`

### No overclocking / no thermal bypass
AKTune does not overclock beyond vendor limits and does not disable thermal throttling.

## Features

### Adaptive runtime profiles
Depending on the runtime mode:

- AUTO:
  - Detects interactive state (screen ON/OFF)
  - Applies **ON** profile when interactive
  - Applies **OFF** profile when idle
  - Uses debounce logic + stable-state confirmation to avoid rapid toggling

- AGGRESSIVE:
  - Forces interactive profile permanently

- STRICT:
  - Forces idle profile permanently

### Baseline capture + restore (uninstall-safe)
- When AKTune writes a node the first time, it stores the original value in a TSV database
- On uninstall, it restores those captured baseline values where possible

### Capability detection (only apply what exists)
AKTune checks for major subsystems and enables tuning blocks only if supported:

- CPUFreq: `/sys/devices/system/cpu/cpufreq`
- GPU devfreq: `/sys/class/devfreq`
- UCLAMP:
  - `/dev/stune/*/uclamp.*`
  - `/dev/cpuset/*/uclamp.*`
  - or cgroup v2 `cpu.uclamp.*`
- zswap: `/sys/module/zswap`
- zram: `/sys/block/zram0`
- MGLRU: `/sys/kernel/mm/lru_gen`
- Memory class: derived from `MemTotal` (small / medium / large)

### Persistent logging
All activity is logged to:

`/data/adb/aktune/logs/aktune.log`

## What AKTune tunes (high level)

AKTune can tune these categories depending on kernel support:

1. Scheduler + overhead sysctls  
   e.g. perf events CPU time limit, schedstats disable, timer migration

2. CPU governor selection + schedutil ramp behavior  
   Cluster-tier-aware settings (little / big / prime)

3. UCLAMP + optional broad boost
   Prioritizes top-app / foreground and can enable sched_boost when configured

4. Migration thresholds  
   Moves tasks to bigger cores sooner while interactive

5. Touch/input boost hooks (OEM dependent)  
   Enables short boost windows for better touch-to-frame responsiveness

6. GPU devfreq governor + minimum freq bias  
   Keeps GPU from dropping too low during UI bursts (interactive-biased)

7. I/O queue tuning  
   Read-ahead, iostats toggle, rq_affinity, scheduler preference

8. Memory (VM) tuning  
   Dirty ratios, cache pressure, compaction, stat interval, optional min_free_kbytes

9. cpuset placement (if supported)  
   Protects foreground performance by restricting background groups to little CPUs

10. Networking latency flags (optional)  
   tcp_low_latency and optional timestamps disable

## Installation

Install like a standard Magisk module:

1. Flash the AKTune zip in Magisk
2. Reboot

Magisk **v20.4+** recommended.

## Lifecycle (what runs when)

### 1) `post-fs-data.sh` (early boot)
AKTune uses this stage to:

- Create `/data/adb/aktune` directories
- Ensure script permissions are correct
- Create baseline/log/config files if missing

No heavy tuning is applied here.

### 2) `service.sh` (boot completed)
After Android finishes booting:

- Waits for `sys.boot_completed=1`
- Starts the adaptive daemon in the background: `tweaks/daemon.sh`

The daemon becomes the main runtime tuning engine.

### 3) Optional oneshot script: `aktune.sh`
`aktune.sh` is a one-time tuning pass (conservative defaults).
It is included mainly for manual usage / debugging.

You can run it manually (optional):

```sh
su -c sh /data/adb/modules/aktune/aktune.sh
````

## Configuration

### Main config file (runtime)

AKTune reads configuration from:

`/data/adb/aktune/config.props`

This file is persistent across reboots and module updates.

### Shipped preset (module default)

The module ships a preset:

`common/config.default.props`

On first run, AKTune will populate `/data/adb/aktune/config.props` from this preset if the config file is missing/empty.


## Preset included: "Aggressive ON / Strict OFF"

This preset is designed so that:

* **Interactive behavior (ON profile)** is strongly optimized for responsiveness
* **Idle behavior (OFF profile)** becomes more strict / battery oriented

Preset file: `common/config.default.props`

Example values included in the preset:

* Daemon cadence:

  * `daemon.interval_sec`
  * `daemon.debounce_ms`
  * `daemon.boost_ms`

* UCLAMP behavior:

  * `uclamp.top.min.interactive`
  * `uclamp.top.min.boost`

* CPU schedutil ramp limits:

  * `cpu.schedutil.on.{tier}.up/down`
  * `cpu.schedutil.off.{tier}.up/down`

* Broad boost controls:

  * `cpu.cpufreq_boost.enable`
  * `sched.boost.enable`

* Migration thresholds:

  * `sched.upmigrate.on/off`
  * `sched.downmigrate.on/off`
  * `sched.group_upmigrate.on/off`
  * `sched.group_downmigrate.on/off`

* I/O behavior:

  * `io.read_ahead_kb.on/off`
  * `io.nr_requests.on/off`
  * `io.nomerges.on/off`
  * `io.rq_affinity.enable/value`
  * `io.iostats.disable`

* Network:

  * `net.tcp_low_latency.enable`
  * `net.tcp_timestamps.disable`

* Touch boost:

  * `touchboost.ms`

* GPU min floor:

  * `gpu.min_freq_pct.on/off`


## How to change behavior (user workflow)

### Edit config

Open and modify:

`/data/adb/aktune/config.props`

Example:

```sh
su
vi /data/adb/aktune/config.props
```

### Apply changes

The daemon reads values at runtime, but the safest workflow is:

* Edit config
* Reboot

### Restore preset quickly

To re-apply the shipped preset:

```sh
su -c cp /data/adb/modules/aktune/common/config.default.props /data/adb/aktune/config.props
su -c reboot
```


## Files and state (persistent)

AKTune stores persistent state under:

* Logs:

  * `/data/adb/aktune/logs/aktune.log`
* Baseline DB (for restore on uninstall):

  * `/data/adb/aktune/state/baseline.tsv`
* Daemon PID:

  * `/data/adb/aktune/state/daemon.pid`
* Forced runtime mode:

  * `/data/adb/aktune/state/force_mode`

### `baseline.tsv` format

A simple TSV database:

```
<path> <original_value>
```

This allows best-effort restore on uninstall.

## Logging (how to verify it's working)

Log file:

`/data/adb/aktune/logs/aktune.log`

You should see entries such as:

* Capability detection summary
* Mode state changes: `MODE: auto` / `MODE: aggressive` / `MODE: strict`
* Profile transitions:

  * `PROFILE: ON`
  * `PROFILE: OFF`
* Successful writes: `Set: <path> = <value>`
* Write failures (if blocked by kernel/SELinux)
* "Write verify mismatch" warnings for bracketed sysfs formats (handled safely)

To inspect the last lines:

```sh
su -c tail -n 200 /data/adb/aktune/logs/aktune.log
```

## Uninstall behavior

On uninstall, AKTune runs:

`uninstall.sh`

It performs:

* Baseline restore from `baseline.tsv`
* Optional cleanup of AKTune state directory (currently enabled)

This makes removal best-effort clean, even if the module touched dozens of nodes.

## Expectations

AKTune is intentionally performance-focused during interactive usage.

Depending on device/kernel, you may observe:

* Higher peak temperatures under long interactive sessions
* Faster battery drain during active use
* Improved touch response and smoother UI bursts

AKTune does NOT:

* Overclock CPU/GPU beyond vendor maximums
* Disable thermal throttling
* Patch Android framework services (pure sysfs/proc tuning)

## Troubleshooting

### "It doesn't feel different"

* Your kernel may not expose common tuning nodes
* Some OEM kernels ignore writes or lock them down

Check logs:

```sh
su -c tail -n 200 /data/adb/aktune/logs/aktune.log
```

### "Failed to write" in logs

Common reasons:

* Node exists but write is denied
* SELinux restrictions
* Kernel ignores the value

AKTune will mark problematic nodes and avoid repeated spam where possible.

### Daemon not running

Check:

```sh
su -c cat /data/adb/aktune/state/daemon.pid
su -c ps -A | grep -i daemon.sh
```

If needed, reboot (Magisk service will restart it).

## Build

`build.sh` produces:

* `AKTune-v2.0.zip`

Example:

```sh
./build.sh
```

## Quick summary: why it feels fast

* CPU ramps faster (schedutil tuning + tier awareness)
* top-app gets priority (UCLAMP clamps, with optional sched_boost)
* touch triggers short boosts (input/touchboost hooks)
* GPU doesn't drop too low (min floor during interactive)
* background interference reduced (cpuset + clamps)
* idle mode turns it all back down (AUTO/STRICT)

That combination reduces "Android jitter" on most modern kernels.

## More Apps by KaijinLab!

| App                                                               | What it does                                                                   |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **[IR Blaster](https://github.com/iodn/android-ir-blaster)**      | Control and test infrared functionality for compatible devices.                |
| **[USBDevInfo](https://github.com/iodn/android-usb-device-info)** | Inspect USB device details and behavior to understand what's really connected. |
| **[GadgetFS](https://github.com/iodn/gadgetfs)**          | Experiment with USB gadget functionality (hardware-adjacent, low-level).       |
| **[TapDucky](https://github.com/iodn/tap-ducky)**                  | A security/testing tool for controlled keystroke injection workflows.          |
| **[HIDWiggle](https://github.com/iodn/hid-wiggle)**                | A mouse jiggler built with USB gadget functionalities.           
| **[AKTune (Android Kernel Tweaker)](https://github.com/iodn/android-kernel-tweaker)**                | Adaptive Android kernel auto-tuner for CPU/GPU/scheduler/memory/I-O. (Magisk Module).|
