#!/system/bin/sh

AKTUNE_ID="aktune"

AKTUNE_DATA_DIR="${AKTUNE_DATA_DIR:-/data/adb/aktune}"
AKTUNE_CR="$(printf '\r')"
LOG_DIR="$AKTUNE_DATA_DIR/logs"
STATE_DIR="$AKTUNE_DATA_DIR/state"
LOG_FILE="$LOG_DIR/aktune.log"
BASELINE_DB="$STATE_DIR/baseline.tsv"
BLOCKED_DB="$STATE_DIR/blocked.tsv"
CONFIG_FILE="$AKTUNE_DATA_DIR/config.props"

# ---- PATH handling (do NOT reorder existing PATH) ----
# Some ROMs provide core tools in APEX paths; forcing /system/bin first can break things.
akt_path_add() {
  d="$1"
  [ -d "$d" ] || return 0
  case ":$PATH:" in
    *":$d:"*) : ;;
    *) PATH="$PATH:$d" ;;
  esac
}

# Best-effort: keep existing PATH order, only append missing directories
akt_path_add "/apex/com.android.runtime/bin"
akt_path_add "/apex/com.android.art/bin"
akt_path_add "/apex/com.android.virt/bin"
akt_path_add "/system_ext/bin"
akt_path_add "/system/bin"
akt_path_add "/system/xbin"
akt_path_add "/vendor/bin"
akt_path_add "/vendor/xbin"
akt_path_add "/odm/bin"
akt_path_add "/product/bin"
akt_path_add "/sbin"
akt_path_add "/data/adb/magisk"

export PATH

# ---- tiny pure-sh helpers ----

akt_strip_cr() {
  # Remove a single trailing carriage return if present (CRLF-safe)
  s="$1"
  cr="$(printf '\r')"
  s="${s%$cr}"
  printf "%s" "$s"
}

_now() {
  if command -v date >/dev/null 2>&1; then
    date "+%Y-%m-%d %H:%M:%S" 2>/dev/null && return 0
  fi
  # Fallback: uptime seconds
  if [ -r /proc/uptime ]; then
    read -r up _ < /proc/uptime 2>/dev/null
    echo "uptime:${up%%.*}"
    return 0
  fi
  echo "0000-00-00 00:00:00"
}

log_i() { echo "$(_now) [I] $*" >> "$LOG_FILE"; }
log_w() { echo "$(_now) [W] $*" >> "$LOG_FILE"; }
log_e() { echo "$(_now) [E] $*" >> "$LOG_FILE"; }

# Collapse whitespace safely WITHOUT tr/sed/awk/grep
# Important: disable globbing to avoid wildcard expansion
akt_trim_ws() {
  s="$1"
  set -f
  # shellcheck disable=SC2086
  set -- $s
  set +f
  echo "$*"
}

read_first_line() {
  f="$1"
  [ -f "$f" ] || return 1
  line=""
  while IFS= read -r line; do
    line="$(akt_strip_cr "$line")"
    echo "$line"
    return 0
  done < "$f"
  return 1
}

# Read an entire file without cat (best-effort)
akt_read_file() {
  f="$1"
  [ -r "$f" ] || return 1
  first=1
  while IFS= read -r line; do
    line="$(akt_strip_cr "$line")"
    if [ "$first" -eq 1 ]; then
      first=0
      printf "%s" "$line"
    else
      printf "\n%s" "$line"
    fi
  done < "$f"
  return 0
}

