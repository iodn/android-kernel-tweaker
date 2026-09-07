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

  local other heterogeneous
  heterogeneous=0
  for other in $(get_policies); do
    [ "$(get_policy_max_freq "$other")" != "$f" ] && heterogeneous=1
  done
  [ "$heterogeneous" -eq 0 ] && { echo "little"; return 0; }

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
  local p tier mode cur su up down
  p="$1"
  tier="$2"
  mode="$3"
  su="$p/schedutil"
  if [ "$mode" = "off" ]; then
    brestore "$su/up_rate_limit_us"
    brestore "$su/down_rate_limit_us"
    brestore "$su/rate_limit_us"
    return 0
  fi

  # The vendor Power HAL may depend on its chosen governor.
  cur="$(read_node "$p/scaling_governor")"
  [ "$(akt_trim_ws "$cur")" = "schedutil" ] || return 0
  [ -d "$su" ] || return 0
  up="$(get_prop_range "cpu.schedutil.on.$tier.up" 6000 500 1000000)"
  down="$(get_prop_range "cpu.schedutil.on.$tier.down" 20000 500 1000000)"
  if [ -e "$su/up_rate_limit_us" ] && [ -e "$su/down_rate_limit_us" ]; then
    write_node "$su/up_rate_limit_us" "$up"
    write_node "$su/down_rate_limit_us" "$down"
  else
    write_node_if_exists "$su/rate_limit_us" "$up"
  fi
}

apply_cpufreq_boost() {
  local node
  for node in /sys/devices/system/cpu/cpufreq/boost /sys/module/cpufreq_boost/parameters/boost; do
    if [ "$1" = "on" ] && [ "$(get_prop_bool cpu.cpufreq_boost.enable 0)" -eq 1 ]; then
      write_node_if_exists "$node" "1"
    else
      brestore "$node"
    fi
  done
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

apply_uclamp_profile() {
  local inter_min node
  if [ "$HAS_UCLAMP" -eq 1 ]; then
    if [ "$1" = "on" ]; then
      inter_min="$(get_prop_range uclamp.top.min.interactive 128 0 1024)"
      set_topapp_min_all_bases "$inter_min"
    else
      for node in $(topapp_min_nodes); do brestore "$node"; done
    fi
  fi
  if [ "$1" = "on" ] && [ "$(get_prop_bool sched.boost.enable 0)" -eq 1 ]; then
    write_node_if_exists /proc/sys/kernel/sched_boost 1
  else
    brestore /proc/sys/kernel/sched_boost
  fi
}

apply_touchboost() {
  local node value ms
  ms="$(get_prop_range touchboost.ms 150 0 500)"
  for node in \
    /sys/module/msm_performance/parameters/touchboost \
    /sys/kernel/msm_performance/touchboost \
    /sys/module/cpu_boost/parameters/input_boost_ms \
    /sys/kernel/cpu_input_boost/input_boost_ms \
    /sys/kernel/cpu_input_boost/enabled \
    /sys/devices/system/cpu/cpu_boost/input_boost_ms; do
    if [ "$1" = "on" ] && [ "$(get_prop_bool touchboost.enable 0)" -eq 1 ]; then
      value=1
      case "$node" in */input_boost_ms) value="$ms" ;; esac
      write_node_if_exists "$node" "$value"
    else
      brestore "$node"
    fi
  done
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
  local d pct bounds min_sup max_sup target best cap current
  d="$1"
  pct="$2"
  case "$pct" in ""|*[!0-9]*) return 0 ;; esac
  [ "$pct" -gt 0 ] && [ "$pct" -le 100 ] || return 0
  [ -e "$d/min_freq" ] || return 0
  bounds="$(_gpu_scan_freq_tokens "$d" 0)"
  # Numeric tokens produced by _gpu_scan_freq_tokens.
  # shellcheck disable=SC2086
  set -- $bounds
  min_sup="$1"
  max_sup="$2"
  [ "$max_sup" -gt 0 ] || return 0
  # Preserve precision without overflowing mksh's 32-bit arithmetic.
  # shellcheck disable=SC2017
  target=$((max_sup / 100 * pct + max_sup % 100 * pct / 100))
  [ "$target" -lt "$min_sup" ] && target="$min_sup"
  bounds="$(_gpu_scan_freq_tokens "$d" "$target")"
  # Numeric tokens produced by _gpu_scan_freq_tokens.
  # shellcheck disable=SC2086
  set -- $bounds
  best="$3"
  [ "$best" -gt 0 ] || return 0
  cap="$(read_node "$d/max_freq")"
  case "$cap" in ""|*[!0-9]*) return 0 ;; esac
  # A zero devfreq limit means no explicit cap. Never raise max_freq.
  [ "$cap" -eq 0 ] || [ "$best" -le "$cap" ] || return 0
  current="$(read_node "$d/min_freq")"
  case "$current" in ""|*[!0-9]*) return 0 ;; esac
  [ "$best" -gt "$current" ] || return 0
  write_node "$d/min_freq" "$best"
}

