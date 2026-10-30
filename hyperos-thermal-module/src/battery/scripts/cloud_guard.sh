#!/system/bin/sh
# cloud_guard.sh v1.0 — BAA云控屏蔽（云端下发防护 + 云端目录巡检隔离）
# 用法: cloud_guard.sh status|on|off|check|early|watch
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh

STATE=$XBT/state/cloud_guard.state
QDIR=$XBT/state/cloud_quarantine
CLOUD_DIRS="/data/vendor/batteryantiaging/cloud_config /mnt/vendor/persist/charger/batteryantiaging/cloud_config"

st_get() {
  grep "^$1=" "$STATE" 2>/dev/null | tail -n 1 | cut -d= -f2
}

st_bt() {
  _v=$(st_get blocked_total)
  case "$_v" in ''|*[!0-9]*) echo 0 ;; *) echo "$_v" ;; esac
}

st_write() {
  # $1=result  $2=blocked_total
  mkdir -p "$XBT/state"
  {
    echo "last_check=$(date '+%H:%M:%S')"
    echo "last_result=$1"
    echo "blocked_total=$2"
  } > "$STATE"
}

scan_count() {
  _n=0
  for d in $CLOUD_DIRS; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -e "$f" ] || continue
      _n=$((_n+1))
    done
  done
  echo "$_n"
}

quarantine() {
  _n=0
  for d in $CLOUD_DIRS; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -e "$f" ] || continue
      mkdir -p "$QDIR"
      # v2.6.23：隔离文件名内嵌自增序号，保证同一秒内多个文件不重名（旧版仅秒级时间戳会互相覆盖）
      _ts=$(date '+%Y%m%d_%H%M%S')
      _base=$(basename "$f")
      _dst="$QDIR/${_ts}__${_base}"
      _k=1
      while [ -e "$_dst" ]; do
        _dst="$QDIR/${_ts}__${_k}__${_base}"
        _k=$((_k + 1))
      done
      if mv "$f" "$_dst" 2>>"$LOG"; then
        _n=$((_n+1)); log "cloud_guard: quarantined $f -> $_dst"
        # v2.6.23：来源映射改用「隔离文件名」作键（旧版用秒级时间戳，同秒多文件会互相覆盖 → 卸载时丢文件）
        echo "${_dst##*/}|$f" >> "$QDIR/_sources.log" 2>/dev/null
      elif cp -af "$f" "$_dst" 2>>"$LOG" && rm -f "$f"; then
        _n=$((_n+1)); log "cloud_guard: quarantined(copy+rm) $f -> $_dst"
        echo "${_dst##*/}|$f" >> "$QDIR/_sources.log" 2>/dev/null
      else
        log "cloud_guard: MOVE FAILED $f"
      fi
    done
  done
  echo "$_n"
}

do_check() {
  # $1=quiet
  _tot=$(scan_count)
  if [ "$_tot" = "0" ]; then
    [ "$1" = "quiet" ] || echo "云端目录干净（0 个文件）"
    st_write clean "$(st_bt)"
    return 0
  fi
  _m=$(quarantine)
  _bt=$(( $(st_bt) + _m ))
  st_write blocked "$_bt"
  [ "$1" = "quiet" ] || echo "⚠ 发现云端文件：本次隔离 ${_m} 个（累计 ${_bt}）"
  log "cloud_guard: found=${_tot} moved=${_m} total=${_bt}"
}

