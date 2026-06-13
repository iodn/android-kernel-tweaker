#!/system/bin/sh
# AKTune adaptive daemon

MODDIR="${0%/*}/.."
export AKTUNE_MODDIR="$MODDIR"

. "$MODDIR/common/util.sh"
. "$MODDIR/common/sysfs.sh"
. "$MODDIR/common/detect.sh"

brestore() {
  baseline_restore_node "$1" >/dev/null 2>&1 || true
}

now_ms() {
  if [ -r /proc/uptime ]; then
    read -r up _ < /proc/uptime 2>/dev/null

    sec="${up%%.*}"
    frac="${up#*.}"

    # Pad to at least 3 digits
    frac3="${frac}000"

    # Keep first 3 chars of frac3
    case "$frac3" in
      ???*)
        rest="${frac3#???}"
        [ -n "$rest" ] && frac3="${frac3%$rest}"
        ;;
      *)
        frac3="000"
        ;;
    esac

    # Force base-10 to avoid octal issues with leading zeros
    echo $((sec * 1000 + 10#$frac3))
    return 0
  fi

  echo 0
  return 0
}

sleep_ms() {
  ms="$1"
  sec=$((ms / 1000))
  rem=$((ms % 1000))

  case "$rem" in
    [0-9]) rem="00$rem" ;;
    [0-9][0-9]) rem="0$rem" ;;
    *) : ;;
  esac

  echo "${sec}.${rem}"
}

MODE_FILE_DEFAULT="$STATE_DIR/force_mode"

read_forced_mode() {
  mf="${1:-$MODE_FILE_DEFAULT}"
  m="$(read_first_line "$mf" 2>/dev/null)"
  m="$(akt_trim_ws "$m")"
  [ -n "$m" ] || m="auto"

  case "$m" in
    auto|aggressive|strict) echo "$m" ;;
    *) echo "auto" ;;
  esac
}

get_policies() {
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] && echo "$p"
  done
}

get_policy_max_freq() {
  f=""
  if [ -e "$1/cpuinfo_max_freq" ]; then
    read -r f < "$1/cpuinfo_max_freq" 2>/dev/null
  fi
  echo "$f"
}

get_max_all_freq() {
  max=0
  for p in $(get_policies); do
    f="$(get_policy_max_freq "$p")"
    case "$f" in
      ""|*[!0-9]*) continue ;;
    esac
    [ "$f" -gt "$max" ] && max="$f"
  done
  echo "$max"
}

policy_tier() {
  p="$1"
  max_all="$2"
  f="$(get_policy_max_freq "$p")"

  case "$f" in
    ""|*[!0-9]*) echo "little"; return 0 ;;
  esac

  little_th=$((max_all * 60 / 100))
  big_th=$((max_all * 85 / 100))

  if [ "$f" -le "$little_th" ]; then
    echo "little"
  elif [ "$f" -le "$big_th" ]; then
    echo "big"
  else
    echo "prime"
  fi
}

apply_schedutil_policy() {
  p="$1"
  tier="$2"
  mode="$3"

  gov="$p/scaling_governor"
  av="$p/scaling_available_governors"

  [ -e "$gov" ] || return 0

  if [ -e "$av" ]; then
    avail="$(read_node "$av")"
    case " $avail " in
      *" schedutil "*)
        write_node "$gov" "schedutil"
        ;;
    esac
  fi

  cur="$(read_node "$gov")"
  cur="$(akt_trim_ws "$cur")"
  [ "$cur" = "schedutil" ] || return 0

  su="$p/schedutil"
  [ -d "$su" ] || return 0

  if [ "$mode" = "on" ]; then
    up="$(get_prop_int "cpu.schedutil.on.$tier.up" 3000)"
    down="$(get_prop_int "cpu.schedutil.on.$tier.down" 15000)"
    write_node_if_exists "$su/iowait_boost_enable" "1"
  else
    up="$(get_prop_int "cpu.schedutil.off.$tier.up" 60000)"
    down="$(get_prop_int "cpu.schedutil.off.$tier.down" 20000)"
    write_node_if_exists "$su/iowait_boost_enable" "0"
  fi

  write_node_if_exists "$su/up_rate_limit_us" "$up"
  write_node_if_exists "$su/down_rate_limit_us" "$down"
}

