#!/system/bin/sh
SKIPUNZIP=0
ui_print "------------------------------------------"
ui_print " ETA 背屏电池卡片"
ui_print "------------------------------------------"
ui_print "- 安装控制端 APK"
pm install -r "$MODPATH/apk/rs.apk" >/dev/null 2>&1
if pm path com.eta.rearscreen >/dev/null 2>&1; then
  ui_print "  [OK] APK 已安装"
else
  ui_print "  [!] 自动安装失败，请手动安装 apk/rs.apk"
fi
ui_print "- 关闭原生背屏时钟（避免覆盖卡片）"
pm disable --user 0 com.xiaomi.subscreencenter >/dev/null 2>&1
ui_print "  [OK] com.xiaomi.subscreencenter 已禁用"
ui_print "- 服务脚本将在开机后自动投放卡片"
ui_print "------------------------------------------"
ui_print " 安装完成，重启生效"
ui_print "------------------------------------------"
