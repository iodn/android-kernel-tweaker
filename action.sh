#!/system/bin/sh

MODDIR="${0%/*}"
export AKTUNE_MODDIR="$MODDIR"

# Load helpers/paths
. "$MODDIR/common/util.sh"

aktune_prepare_dirs

MODE_FILE="$STATE_DIR/force_mode"

read_mode() {
  if [ -f "$MODE_FILE" ]; then
    m="$(read_first_line "$MODE_FILE" 2>/dev/null)"
    m="$(akt_trim_ws "$m")"
    [ -n "$m" ] && { echo "$m"; return 0; }
  fi
  echo "auto"
}

normalize_mode() {
  case "$1" in
    auto|aggressive|strict) echo "$1" ;;
    *) echo "auto" ;;
  esac
}

next_mode() {
  case "$1" in
    auto) echo "aggressive" ;;
    aggressive) echo "strict" ;;
    strict) echo "auto" ;;
    *) echo "auto" ;;
  esac
}

mode_desc() {
  case "$1" in
    auto) echo "AUTO: Screen ON => Aggressive, Screen OFF => Strict" ;;
    aggressive) echo "AGGRESSIVE: Always Aggressive (ignores screen state)" ;;
    strict) echo "STRICT: Always Strict (ignores screen state)" ;;
    *) echo "AUTO: Screen ON => Aggressive, Screen OFF => Strict" ;;
  esac
}

cur="$(read_mode)"
cur="$(normalize_mode "$cur")"
nxt="$(next_mode "$cur")"

echo "$nxt" > "$MODE_FILE" 2>/dev/null

log_i "action: mode changed $cur -> $nxt"

echo ""
echo "========================================"
echo "AKTune: mode changed"
echo "Current: $cur"
echo "Next: $nxt"
echo "----------------------------------------"
mode_desc "$nxt"
echo "========================================"
echo ""

# Keep a single writer. The running daemon observes the new mode next poll.
if aktune_daemon_running; then
  log_i "action: mode queued for running daemon"
  echo "AKTune: mode will apply on the next poll"
  exit 0
fi

# A reboot during a write requires an explicit retry after collecting logs.
if [ -f "$STATE_DIR/apply_pending" ]; then
  echo "AKTune: tuning is paused after an interrupted profile."
  echo "Collect logs, then remove /data/adb/aktune/state/apply_pending to retry."
  exit 0
fi

if command -v nohup >/dev/null 2>&1; then
  nohup sh "$MODDIR/tweaks/daemon.sh" >> "$LOG_FILE" 2>&1 &
else
  sh "$MODDIR/tweaks/daemon.sh" >> "$LOG_FILE" 2>&1 &
fi

log_i "action: daemon restarted pid=$!"
echo "AKTune: daemon restarted"
echo ""