apply_cpufreq_boost() {
  mode="$1"
  en="$(get_prop_bool cpu.cpufreq_boost.enable 0)"
  v="0"
  [ "$mode" = "on" ] && [ "$en" -eq 1 ] && v="1"

  write_node_if_exists "/sys/devices/system/cpu/cpufreq/boost" "$v"
  write_node_if_exists "/sys/module/cpufreq_boost/parameters/boost" "$v"
}

apply_cpu_profile() {
  mode="$1"
  [ "$HAS_CPUFREQ" -eq 1 ] || return 0

  max_all="$(get_max_all_freq)"

  for p in $(get_policies); do
    tier="$(policy_tier "$p" "$max_all")"
    apply_schedutil_policy "$p" "$tier" "$mode"
  done

  apply_cpufreq_boost "$mode"
}

cg_find_group() {
  g="$1"

  if [ -d "/sys/fs/cgroup/$g" ]; then
    echo "/sys/fs/cgroup/$g"
    return 0
  fi

  for a in /sys/fs/cgroup/*; do
    [ -d "$a" ] || continue

    if [ -d "$a/$g" ]; then
      echo "$a/$g"
      return 0
    fi

    for b in "$a"/*; do
      [ -d "$b" ] || continue
      if [ -d "$b/$g" ]; then
        echo "$b/$g"
        return 0
      fi
      for c in "$b"/*; do
        [ -d "$c" ] || continue
        if [ -d "$c/$g" ]; then
          echo "$c/$g"
          return 0
        fi
      done
    done
  done

  return 1
}

uclamp_write_group() {
  grp="$1"
  maxv="$2"
  minv="$3"
  boosted="$4"
  lat="$5"

  [ -d "$grp" ] || return 0

  if [ -e "$grp/uclamp.max" ] || [ -e "$grp/uclamp.min" ]; then
    write_node_if_exists "$grp/uclamp.max" "$maxv"
    write_node_if_exists "$grp/uclamp.min" "$minv"
    write_node_if_exists "$grp/uclamp.boosted" "$boosted"
    write_node_if_exists "$grp/uclamp.latency_sensitive" "$lat"
    return 0
  fi

  if [ -e "$grp/cpu.uclamp.max" ] || [ -e "$grp/cpu.uclamp.min" ]; then
    write_node_if_exists "$grp/cpu.uclamp.max" "$maxv"
    write_node_if_exists "$grp/cpu.uclamp.min" "$minv"
    return 0
  fi

  return 0
}

apply_uclamp_profile() {
  mode="$1"
  [ "$HAS_UCLAMP" -eq 1 ] || return 0

  inter_min="$(get_prop_int uclamp.top.min.interactive 128)"

  if [ "$mode" = "on" ]; then
    uclamp_write_group "/dev/stune/top-app" "1024" "$inter_min" "1" "1"
    uclamp_write_group "/dev/stune/foreground" "1024" "0" "0" "0"
    uclamp_write_group "/dev/stune/background" "512" "0" "0" "0"
    uclamp_write_group "/dev/stune/system-background" "384" "0" "0" "0"
    uclamp_write_group "/dev/cpuset/top-app" "1024" "$inter_min" "1" "1"

    cg_top="$(cg_find_group top-app)"
    if [ -n "$cg_top" ]; then
      uclamp_write_group "$cg_top" "1024" "$inter_min" "0" "0"
    fi

    if [ "$(get_prop_bool sched.boost.enable 0)" -eq 1 ]; then
      write_node_if_exists "/proc/sys/kernel/sched_boost" "1"
    else
      write_node_if_exists "/proc/sys/kernel/sched_boost" "0"
    fi
    set_sysctl "kernel/sched_util_clamp_min_rt_default" "0"
    set_sysctl "kernel/sched_util_clamp_min" "$inter_min"
  else
    uclamp_write_group "/dev/stune/top-app" "768" "0" "0" "0"

    cg_top="$(cg_find_group top-app)"
    if [ -n "$cg_top" ]; then
      uclamp_write_group "$cg_top" "768" "0" "0" "0"
    fi

    write_node_if_exists "/proc/sys/kernel/sched_boost" "0"
    set_sysctl "kernel/sched_util_clamp_min" "0"
  fi
}

apply_migration_thresholds() {
  mode="$1"
  if [ "$mode" = "on" ]; then
    set_sysctl "kernel/sched_upmigrate" "$(get_prop_int sched.upmigrate.on 75)"
    set_sysctl "kernel/sched_downmigrate" "$(get_prop_int sched.downmigrate.on 55)"
    set_sysctl "kernel/sched_group_upmigrate" "$(get_prop_int sched.group_upmigrate.on 85)"
    set_sysctl "kernel/sched_group_downmigrate" "$(get_prop_int sched.group_downmigrate.on 65)"
  else
    set_sysctl "kernel/sched_upmigrate" "$(get_prop_int sched.upmigrate.off 95)"
    set_sysctl "kernel/sched_downmigrate" "$(get_prop_int sched.downmigrate.off 75)"
    set_sysctl "kernel/sched_group_upmigrate" "$(get_prop_int sched.group_upmigrate.off 98)"
    set_sysctl "kernel/sched_group_downmigrate" "$(get_prop_int sched.group_downmigrate.off 80)"
  fi
}

apply_sched_latency_tunables() {
  mode="$1"
  if [ "$mode" = "on" ]; then
    set_sysctl "kernel/sched_migration_cost_ns" "20000"
    set_sysctl "kernel/sched_min_granularity_ns" "800000"
    set_sysctl "kernel/sched_wakeup_granularity_ns" "1000000"
    set_sysctl "kernel/sched_latency_ns" "6000000"
  else
    set_sysctl "kernel/sched_migration_cost_ns" "70000"
    set_sysctl "kernel/sched_min_granularity_ns" "1200000"
    set_sysctl "kernel/sched_wakeup_granularity_ns" "2000000"
    set_sysctl "kernel/sched_latency_ns" "12000000"
  fi
}

apply_kernel_overhead_profile() {
  mode="$1"

  if [ "$mode" = "on" ]; then
    set_sysctl "kernel/sched_autogroup_enabled" "0"
    set_sysctl "kernel/sched_child_runs_first" "1"
    set_sysctl "kernel/perf_cpu_time_max_percent" "10"
    set_sysctl "kernel/sched_schedstats" "0"
    set_sysctl "kernel/timer_migration" "0"
    set_sysctl "kernel/sched_min_task_util_for_colocation" "0"
    write_node_if_exists "/proc/sys/kernel/printk" "0 0 0 0"
    write_node_if_exists "/proc/sys/kernel/printk_devkmsg" "off"
  else
    brestore "/proc/sys/kernel/sched_autogroup_enabled"
    brestore "/proc/sys/kernel/sched_child_runs_first"
    brestore "/proc/sys/kernel/perf_cpu_time_max_percent"
    brestore "/proc/sys/kernel/sched_schedstats"
    brestore "/proc/sys/kernel/timer_migration"
    brestore "/proc/sys/kernel/sched_min_task_util_for_colocation"
    brestore "/proc/sys/kernel/printk"
    brestore "/proc/sys/kernel/printk_devkmsg"
  fi

  write_node_if_exists "/sys/module/workqueue/parameters/power_efficient" "1"
}

apply_touchboost() {
  mode="$1"
  ms="$(get_prop_int touchboost.ms 150)"

  if [ "$mode" = "on" ]; then
    write_node_if_exists "/sys/module/msm_performance/parameters/touchboost" "1"
    write_node_if_exists "/sys/kernel/msm_performance/touchboost" "1"
    write_node_if_exists "/sys/module/cpu_boost/parameters/input_boost_ms" "$ms"
    write_node_if_exists "/sys/kernel/cpu_input_boost/input_boost_ms" "$ms"
    write_node_if_exists "/sys/kernel/cpu_input_boost/enabled" "1"
    write_node_if_exists "/sys/devices/system/cpu/cpu_boost/input_boost_ms" "$ms"
  else
    write_node_if_exists "/sys/module/msm_performance/parameters/touchboost" "0"
    write_node_if_exists "/sys/kernel/msm_performance/touchboost" "0"
    write_node_if_exists "/sys/module/cpu_boost/parameters/input_boost_ms" "0"
    write_node_if_exists "/sys/kernel/cpu_input_boost/input_boost_ms" "0"
    write_node_if_exists "/sys/kernel/cpu_input_boost/enabled" "0"
    write_node_if_exists "/sys/devices/system/cpu/cpu_boost/input_boost_ms" "0"
  fi
}

gpu_nodes_iter() {
  for d in /sys/class/devfreq/*; do
    [ -d "$d" ] || continue
    [ -e "$d/governor" ] || continue
    name="${d##*/}"
    case "$name" in
      *gpu*|*GPU*|*kgsl*|*KGSL*|*mali*|*Mali*|*adreno*|*Adreno*)
        echo "$d"
        ;;
    esac
  done

  [ -d /sys/class/kgsl/kgsl-3d0/devfreq ] && echo "/sys/class/kgsl/kgsl-3d0/devfreq"
}

