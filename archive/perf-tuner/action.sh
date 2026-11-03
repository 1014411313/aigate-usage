#!/system/bin/sh
# KernelSU 管理器中点击「执行」按钮时运行：用音量键选择方案并立即生效
MODDIR=${0%/*}
. "$MODDIR/bin/perf.sh"

say "当前方案：$(current_profile)"
select_profile 8 "$(current_profile)"
apply "$SELECTED_PROFILE"