# Uptime in milliseconds (pure-sh, no awk/printf)
akt_uptime_ms() {
  if [ -r /proc/uptime ]; then
    read -r up _ < /proc/uptime 2>/dev/null
    sec="${up%%.*}"
    frac="${up#*.}"
    frac3="${frac}000"
    case "$frac3" in
      ???*)
        rest="${frac3#???}"
        [ -n "$rest" ] && frac3="${frac3%$rest}"
        ;;
      *) frac3="000" ;;
    esac
    case "$sec" in ""|*[!0-9]*) sec=0 ;; esac
    echo $((sec * 1000 + 10#$frac3))
    return 0
  fi
  echo 0
}

# Sleep that survives missing/broken /system/bin/sleep
# Accepts "N" or "N.MMM"
akt_sleep() {
  dur="$1"
  [ -n "$dur" ] || dur="1"

  if command -v sleep >/dev/null 2>&1; then
    sleep "$dur" 2>/dev/null && return 0
  fi

  # Busy-wait fallback using uptime (avoid crashes; used only if sleep is missing)
  ms_total=0
  case "$dur" in
    *.*)
      s="${dur%%.*}"
      f="${dur#*.}"
      case "$s" in ""|*[!0-9]*) s=0 ;; esac
      f3="${f}000"
      case "$f3" in
        ???*)
          rest="${f3#???}"
          [ -n "$rest" ] && f3="${f3%$rest}"
          ;;
        *) f3="000" ;;
      esac
      case "$f3" in ""|*[!0-9]*) f3="000" ;; esac
      ms_total=$((s * 1000 + 10#$f3))
      ;;
    *)
      case "$dur" in ""|*[!0-9]*) dur=1 ;; esac
      ms_total=$((dur * 1000))
      ;;
  esac

  start="$(akt_uptime_ms)"
  end=$((start + ms_total))
  while :; do
    now="$(akt_uptime_ms)"
    [ "$now" -ge "$end" ] && break
  done
  return 0
}

# Config parsing without awk/grep
_get_prop_raw() {
  local key line
  key="$1"
  [ -f "$CONFIG_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%"$AKTUNE_CR"}"
    case "$line" in ""|\#*) continue ;; esac
    case "$line" in "$key="*) echo "${line#*=}"; return 0 ;; esac
  done < "$CONFIG_FILE"
  return 1
}

get_prop() {
  key="$1"
  def="$2"
  val="$(_get_prop_raw "$key")"
  [ -n "$val" ] && { echo "$val"; return 0; }
  echo "$def"
}

get_prop_int() {
  local val
  val="$(get_prop "$1" "$2")"
  # These settings are nonnegative. Reject signs, embedded '-' and overflow.
  case "$val" in ""|*[!0-9]*|??????????*) echo "$2"; return ;; esac
  while [ "${val#0}" != "$val" ]; do val="${val#0}"; done
  echo "${val:-0}"
}

get_prop_range() {
  local val
  val="$(get_prop_int "$1" "$2")"
  if [ "$val" -lt "$3" ] || [ "$val" -gt "$4" ]; then
    echo "$2"
  else
    echo "$val"
  fi
}

get_prop_bool() {
  key="$1"
  def="$2"
  val="$(get_prop "$key" "$def")"
  case "$val" in 1|true|on|yes|Y|y) echo 1 ;; *) echo 0 ;; esac
}

_ensure_default_config() {
  [ -f "$CONFIG_FILE" ] || : > "$CONFIG_FILE"

  # If user already has content, do not overwrite
  if command -v wc >/dev/null 2>&1; then
    size="$(wc -c < "$CONFIG_FILE" 2>/dev/null)"
    [ -n "$size" ] || size=0
    [ "$size" -gt 0 ] && return 0
  else
    read_first_line "$CONFIG_FILE" >/dev/null 2>&1 && return 0
  fi

  # Copy module default preset (first install)
  if [ -n "${AKTUNE_MODDIR:-}" ] && [ -f "$AKTUNE_MODDIR/common/config.default.props" ]; then
    # avoid cat if possible
    cp "$AKTUNE_MODDIR/common/config.default.props" "$CONFIG_FILE" 2>/dev/null
    return 0
  fi

  # Fallback minimal defaults
  cat > "$CONFIG_FILE" <<'EOF'
daemon.interval_sec=8
daemon.debounce_ms=1200
uclamp.top.min.interactive=128
EOF
}

aktune_prepare_dirs() {
  mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null
  [ -f "$LOG_FILE" ] || : > "$LOG_FILE"
  [ -f "$BASELINE_DB" ] || : > "$BASELINE_DB"
  [ -f "$BLOCKED_DB" ] || : > "$BLOCKED_DB"
  [ -f "$CONFIG_FILE" ] || : > "$CONFIG_FILE"
  _ensure_default_config
}

aktune_prepare_boot_state() {
  local boot previous
  boot="$(read_first_line /proc/sys/kernel/random/boot_id)"
  [ -n "$boot" ] || { log_e "Cannot identify boot; skipping tuning"; return 1; }
  previous="$(read_first_line "$STATE_DIR/boot_id")"
  if [ "$boot" != "$previous" ]; then
    cp "$BASELINE_DB" "$STATE_DIR/baseline.previous.tsv" 2>/dev/null
    : > "$BASELINE_DB"
    : > "$BLOCKED_DB"
    printf '%s\n' "$boot" > "$STATE_DIR/boot_id"
  fi
}