_gpu_scan_freq_tokens() {
  d="$1"
  target="$2"
  min=0
  max=0
  best=0
  af="$d/available_frequencies"

  if [ ! -e "$af" ]; then
    echo "0 0 0"
    return 0
  fi

  while IFS= read -r line; do
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    for x in "$@"; do
      case "$x" in
        ""|*[!0-9]*) continue ;;
      esac
      if [ "$min" -eq 0 ] || [ "$x" -lt "$min" ]; then
        min="$x"
      fi
      [ "$x" -gt "$max" ] && max="$x"
      if [ "$x" -ge "$target" ]; then
        if [ "$best" -eq 0 ] || [ "$x" -lt "$best" ]; then
          best="$x"
        fi
      fi
    done
  done < "$af"

  echo "$min $max $best"
}

gpu_set_minfreq_percent() {
  d="$1"
  pct="$2"
  minnode="$d/min_freq"

  [ -e "$minnode" ] || return 0

  case "$pct" in
    ""|*[!0-9]*) return 0 ;;
  esac
  [ "$pct" -gt 0 ] || return 0

  bounds="$(_gpu_scan_freq_tokens "$d" 0)"
  set -f
  # shellcheck disable=SC2086
  set -- $bounds
  set +f
  min_sup="$1"
  max_sup="$2"

  if [ "$max_sup" -gt 0 ]; then
    target=$((max_sup * pct / 100))
    [ "$target" -lt "$min_sup" ] && target="$min_sup"

    pick="$(_gpu_scan_freq_tokens "$d" "$target")"
    set -f
    # shellcheck disable=SC2086
    set -- $pick
    set +f
    best="$3"

    [ "$best" -gt 0 ] || best="$target"
    write_node_if_exists "$minnode" "$best"
    return 0
  fi

  if [ -e "$d/max_freq" ]; then
    mx=""
    read -r mx < "$d/max_freq" 2>/dev/null
    case "$mx" in
      ""|*[!0-9]*) return 0 ;;
    esac
    [ "$mx" -gt 0 ] || return 0
    v=$((mx * pct / 100))
    [ "$v" -gt 0 ] || return 0
    write_node_if_exists "$minnode" "$v"
  fi
}

