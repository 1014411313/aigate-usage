#!/system/bin/sh
# 模块被移除时还原设备原始取值并清理配置
MODDIR=${0%/*}
. "$MODDIR/bin/perf.sh"

restore_defaults
rm -rf "$CONFIG_DIR"