rotate_logs_if_needed() {
  [ -f "$LOG_FILE" ] || return 0
  command -v wc >/dev/null 2>&1 || return 0
  size="$(wc -c < "$LOG_FILE" 2>/dev/null)"
  [ -n "$size" ] || return 0
  [ "$size" -lt 1048576 ] && return 0
  [ -f "$LOG_FILE.2" ] && mv -f "$LOG_FILE.2" "$LOG_FILE.3" 2>/dev/null
  [ -f "$LOG_FILE.1" ] && mv -f "$LOG_FILE.1" "$LOG_FILE.2" 2>/dev/null
  mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
  : > "$LOG_FILE"
}

wait_boot_completed() {
  timeout="${1:-120}"
  i=0
  while [ "$i" -lt "$timeout" ]; do
    [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && return 0
    akt_sleep 1
    i=$((i + 1))
  done
  return 1
}

# Keep digits only (best-effort)
_digits_only() {
  s="$1"
  # If tr exists, use it (more robust), else fallback
  if command -v tr >/dev/null 2>&1; then
    printf "%s" "$s" | tr -cd '0-9'
    return 0
  fi
  case "$s" in *[!0-9]*|"") echo "" ;; *) echo "$s" ;; esac
}

_mem_kb_from_proc_meminfo() {
  kb=""
  [ -r /proc/meminfo ] || { echo ""; return 0; }
  while IFS= read -r line; do
    line="$(akt_strip_cr "$line")"
    case "$line" in
      MemTotal:*)
        set -f
        # shellcheck disable=SC2086
        set -- $line
        set +f
        kb="$2"
        break
        ;;
    esac
  done < /proc/meminfo
  echo "$kb"
}

_mem_mb_from_getprop() {
  for k in ro.boot.ddr_size ro.boot.ddrsize ro.boot.ram_size ro.boot.ramsize ro.boot.mem_size ro.boot.memsize ro.boot.memory ro.boot.ram; do
    v="$(getprop "$k" 2>/dev/null)"
    d="$(_digits_only "$v")"
    case "$d" in ""|*[!0-9]*) continue ;; esac
    if [ "$d" -le 65536 ]; then
      echo "$d"
      return 0
    fi
    if [ "$d" -ge 104857600 ]; then
      echo $((d / 1024 / 1024))
      return 0
    fi
  done
  echo ""
}

_mem_mb_from_dumpsys() {
  command -v dumpsys >/dev/null 2>&1 || { echo ""; return 0; }
  out="$(dumpsys meminfo 2>/dev/null)"
  [ -n "$out" ] || { echo ""; return 0; }
  mb=""
  while IFS= read -r line; do
    line="$(akt_strip_cr "$line")"
    case "$line" in
      "Total RAM:"*)
        set -f
        # shellcheck disable=SC2086
        set -- $line
        set +f
        raw="$3"
        raw="$(_digits_only "$raw")"
        case "$raw" in ""|*[!0-9]*) : ;; *) mb=$((raw / 1024)) ;; esac
        break
        ;;
    esac
  done <<EOF
$out
EOF
  echo "$mb"
}

get_mem_total_mb() {
  kb="$(_mem_kb_from_proc_meminfo)"
  case "$kb" in ""|*[!0-9]*) kb="0" ;; esac
  if [ "$kb" -gt 0 ]; then
    echo $((kb / 1024))
    return 0
  fi

  mb="$(_mem_mb_from_getprop)"
  case "$mb" in ""|*[!0-9]*) : ;; *) [ "$mb" -gt 0 ] && { echo "$mb"; return 0; } ;; esac

  mb="$(_mem_mb_from_dumpsys)"
  case "$mb" in ""|*[!0-9]*) : ;; *) [ "$mb" -gt 0 ] && { echo "$mb"; return 0; } ;; esac

  echo "0"
}

aktune_daemon_running() {
  local pid command_line
  pid="$(read_first_line "$STATE_DIR/daemon.pid")"
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  case "$command_line" in *"/tweaks/daemon.sh"*) return 0 ;; esac
  return 1
}