apply_gpu_profile() {
  mode="$1"
  [ "$HAS_GPU_DEVFREQ" -eq 1 ] || return 0

  pct_on="$(get_prop_int gpu.min_freq_pct.on 45)"
  pct_off="$(get_prop_int gpu.min_freq_pct.off 0)"

  for d in $(gpu_nodes_iter); do
    gov="$d/governor"
    [ -e "$gov" ] || continue

    if [ "$mode" = "on" ]; then
      if [ -e "$d/available_governors" ]; then
        write_one_of "$gov" "msm-adreno-tz" "simple_ondemand" "bw_hwmon" "ondemand" "interactive"
      fi
      [ "$pct_on" -gt 0 ] && gpu_set_minfreq_percent "$d" "$pct_on"
    else
      if [ "$pct_off" -gt 0 ]; then
        gpu_set_minfreq_percent "$d" "$pct_off"
      else
        brestore "$d/min_freq"
      fi
      brestore "$d/governor"
    fi
  done
}

mount_dev_for_mp() {
  mp="$1"
  [ -r /proc/mounts ] || return 1

  while IFS= read -r dev mnt rest; do
    [ "$mnt" = "$mp" ] || continue
    echo "${dev##*/}"
    return 0
  done < /proc/mounts

  return 1
}

io_blacklisted() {
  case "$1" in
    ""|loop*|ram*|zram*) return 0 ;;
  esac
  return 1
}

