#!/system/bin/sh
# Use the same safety checks and profiles as the adaptive daemon.
MODDIR="${0%/*}"
exec sh "$MODDIR/tweaks/daemon.sh" --oneshot