# ---- v2.7.13 新增：归还隔离区文件（关闭云控屏蔽时使用）----
# 【为什么必须加】旧版只有 uninstall.sh 会归还（uninstall.sh:145-172）。
#   于是"关掉云控屏蔽"这个动作【不归还任何文件】：
#     · 被隔离的云端配置永久滞留在 $XBT/state/cloud_quarantine
#     · 越关越多（每次巡检都会继续搬新文件进去）
#     · 用户以为"关了"，实际那些文件再也不会被系统读到
#   本函数与 uninstall.sh 的归还逻辑保持一致（含新格式精确匹配 + 旧格式时间戳回退）。
restore_quarantine() {
  _qdir="$QDIR"
  [ -d "$_qdir" ] || { echo 0; return; }
  _n=0
  for f in "$_qdir"/*; do
    [ -e "$f" ] || continue
    _b=$(basename "$f")
    case "$_b" in _sources.log) continue ;; esac
    # 新格式：按隔离文件名精确匹配；旧格式：回退用时间戳前缀（兼容历史隔离区）
    _src=$(grep -F "${_b}|" "$_qdir/_sources.log" 2>/dev/null | tail -n 1 | cut -d'|' -f2-)
    if [ -z "$_src" ]; then
      _ts=${_b%%__*}
      _src=$(grep -F "${_ts}|" "$_qdir/_sources.log" 2>/dev/null | tail -n 1 | cut -d'|' -f2-)
    fi
    # 真正的原始文件名：去掉 `<ts>__` 或 `<ts>__<n>__` 前缀
    _orig=$(echo "$_b" | sed -E 's/^[0-9]{8}_[0-9]{6}__([0-9]+__)?//')
    if [ -n "$_src" ] && [ -d "$(dirname "$_src")" ] && [ ! -e "$_src" ]; then
      mv "$f" "$_src" 2>/dev/null && { _n=$((_n+1)); log "cloud_guard: returned -> $_src"; continue; }
    fi
    for d in $CLOUD_DIRS; do
      if [ -d "$d" ]; then
        mv "$f" "$d/$_orig" 2>/dev/null && { _n=$((_n+1)); log "cloud_guard: returned -> $d/$_orig"; break; }
      fi
    done
  done
  # 归还完清掉累计计数，避免"关掉后仍显示拦截过 N 个"
  st_write off 0
  echo "$_n"
}

cmd_status() {
  _cg=$(cfg_get cloud_guard 1)
  if [ "$_cg" = "1" ]; then _s="开"; _lv="v1h"; else _s="关"; _lv="v1g"; fi
  _lc=$(st_get last_check); [ -n "$_lc" ] || _lc="-"
  _lr=$(st_get last_result)
  _bt=$(st_bt)
  case "$_lr" in
    clean) _rl="正常" ;;
    blocked) _rl="⚠有拦截" ;;
    off) _rl="(未启用)" ;;
    *) _rl="待巡检" ;;
  esac
  echo "云控屏蔽 : ${_s} (${_lv}) | 巡检:${_lc} ${_rl} | 累计拦截:${_bt}"
  echo "当前载荷 : $(basename "$BAA_SRC") [$(hash_of "$BAA_SRC" | cut -c1-12)…] 挂载=$(baa_state_cn)"
  echo "云端目录 : $(scan_count) 个文件待检 | 隔离区 $(ls -1 "$QDIR" 2>/dev/null | grep -v '^_sources.log$' | wc -l) 个"
}

watch_start() {
  # v2.6.23：改用 xbt_pids（pgrep），并排除自身 pid，避免"自己匹配自己"导致永不启动
  _others=$(xbt_pids 'HyperOS_XJ/battery/scripts/cloud_guard\.sh watch' 'HyperOS_XJ/battery/scripts/cloud_guard.sh watch' | grep -v "^$$\$")
  if [ -z "$_others" ]; then
    ( setsid sh $XBT/scripts/cloud_guard.sh watch >/dev/null 2>&1 < /dev/null & )
    log "cloud_guard: watch started"
  fi
}

case "$1" in
  status)
    cmd_status
    ;;
  on)
    cfg_set cloud_guard 1
    log "cloud_guard: switch ON (v1h)"
    _pick=$(baa_refresh_src 2>&1)
    _out=$(sh $XBT/scripts/baa_ops.sh mount 2>&1); _rc=$?
    setprop ctl.restart batteryantiaging 2>/dev/null
    echo "$_out" >> "$LOG"
    if [ "$_rc" != "0" ]; then
      echo "⚠ 云控屏蔽开启：载荷重挂载失败 rc=$_rc（详见日志）"
      echo "$_out" | tail -n 3
      exit 1
    fi
    watch_start
    echo "✓ 云控屏蔽已开启 (v1h)"
    echo "载荷: $_pick [$(hash_of "$BAA_SRC" | cut -c1-12)…] 挂载=$(baa_state_cn)"
    ;;
  off)
    cfg_set cloud_guard 0
    log "cloud_guard: switch OFF (v1g)"
    # v2.7.13：关闭时【归还】之前隔离的文件（旧版不归还，导致文件永久滞留 + 越攒越多）
    _ret=$(restore_quarantine)
    _pick=$(baa_refresh_src 2>&1)
    _out=$(sh $XBT/scripts/baa_ops.sh mount 2>&1); _rc=$?
    setprop ctl.restart batteryantiaging 2>/dev/null
    echo "$_out" >> "$LOG"
    if [ "$_rc" != "0" ]; then
      echo "⚠ 云控屏蔽关闭：载荷重挂载失败 rc=$_rc（详见日志）"
      echo "$_out" | tail -n 3
      exit 1
    fi
    echo "✓ 云控屏蔽已关闭 (v1g)"
    echo "归还云端文件: ${_ret} 个"
    echo "载荷: $_pick [$(hash_of "$BAA_SRC" | cut -c1-12)…] 挂载=$(baa_state_cn)"
    ;;
  check)
    _cg=$(cfg_get cloud_guard 1)
    if [ "$_cg" != "1" ]; then echo "云控屏蔽已关闭，巡检不执行。"; exit 0; fi
    do_check
    ;;
  restore)
    _ret=$(restore_quarantine)
    echo "归还云端文件: ${_ret} 个"
    ;;
  early)
    _cg=$(cfg_get cloud_guard 1)
    [ "$_cg" = "1" ] || exit 0
    do_check quiet
    ;;
  watch)
    _tick=0
    while true; do
      _cg=$(cfg_get cloud_guard 1)
      if [ "$_cg" = "1" ]; then
        do_check quiet >/dev/null 2>&1
      else
        st_write off "$(st_bt)"
      fi
      # BAA 挂载巡检（独立于云控开关，每 ~5 分钟一次）：
      # 应对 mid-session 系统替换 /odm、OTA 残留等导致 bind mount 失效的情况。
      # freepps 进程保活（v2.6.22i：进程被杀后 <=1 分钟自动复活）
      [ "$(cfg_get freepps 0)" = "1" ] && sh $XBT/scripts/freepps.sh ensure >/dev/null 2>&1
      _tick=$((_tick+1))
      if [ $((_tick % 5)) -eq 0 ] && [ "$(cfg_get unlock 1)" = "1" ] && [ "$(baa_state)" = "inactive" ]; then
        log "cloud_guard: BAA inactive detected, remounting"
        baa_refresh_src >/dev/null 2>&1
        sh $XBT/scripts/baa_ops.sh mount >>"$LOG" 2>&1
      fi
      sleep 60
    done
    ;;
  *)
    echo "usage: cloud_guard.sh status|on|off|check|early|watch"
    ;;
esac