_io_add_target() {
  dev="$1"
  [ -n "$dev" ] || return 0
  [ -d "/sys/block/$dev/queue" ] || return 0
  io_blacklisted "$dev" && return 0

  case " $IO_TARGETS " in
    *" $dev "*) return 0 ;;
  esac

  IO_TARGETS="${IO_TARGETS:-}${IO_TARGETS:+ }$dev"
}

_io_collect_targets() {
  IO_TARGETS=""

  for mp in /data /; do
    dev="$(mount_dev_for_mp "$mp")"

    case "$dev" in
      dm-*)
        for s in /sys/block/"$dev"/slaves/*; do
          [ -e "$s" ] || continue
          _io_add_target "${s##*/}"
        done
        ;;
      *)
        _io_add_target "$dev"
        for s in /sys/block/"$dev"/slaves/*; do
          [ -e "$s" ] || continue
          _io_add_target "${s##*/}"
        done
        ;;
    esac
  done

  echo "$IO_TARGETS"
}

apply_io_profile() {
  mode="$1"

  ra_on="$(get_prop_int io.read_ahead_kb.on 256)"
  ra_off="$(get_prop_int io.read_ahead_kb.off 128)"
  nr_on="$(get_prop_int io.nr_requests.on 256)"
  nr_off="$(get_prop_int io.nr_requests.off 128)"
  nm_on="$(get_prop_int io.nomerges.on 2)"
  nm_off="$(get_prop_int io.nomerges.off 0)"
  rq_en="$(get_prop_bool io.rq_affinity.enable 1)"
  rq_val="$(get_prop_int io.rq_affinity.value 2)"
  ios_dis="$(get_prop_bool io.iostats.disable 1)"

  for dev in $(_io_collect_targets); do
    q="/sys/block/$dev/queue"
    [ -d "$q" ] || continue

    [ "$ios_dis" -eq 1 ] && write_node_if_exists "$q/iostats" "0"
    write_node_if_exists "$q/add_random" "0"

    if [ "$mode" = "on" ]; then
      write_node_if_exists "$q/read_ahead_kb" "$ra_on"
      write_node_if_exists "$q/nomerges" "$nm_on"
      write_node_if_exists "$q/nr_requests" "$nr_on"
      if [ -e "$q/rq_affinity" ] && [ "$rq_en" -eq 1 ]; then
        write_node_if_exists "$q/rq_affinity" "$rq_val"
      fi
    else
      write_node_if_exists "$q/read_ahead_kb" "$ra_off"
      write_node_if_exists "$q/nomerges" "$nm_off"
      write_node_if_exists "$q/nr_requests" "$nr_off"
      if [ -e "$q/rq_affinity" ] && [ "$rq_en" -eq 1 ]; then
        write_node_if_exists "$q/rq_affinity" "1"
      fi
    fi

    [ -e "$q/scheduler" ] && write_one_of "$q/scheduler" "none" "mq-deadline" "deadline"
  done
}

calc_min_free_kbytes() {
  mb="${MEM_TOTAL_MB:-0}"
  case "$mb" in
    ""|*[!0-9]*) echo ""; return 0 ;;
  esac
  [ "$mb" -gt 0 ] || { echo ""; return 0; }

  if [ "$mb" -le 4096 ]; then
    echo "16384"
  elif [ "$mb" -le 8192 ]; then
    echo "24576"
  else
    echo "32768"
  fi
}

zram_can_change_algo() {
  [ -e /sys/block/zram0/disksize ] || return 1
  ds=""
  read -r ds < /sys/block/zram0/disksize 2>/dev/null
  [ "$ds" = "0" ] && return 0
  return 1
}

