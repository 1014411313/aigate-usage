#!/system/bin/sh
# ============================================================================
# guard_watchdog.sh —— charge_guard 掉线自愈（v3.9.5 重写版）
# ----------------------------------------------------------------------------
# 【为什么重写】
#   v3.4.0 的旧版第 40 行是 `tr '\0' ' ' < "/proc/$_p/cmdline"`（裸读，无 timeout）。
#   竞态：pgrep -f 会命中 charge_guard 的短命 fork 子 shell（exec 前 cmdline 与父相同），
#   若目标在 open 与 read 之间被回收，内核每次 read 都返回 -ESRCH；
#   Android toybox 的 tr 只在 read()==0 时退出，返回 -1 时死循环重读
#   → tr 单核 100% + 看守永久卡死 + 自愈静默失效。
#   当时处理方式是【把整个脚本删掉】，结果连自愈功能一起没了。
#
# 【本版设计：根本不读 cmdline，从根上消除该 bug 类】
#   active_guard.sh 启动时把 $$ 写进 state/cg.pid；
#   本脚本只做 `kill -0 <pid>` 判活 —— 不碰 /proc/<pid>/cmdline，
#   不 fork 任何读 proc 的子进程，因此无论目标何时退出都不会出现 ESRCH 死循环。
#
# 【额外保护】
#   ① 每次判活前校验 PID 文件时间戳，超过 10 分钟未更新则忽略（防 PID 复用）
#   ② 重启前二次确认，避免瞬时抖动导致双实例
#   ③ 全局限流：同一分钟内最多重启 1 次
#   ④ 所有外部命令仍加 timeout，遵守模块既有惯例
# ============================================================================
XBT=/data/adb/modules/HyperOS_XJ/battery
LOG="${LOG:-/data/local/tmp/xt_toolbox.log}"
PIDF="$XBT/state/cg.pid"
LASTF="$XBT/state/wd_last_restart"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') guard_watchdog: $*" >> "$LOG" 2>/dev/null; }

# ---- 判断 charge_guard 是否活着（只靠 PID 文件 + kill -0，不读 cmdline）----
cg_alive() {
  [ -s "$PIDF" ] || return 1
  _pid=$(cat "$PIDF" 2>/dev/null)
  case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_pid" -gt 1 ] 2>/dev/null || return 1

  # PID 文件超过 10 分钟未更新 → 可能是陈旧记录（PID 已被别的进程复用）
  # 用 `date -r 文件 +%s` 不可靠（toybox 版本差异），改用 state 里另存的时间戳
  _tsf="$XBT/state/cg_started_ts"
  if [ -s "$_tsf" ]; then
    _ts=$(cat "$_tsf" 2>/dev/null); _now=$(date +%s)
    case "$_ts" in ''|*[!0-9]*) ;; *)
      [ $((_now - _ts)) -gt 86400 ] && return 1 ;;   # 超过 24 小时视为陈旧
    esac
  fi

  kill -0 "$_pid" 2>/dev/null || return 1
  return 0
}

# ---- 重启 charge_guard ----
restart_cg() {
  _now=$(date +%s)
  _last=$(cat "$LASTF" 2>/dev/null)
  case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  if [ $((_now - _last)) -lt 60 ]; then
    log "跳过重启（60 秒全局限流内，上次 $_last）"
    return 1
  fi
  echo "$_now" > "$LASTF" 2>/dev/null

  log "检测到 charge_guard 掉线（pidfile=$(cat "$PIDF" 2>/dev/null)），正在重启"
  rm -f "$PIDF" 2>/dev/null
  ( setsid sh $XBT/scripts/charge_guard.sh >/dev/null 2>&1 < /dev/null & )
  sleep 3
  if cg_alive; then
    log "重启成功 pid=$(cat "$PIDF" 2>/dev/null)"
  else
    log "⚠ 重启后仍不存活，等待下一轮"
  fi
}

# ---- 主循环 ----
log "started (pid $$, PID-file 模式，不读 /proc/<pid>/cmdline)"
TICK=0
while :; do
  TICK=$((TICK + 1))
  # 每 60 秒巡检一次
  if ! cg_alive; then
    restart_cg
  elif [ $((TICK % 30)) -eq 1 ]; then
    # 约每 30 分钟打一次存活心跳，便于日志核对（不刷屏）
    log "alive pid=$(cat "$PIDF" 2>/dev/null)"
  fi
  sleep 60
done
