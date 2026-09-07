#!/system/bin/sh

SKIPUNZIP=0

print_modname() {
  ui_print "*******************************"
  ui_print " AKTune v2.2"
  ui_print " Kernel Tweaker"
  ui_print "*******************************"
}

on_install() {
  ui_print "- Installing AKTune files..."
}

set_permissions() {
  ui_print "- Setting permissions..."

  set_perm_recursive "$MODPATH" 0 0 0755 0644

  set_perm "$MODPATH/aktune.sh" 0 0 0755
  set_perm "$MODPATH/service.sh" 0 0 0755
  set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
  set_perm "$MODPATH/uninstall.sh" 0 0 0755

  set_perm_recursive "$MODPATH/common" 0 0 0755 0644
  set_perm_recursive "$MODPATH/tweaks" 0 0 0755 0644

  chmod 0755 "$MODPATH/aktune.sh" "$MODPATH/service.sh" "$MODPATH/post-fs-data.sh" "$MODPATH/uninstall.sh" 2>/dev/null
  chmod 0755 "$MODPATH/common/"*.sh 2>/dev/null
  chmod 0755 "$MODPATH/tweaks/"*.sh 2>/dev/null
}