apply_mem_profile() {
  mode="$1"

  write_node_if_exists "/proc/sys/vm/page-cluster" "0"

  if [ "$mode" = "on" ]; then
    write_node_if_exists "/proc/sys/vm/vfs_cache_pressure" "50"
    write_node_if_exists "/proc/sys/vm/dirty_ratio" "15"
    write_node_if_exists "/proc/sys/vm/dirty_background_ratio" "5"
    write_node_if_exists "/proc/sys/vm/stat_interval" "10"
    write_node_if_exists "/proc/sys/vm/compaction_proactiveness" "10"
    write_node_if_exists "/proc/sys/vm/dirty_writeback_centisecs" "300"
    write_node_if_exists "/proc/sys/vm/dirty_expire_centisecs" "1500"
    mfk="$(calc_min_free_kbytes)"
    [ -n "$mfk" ] && write_node_if_exists "/proc/sys/vm/min_free_kbytes" "$mfk"
  else
    write_node_if_exists "/proc/sys/vm/vfs_cache_pressure" "80"
    write_node_if_exists "/proc/sys/vm/dirty_ratio" "20"
    write_node_if_exists "/proc/sys/vm/dirty_background_ratio" "10"
    write_node_if_exists "/proc/sys/vm/stat_interval" "20"
    write_node_if_exists "/proc/sys/vm/compaction_proactiveness" "20"
    write_node_if_exists "/proc/sys/vm/dirty_writeback_centisecs" "500"
    write_node_if_exists "/proc/sys/vm/dirty_expire_centisecs" "2000"
    brestore "/proc/sys/vm/min_free_kbytes"
  fi

  if [ "$HAS_ZRAM" -eq 1 ]; then
    if zram_can_change_algo; then
      if [ "$mode" = "on" ]; then
        write_node_if_exists "/sys/block/zram0/comp_algorithm" "lz4"
      else
        write_node_if_exists "/sys/block/zram0/comp_algorithm" "lzo-rle"
      fi
    else
      log_i "ZRAM: skip comp_algorithm (zram active)"
    fi
  fi
}

apply_net_profile() {
  mode="$1"

  if [ "$(get_prop_bool net.tcp_low_latency.enable 1)" -eq 1 ]; then
    if [ "$mode" = "on" ]; then
      write_node_if_exists "/proc/sys/net/ipv4/tcp_low_latency" "1"
    else
      brestore "/proc/sys/net/ipv4/tcp_low_latency"
    fi
  fi

  if [ "$(get_prop_bool net.tcp_timestamps.disable 0)" -eq 1 ]; then
    if [ "$mode" = "on" ]; then
      write_node_if_exists "/proc/sys/net/ipv4/tcp_timestamps" "0"
    else
      brestore "/proc/sys/net/ipv4/tcp_timestamps"
    fi
  fi
}

apply_cpuset_profile() {
  return 0
}

apply_profile() {
  mode="$1"
  if [ "$mode" = "on" ]; then
    log_i "PROFILE: ON"
  else
    log_i "PROFILE: OFF"
  fi

  apply_kernel_overhead_profile "$mode"
  apply_cpu_profile "$mode"
  apply_uclamp_profile "$mode"
  apply_migration_thresholds "$mode"
  apply_sched_latency_tunables "$mode"
  apply_touchboost "$mode"
  apply_gpu_profile "$mode"
  apply_io_profile "$mode"
  apply_mem_profile "$mode"
  apply_net_profile "$mode"
  apply_cpuset_profile "$mode"
}

contains() {
  hay="$1"
  needle="$2"
  case "$hay" in
    *"$needle"*) return 0 ;;
  esac
  return 1
}

