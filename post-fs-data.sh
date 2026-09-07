#!/system/bin/sh

MODDIR="${0%/*}"
export AKTUNE_MODDIR="$MODDIR"
. "$MODDIR/common/util.sh"

aktune_prepare_dirs

chmod 0755 \
  "$MODDIR/aktune.sh" \
  "$MODDIR/service.sh" \
  "$MODDIR/post-fs-data.sh" \
  "$MODDIR/uninstall.sh" \
  "$MODDIR/action.sh" \
  "$MODDIR/tweaks/daemon.sh" \
  2>/dev/null

chmod 0755 "$MODDIR/common/"*.sh 2>/dev/null
chmod 0755 "$MODDIR/tweaks/"*.sh 2>/dev/null

log_i "post-fs-data: AKTune directories prepared"
