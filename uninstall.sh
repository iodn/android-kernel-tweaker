#!/system/bin/sh
# AKTune uninstall script: best-effort restore captured baseline values
MODDIR="${0%/*}"

# shellcheck disable=SC1091
. "$MODDIR/common/util.sh"
. "$MODDIR/common/sysfs.sh"

aktune_prepare_dirs
if aktune_daemon_running; then
  kill "$(read_first_line "$STATE_DIR/daemon.pid")" 2>/dev/null
  attempts=0
  while aktune_daemon_running; do
    attempts=$((attempts + 1))
    [ "$attempts" -ge 10 ] && { log_w "Uninstall: daemon still active; restore deferred to reboot"; exit 1; }
    sleep 1
  done
fi
aktune_prepare_boot_state || exit 1

log_i "Uninstall: attempting baseline restore..."
restore_baseline_all
log_i "Uninstall: baseline restore complete"

# Optional: cleanup AKTune state (comment out if you want to keep logs after uninstall)
rm -rf "$AKTUNE_DATA_DIR/state" 2>/dev/null