is_screen_on_sysfs() {
  for f in /sys/class/graphics/fb0/blank /sys/class/graphics/fb1/blank; do
    [ -e "$f" ] || continue
    v=""
    read -r v < "$f" 2>/dev/null
    case "$v" in
      0) return 0 ;;
      1|2|4) return 1 ;;
    esac
  done

  for bl in /sys/class/backlight/*; do
    [ -d "$bl" ] || continue
    if [ -e "$bl/bl_power" ]; then
      p=""
      read -r p < "$bl/bl_power" 2>/dev/null
      [ "$p" = "0" ] && return 0
    fi
  done

  return 2
}

is_screen_on() {
  is_screen_on_sysfs
  r="$?"

  [ "$r" = "0" ] && return 0
  [ "$r" = "1" ] && return 1

  out="$(dumpsys power 2>/dev/null)"
  contains "$out" "mInteractive=true" && return 0
  contains "$out" "Display Power: state=ON" && return 0

  out2="$(dumpsys display 2>/dev/null)"
  contains "$out2" "mState=ON" && return 0

  return 1
}

stable_screen_state() {
  if is_screen_on; then
    s1="on"
  else
    s1="off"
  fi

  sleep 1

  if is_screen_on; then
    s2="on"
  else
    s2="off"
  fi

  [ "$s1" = "$s2" ] && echo "$s1" || echo ""
}

set_topapp_min_all_bases() {
  val="$1"

  [ -d "/dev/stune/top-app" ] && write_node_if_exists "/dev/stune/top-app/uclamp.min" "$val"
  [ -d "/dev/cpuset/top-app" ] && write_node_if_exists "/dev/cpuset/top-app/uclamp.min" "$val"

  cg_top="$(cg_find_group top-app)"
  [ -n "$cg_top" ] && write_node_if_exists "$cg_top/cpu.uclamp.min" "$val"
}

run_boost_async() {
  boost_min="$1"
  inter_min="$2"
  boost_ms="$3"

  (
    set_topapp_min_all_bases "$boost_min"
    sleep "$(sleep_ms "$boost_ms")"
    set_topapp_min_all_bases "$inter_min"
  ) &
}

effective_state_from_mode() {
  fm="$1"
  case "$fm" in
    aggressive) echo "on" ;;
    strict) echo "off" ;;
    auto|*) stable_screen_state ;;
  esac
}

main() {
  aktune_prepare_dirs
  rotate_logs_if_needed
  detect_platform

  interval="$(get_prop_int daemon.interval_sec 8)"
  debounce_ms="$(get_prop_int daemon.debounce_ms 1200)"
  boost_min="$(get_prop_int uclamp.top.min.boost 160)"
  inter_min="$(get_prop_int uclamp.top.min.interactive 128)"
  boost_ms="$(get_prop_int daemon.boost_ms 2200)"

  case "$interval" in
    ""|*[!0-9]*) interval="8" ;;
    0) interval="8" ;;
  esac

  last_effective=""
  last_change_ts=0
  last_forced=""

  forced="$(read_forced_mode)"
  st="$(effective_state_from_mode "$forced")"

  if [ -n "$st" ]; then
    log_i "MODE: $forced (initial)"
    apply_profile "$st"
    last_effective="$st"
    last_change_ts="$(now_ms)"
    last_forced="$forced"
    [ "$st" = "on" ] && run_boost_async "$boost_min" "$inter_min" "$boost_ms"
  fi

  while true; do
    now="$(now_ms)"
    forced="$(read_forced_mode)"

    if [ "$forced" != "$last_forced" ]; then
      log_i "MODE: changed $last_forced -> $forced"
      st="$(effective_state_from_mode "$forced")"
      if [ -n "$st" ]; then
        apply_profile "$st"
        last_effective="$st"
        last_change_ts="$now"
        [ "$st" = "on" ] && run_boost_async "$boost_min" "$inter_min" "$boost_ms"
      fi
      last_forced="$forced"
      sleep "$interval"
      continue
    fi

    if [ "$forced" = "auto" ]; then
      st="$(stable_screen_state)"
      if [ -n "$st" ] && [ "$st" != "$last_effective" ]; then
        dt=$((now - last_change_ts))
        if [ "$dt" -ge "$debounce_ms" ]; then
          log_i "AUTO: screen -> $st"
          apply_profile "$st"
          last_effective="$st"
          last_change_ts="$now"
          [ "$st" = "on" ] && run_boost_async "$boost_min" "$inter_min" "$boost_ms"
        fi
      fi
    fi

    sleep "$interval"
  done
}

main
