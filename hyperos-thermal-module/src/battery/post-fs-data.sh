#!/system/bin/sh
# 电池解容工具箱 - post-fs-data 阶段
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh

log "pfd: begin"

# FreePPS 二进制的 fp.dat 路径写死在 /data/adb/modules/battery_tune 下。
# 只建兼容目录 + 单文件软链（不放 module.prop，避免 KernelSU 显示幽灵模块；
# 若该目录已是用户自己安装的 battery_tune 真模块，则完全不动）。
_bt=/data/adb/modules/battery_tune
[ -L "$_bt" ] && rm -f "$_bt" 2>/dev/null
[ -d "$_bt" ] || mkdir -p "$_bt" 2>/dev/null
if [ -d "$_bt" ] && [ ! -f "$_bt/module.prop" ]; then
    [ -e "$_bt/fp.dat" ] || ln -sfn "$XBT/fp.dat" "$_bt/fp.dat" 2>/dev/null
fi

# 清理重启前残留的 fv_guard pidfile，避免 PID 复用导致“假存活”而不再启动。
rm -f /data/local/tmp/xt_fv_guard.pid 2>/dev/null

KSUD=/data/adb/ksu/bin/ksud
if [ -x "$KSUD" ]; then
  KSU_MODULE=HyperOS_XJ "$KSUD" module config set manage.kernel_umount false >>"$LOG" 2>&1
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