apply_gpu_profile() {
  local d pct
  [ "$HAS_GPU_DEVFREQ" -eq 1 ] || return 0
  pct="$(get_prop_range gpu.min_freq_pct.on 0 0 100)"
  for d in $(gpu_nodes_iter); do
    if [ "$1" = "on" ] && [ "$(get_prop_bool gpu.tuning.enable 0)" -eq 1 ]; then
      gpu_set_minfreq_percent "$d" "$pct"
    else
      brestore "$d/min_freq"
    fi
  done
}

mount_dev_for_mp() {
  local _id _parent dev _root mp _rest
  while read -r _id _parent dev _root mp _rest; do
    [ "$mp" = "$1" ] || continue
    readlink -f "/sys/dev/block/$dev" 2>/dev/null
    return
  done < /proc/self/mountinfo
  return 1
}

io_blacklisted() {
  case "$1" in
    ""|loop*|ram*|zram*) return 0 ;;
  esac
  return 1
}

_io_add_target() {
  local path child dev
  path="$(readlink -f "$1" 2>/dev/null)"
  [ -d "$path" ] || return 0
  [ -e "$path/partition" ] && path="${path%/*}"
  dev="${path##*/}"
  io_blacklisted "$dev" && return 0
  case " $IO_VISITED " in *" $dev "*) return 0 ;; esac
  IO_VISITED="$IO_VISITED $dev"
  [ -d "$path/queue" ] && IO_TARGETS="$IO_TARGETS $path/queue"
  for child in "$path"/slaves/*; do
    [ -e "$child" ] && _io_add_target "$child"
  done
  return 0
}

_io_collect_targets() {
  local IO_TARGETS IO_VISITED mp path
  IO_TARGETS=""
  IO_VISITED=""
  for mp in /data /; do
    path="$(mount_dev_for_mp "$mp")"
    [ -n "$path" ] && _io_add_target "$path"
  done
  echo "$IO_TARGETS"
}

apply_io_profile() {
  local q ra
  ra="$(get_prop_range io.read_ahead_kb.on 128 0 512)"
  for q in $(_io_collect_targets); do
    if [ "$1" = "on" ] && [ "$(get_prop_bool io.read_ahead.enable 0)" -eq 1 ]; then
      write_node_if_exists "$q/read_ahead_kb" "$ra"
    else
      brestore "$q/read_ahead_kb"
    fi
    # Keep vendor scheduler, request merging/depth, affinity and accounting.
  done
}

apply_net_profile() {
  mode="$1"

  if [ "$(get_prop_bool net.tcp_low_latency.enable 0)" -eq 1 ]; then
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

apply_profile() {
  local mode
  mode="$1"
  printf '%s %s\n' "$(read_first_line /proc/sys/kernel/random/boot_id)" "$mode" > "$STATE_DIR/apply_pending"
  log_i "PROFILE: $mode begin"
  log_i "STAGE: CPU"
  apply_cpu_profile "$mode"
  log_i "STAGE: UCLAMP"
  apply_uclamp_profile "$mode"
  log_i "STAGE: TOUCH"
  apply_touchboost "$mode"
  log_i "STAGE: GPU"
  apply_gpu_profile "$mode"
  log_i "STAGE: IO"
  apply_io_profile "$mode"
  log_i "STAGE: NET"
  apply_net_profile "$mode"
  log_i "PROFILE: $mode complete"
  rm -f "$STATE_DIR/apply_pending"
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

  return 2
}

is_screen_on() {
  is_screen_on_sysfs
  r="$?"

  [ "$r" = "0" ] && return 0
  [ "$r" = "1" ] && return 1

  out="$(dumpsys -t 2 power 2>/dev/null)"
  contains "$out" "mInteractive=false" && return 1
  contains "$out" "mWakefulness=Asleep" && return 1
  contains "$out" "mWakefulness=Dozing" && return 1
  contains "$out" "mInteractive=true" && return 0
  contains "$out" "mWakefulness=Awake" && return 0
  contains "$out" "Display Power: state=ON" && return 0

  out2="$(dumpsys -t 2 display 2>/dev/null)"
  contains "$out2" "mState=ON" && return 0

  return 1
}

stable_screen_state() {
  local s1 s2
  if is_screen_on; then
    s1="on"
  else
    s1="off"
  fi

  # Confirm transitions only; avoid a second probe on every idle poll.
  [ "$s1" = "${last_effective:-}" ] && { echo "$s1"; return 0; }
  sleep 1

  if is_screen_on; then
    s2="on"
  else
    s2="off"
  fi

  [ "$s1" = "$s2" ] && echo "$s1" || echo ""
}

topapp_min_nodes() {
  local node cg_top
  for node in /dev/stune/top-app/uclamp.min /dev/cpuset/top-app/uclamp.min; do
    [ -e "$node" ] && echo "$node"
  done
  cg_top="$(cg_find_group top-app)"
  [ -n "$cg_top" ] && [ -e "$cg_top/cpu.uclamp.min" ] && echo "$cg_top/cpu.uclamp.min"
  return 0
}

set_topapp_min_all_bases() {
  local node val pct val_pct current current_units whole frac
  val="$1"
  for node in $(topapp_min_nodes); do
    current="$(read_node "$node")"
    case "$node" in
      */cpu.uclamp.min)
        pct=$((val * 10000 / 1024))
        whole="${current%%.*}"
        frac="${current#*.}"
        [ "$frac" = "$current" ] && frac=0
        # Compare in hundredths without floating-point tools.
        case "$whole:$frac" in *[!0-9:]*|:*) continue ;; esac
        frac="${frac}00"
        frac="${frac%"${frac#??}"}"
        current_units=$((whole * 100 + 10#$frac))
        [ "$pct" -gt "$current_units" ] || continue
        val_pct="$(printf '%d.%02d' $((pct / 100)) $((pct % 100)))"
        write_node "$node" "$val_pct"
        ;;
      *)
        case "$current" in ""|*[!0-9]*) continue ;; esac
        [ "$val" -gt "$current" ] && write_node "$node" "$val"
        ;;
    esac
  done
  return 0
}

