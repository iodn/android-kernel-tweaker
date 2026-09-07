#!/system/bin/sh

MODDIR="${0%/*}"
export AKTUNE_MODDIR="$MODDIR"
. "$MODDIR/common/util.sh"

aktune_prepare_dirs
rotate_logs_if_needed

log_i "service: waiting for boot completion"
wait_boot_completed 180 || { log_w "service: boot incomplete; tuning skipped"; exit 0; }
akt_sleep 5

if aktune_daemon_running; then
  log_i "service: daemon already running"
  exit 0
fi

log_i "service: starting adaptive daemon"

if command -v nohup >/dev/null 2>&1; then
  nohup sh "$MODDIR/tweaks/daemon.sh" >> "$LOG_FILE" 2>&1 &
else
  sh "$MODDIR/tweaks/daemon.sh" >> "$LOG_FILE" 2>&1 &
fi

log_i "service: daemon pid=$!"
exit 0
