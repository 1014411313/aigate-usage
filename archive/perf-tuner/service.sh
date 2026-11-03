#!/system/bin/sh
# late_start service 阶段按已保存的方案应用调优
MODDIR=${0%/*}
. "$MODDIR/bin/perf.sh"

saved=$(current_profile)
case "$saved" in
  default | "") reset ;;
  *) apply "$saved" ;;
esac
