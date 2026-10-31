#!/system/bin/sh
# 电池解容工具箱 - post-fs-data 阶段
XBT=/data/adb/modules/battery_tune
. $XBT/scripts/common.sh

log "pfd: begin"

# 清理重启前残留的 fv_guard pidfile，避免 PID 复用导致“假存活”而不再启动。
rm -f /data/local/tmp/xt_fv_guard.pid 2>/dev/null

KSUD=/data/adb/ksu/bin/ksud
if [ -x "$KSUD" ]; then
  KSU_MODULE=battery_tune "$KSUD" module config set manage.kernel_umount false >>"$LOG" 2>&1
fi

if [ "$(cfg_get unlock 1)" = "1" ]; then
  baa_refresh_src >/dev/null 2>>"$LOG"
  sh $XBT/scripts/baa_ops.sh mount >>"$LOG" 2>&1
  _rc=$?
  log "pfd: mount exit=$_rc"
else
  log "pfd: unlock=0, skip mount"
fi

# 云控屏蔽：BAA服务启动前清点/隔离云端配置（v1.6.0）
if [ "$(cfg_get cloud_guard 1)" = "1" ]; then
  sh $XBT/scripts/cloud_guard.sh early >>"$LOG" 2>&1
fi
exit 0