#!/system/bin/sh
# 电池解容工具箱 - 循环伪装守护（v2.6.18）
# 背景：部分 FG 固件会在充电/周期同步时把 cyclecount 回滚为真实值；
#       本守护 10s 检查一次，仅"被回滚"时重压（值未变不写），并同步维护
#       battery/cycle_count（如存在且可写），保证各读取端一致。
# 用法: cycle_guard.sh start|stop|status
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh
PIDFILE=/data/local/tmp/xt_cycle_guard.pid
NODES="/sys/class/xm_power/fg_master/cyclecount /sys/class/power_supply/battery/cycle_count"

_guard_alive() {
  _p="$1"
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_p" 2>/dev/null || return 1
  # v2.6.23：加超时保护（读 /proc/<pid>/cmdline 在该进程退出瞬间会永久阻塞）
  case "$(timeout 1 cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')" in
    *cycle_guard*) return 0 ;;
  esac
  return 1
}

_apply() {
  CF=$(cfg_get cycle_fake "")
  [ -n "$CF" ] || return 0
  for _p in $NODES; do
    [ -e "$_p" ] || continue
    _cur=$(cat "$_p" 2>/dev/null)
    case "$_cur" in ''|*[!0-9]*) continue ;; esac
    [ "$_cur" = "$CF" ] && continue
    chmod 666 "$_p" 2>/dev/null
    echo "$CF" > "$_p" 2>/dev/null
    _now=$(cat "$_p" 2>/dev/null)
    [ "$_now" = "$CF" ] || continue
    # 日志节流：同类重压 10 分钟最多记一条
    _lt=$(cat $XBT/state/cycle_guard_lastlog 2>/dev/null)
    case "$_lt" in ''|*[!0-9]*) _lt=0 ;; esac
    _nw=$(date +%s)
    if [ $((_nw - _lt)) -gt 600 ]; then
      log "cycle_guard: $(basename $_p) $_cur -> $CF"
      echo "$_nw" > $XBT/state/cycle_guard_lastlog 2>/dev/null
    fi
  done
}

_spawn() {
  mkdir -p $XBT/state 2>/dev/null
  ( while true; do
      _apply
      # v2.7：顺带校正真实值记录（若曾被伪装值污染，用 qmax_cyclecount 纠正回来）
      cycle_real_capture 2>/dev/null
      sleep 10
    done ) &
  echo $! > "$PIDFILE"
  log "cycle_guard: started pid=$(cat $PIDFILE)"
  echo "started (pid $(cat $PIDFILE))"
}

start_guard() {
  CF=$(cfg_get cycle_fake "")
  if [ -z "$CF" ]; then
    echo "idle (cycle_fake 未设置，无需守护)"
    return 0
  fi
  if [ -f "$PIDFILE" ]; then
    _p=$(cat "$PIDFILE" 2>/dev/null)
    if _guard_alive "$_p"; then
      echo "already running (pid $_p)"
      return 0
    fi
    rm -f "$PIDFILE"
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$XBT/scripts/cycle_guard.sh" _spawn >/dev/null 2>&1
    _t=0
    while [ "$_t" -lt 5 ]; do
      sleep 1
      _t=$((_t + 1))
      _p=$(cat "$PIDFILE" 2>/dev/null)
      if _guard_alive "$_p"; then
        echo "started (pid $_p)"
        return 0
      fi
    done
  fi
  _spawn
}

stop_guard() {
  if [ -f "$PIDFILE" ]; then
    _p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null
    rm -f "$PIDFILE"
  fi
  log "cycle_guard: stopped"
  echo "stopped"
}

status_guard() {
  if [ -f "$PIDFILE" ] && _guard_alive "$(cat "$PIDFILE" 2>/dev/null)"; then
    echo "running (pid $(cat $PIDFILE))"
  else
    echo "not running"
  fi
}

case "$1" in
  start)   start_guard ;;
  _spawn)  _spawn ;;
  stop)    stop_guard ;;
  status)  status_guard ;;
  *) echo "usage: $0 start|stop|status"; exit 9 ;;
esac