effective_state_from_mode() {
  fm="$1"
  case "$fm" in
    aggressive) echo "on" ;;
    strict) echo "off" ;;
    auto|*) stable_screen_state ;;
  esac
}

acquire_daemon_lock() {
  local boot old_lock
  boot="$(read_first_line /proc/sys/kernel/random/boot_id)"
  [ -n "$boot" ] || return 1
  DAEMON_LOCK="$STATE_DIR/daemon.$boot.lock"
  # Fail closed on an occupied lock, including after SIGKILL in this boot.
  mkdir "$DAEMON_LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$DAEMON_LOCK/pid"
  printf '%s\n' "$$" > "$STATE_DIR/daemon.pid"
  trap 'release_daemon_lock' EXIT
  trap 'exit 0' HUP INT TERM
  for old_lock in "$STATE_DIR"/daemon.*.lock; do
    [ "$old_lock" = "$DAEMON_LOCK" ] && continue
    rm -f "$old_lock/pid"
    rmdir "$old_lock" 2>/dev/null
  done
  return 0
}

release_daemon_lock() {
  rm -f "$STATE_DIR/daemon.pid"
  rm -f "$DAEMON_LOCK/pid"
  rmdir "$DAEMON_LOCK" 2>/dev/null
}

main() {
  aktune_prepare_dirs
  rotate_logs_if_needed
  acquire_daemon_lock || { log_w "Another tuning process owns the lock"; return 1; }
  aktune_prepare_boot_state || return 1
  local pending_boot pending_mode boot
  boot="$(read_first_line /proc/sys/kernel/random/boot_id)"
  if [ -f "$STATE_DIR/apply_pending" ]; then
    read -r pending_boot pending_mode < "$STATE_DIR/apply_pending"
    if [ "$pending_boot" != "$boot" ]; then
      log_e "Tuning paused: previous boot ended during profile $pending_mode; collect crash logs before retrying"
      return 1
    fi
  fi
  log_i "Kernel: $(uname -a)"
  detect_platform
  if [ "${1:-}" = "--oneshot" ]; then
    apply_profile on
    return
  fi

  interval="$(get_prop_range daemon.interval_sec 8 2 300)"
  debounce_ms="$(get_prop_range daemon.debounce_ms 1200 0 60000)"

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
        fi
      fi
    fi

    sleep "$interval"
  done
}

main "$@"
