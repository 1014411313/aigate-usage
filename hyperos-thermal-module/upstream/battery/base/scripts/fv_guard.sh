#!/system/bin/sh
# 电池解容工具箱 - smart_fv 0V 守护（inotify秒级 + 10s轮询双保险）
# v2: 改用 setsid 独立会话启动，即使从 WebUI/终端触发的“同步”重启守护，
#     也不会随调用方会话结束被系统连带回收
# 用法: fv_guard.sh start|stop|status
XBT=/data/adb/modules/battery_tune
. $XBT/scripts/common.sh

PIDFILE=/data/local/tmp/xt_fv_guard.pid
HANDLER=$XBT/scripts/fv_handler.sh

# 判断 pid 是否真的是本守护进程（防 PID 复用造成的“假存活”）。
_guard_alive() {
  _p="$1"
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_p" 2>/dev/null || return 1
  # v2.6.23：加超时保护（读 /proc/<pid>/cmdline 在该进程退出瞬间会永久阻塞）
  _cl=$(timeout 1 cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')
  case "$_cl" in
    *fv_guard*|*fv_handler*|*inotifyd*) return 0 ;;
  esac
  return 1
}

_spawn() {
  # 首次记录系统原始值（卸载时还原用）
  #
  # ===== v2.9.5 【修复：快照值会被自己污染】=====
  # 【背景 · 先明确 smart_fv 是什么】它是【满充降压量(mV)】：
  #     smart_fv = 30~40 → 满充电压降 30~40mV → 少充一点 → 厂商的【电池抗老化】保护
  #     smart_fv = 0     → 不降压 → 充到满电压 → 【解容】（= 本模块的目的）
  #   所以"把 smart_fv 压成 0"是【模块的正常功能】，不是 bug。
  # 【真问题在"快照"这一步】service.sh 的启动顺序是【先挂 BAA、后启 fv_guard】：
  #     ① BAA 挂载 → 模块载荷 "smart_fv":{"value":0} → 系统服务把节点写成 0
  #     ② 紧接着 fv_guard 启动 → `cat $FV_NODE` 读到 0 → 把 0 记成"系统原始值"
  #   而原厂载荷 stock_BAA_config_*.json 实测是 value=[30,40]（13/14 机型非 0），
  #   叠加 customize.sh 的 state 迁移白名单含 fv_default → 污染值跨版本永久携带。
  # 【后果】卸载时 uninstall.sh 把这 0 写回节点 → 原厂的 30/40 降压保护【永久丢失】，
  #   用户以为"还原干净了"（说明文件还写"已自动还原"），实际电池抗老化被关掉了。
  #   这与 direct_control_defaults 的快照污染完全同型（v2.9.4 修了那个，漏了这个）。
  # 【修法】卸载还原的目标应是【原厂值】而不是"启动那一刻的节点值"。
  #   ① 明文载荷 → 从 stock 里 grep smart_fv.value（取最大值）
  #   ② 密文载荷（本机即是 BAA_ENC:）→ 回落内置表：原厂档位实测 13/14 机型为 30 或 40，
  #      取 40（保守：最接近"完全未降压"的原厂档位，且在实测取值范围内）
  #   ③ 都拿不到 → 才回落到节点当前值，并标注 source=node 便于排查
  #   ★ 注意：fv_default 只用于【卸载还原】，运行期从不用它写节点，
  #     因此本修复【完全不影响解容功能】（解容仍由 fv_guard 把节点压 0）。
  if [ ! -f "$XBT/state/fv_default" ]; then
    mkdir -p "$XBT/state" 2>/dev/null
    _fv0=""; _src=""
    if [ -f "$BAA_STOCK" ]; then
      _raw0=$(cat "$BAA_STOCK" 2>/dev/null)
      case "$_raw0" in
        BAA_ENC:*) : ;;                      # 密文载荷，shell 读不出明文
        *)
          _fv0=$(printf '%s' "$_raw0" | grep -o '"smart_fv"[^}]*"value":[0-9]*' 2>/dev/null | \
                 grep -o '[0-9]*$' | sort -n | tail -n 1)
          [ -n "$_fv0" ] && _src="stock"
          ;;
      esac
    fi
    if [ -z "$_fv0" ]; then
      # 内置原厂档位表（依据 14 机型 stock 载荷实测：bixi/onyx=40，其余=30/40）
      case "$DEV_CODE" in
        xuanyuan|haotian|dada|nezha|myron|annibale|bixi|onyx|popsicle|miro|songyuan|warsaw|pudding|pandora|byron)
          _fv0=40; _src="table" ;;
        *) : ;;
      esac
    fi
    if [ -z "$_fv0" ]; then
      _fv0=$(cat "$FV_NODE" 2>/dev/null)
      _src="node"
    fi
    case "$_fv0" in
      ''|*[!0-9]*) : ;;
      *)
        echo "$_fv0" > "$XBT/state/fv_default" 2>/dev/null
        echo "$_src" > "$XBT/state/fv_default_src" 2>/dev/null
        log "fv_guard: uninstall-restore target smart_fv=${_fv0} (source=$_src)"
        ;;
    esac
  fi
  /system/bin/inotifyd "$HANDLER" "$FV_NODE:w" >/dev/null 2>&1 &
  ( while true; do
      _v=$(cat "$FV_NODE" 2>/dev/null)
      if [ -n "$_v" ] && [ "$_v" != "0" ]; then
        echo 0 > "$FV_NODE" 2>/dev/null
        log "fv_guard: [loop] $_v -> 0"
      fi
      sleep 10
    done ) &
  echo $! > "$PIDFILE"
  log "fv_guard: started pid=$(cat $PIDFILE)"
  echo "started (pid $(cat $PIDFILE))"
}

start_guard() {
  if [ -f "$PIDFILE" ]; then
    _p=$(cat "$PIDFILE" 2>/dev/null)
    if _guard_alive "$_p"; then
      echo "already running (pid $_p)"
      return 0
    fi
    # 残留 / 失效 pid（含跨重启 PID 复用）→ 清掉后重新启动。
    rm -f "$PIDFILE"
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$XBT/scripts/fv_guard.sh" _spawn >/dev/null 2>&1
    _t=0
    while [ "$_t" -lt 5 ]; do
      sleep 1
      _t=$((_t+1))
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
  for _q in $(timeout 5 pgrep -f "$HANDLER" 2>/dev/null); do
    kill -9 "$_q" 2>/dev/null
  done
  log "fv_guard: stopped"
  echo "stopped"
}

status_guard() {
  _fv=$(cat "$FV_NODE" 2>/dev/null)
  if [ -f "$PIDFILE" ] && _guard_alive "$(cat "$PIDFILE" 2>/dev/null)"; then
    echo "running (pid $(cat $PIDFILE), fv=$_fv)"
  else
    echo "not running (fv=$_fv)"
  fi
}

case "$1" in
  start) start_guard ;;
  _spawn) _spawn ;;
  stop) stop_guard ;;
  status) status_guard ;;
  *) echo "usage: $0 start|stop|status"; exit 9 ;;
esac