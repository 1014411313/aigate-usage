#!/system/bin/sh
# 安装时由 KernelSU / Magisk 的安装器 source 执行
SKIPMOUNT=true
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=true

MODDIR=$MODPATH
. "$MODPATH/bin/perf.sh"

ui_print "- 安装 Perf Tuner"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for script in bin/perf.sh service.sh action.sh uninstall.sh; do
  set_perm "$MODPATH/$script" 0 0 0755
done

select_profile 15 balanced
apply "$SELECTED_PROFILE"
ui_print "- 默认方案已设为 $SELECTED_PROFILE"
ui_print "- 可在 KernelSU 管理器的模块 WebUI 中随时切换"
