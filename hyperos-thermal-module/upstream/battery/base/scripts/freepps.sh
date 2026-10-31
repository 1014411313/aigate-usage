#!/system/bin/sh
# freepps.sh v1.0 - 公版 PPS 解锁（整合自 FreePPS v1.7.0，二进制已本地化路径）
# 用法: freepps.sh status | on | off | boot | ensure
# 说明: settings freepps=0/1；运行时数据目录 /data/adb/modules/freepps（free=1锁定 / 0暂停）
XBT=/data/adb/modules/battery_tune
. $XBT/scripts/common.sh
FP=/data/adb/modules/freepps
FP_FREE=$FP/free
FP_BIN=$XBT/bin/freepps

ensure_dir() {
  mkdir -p $FP 2>/dev/null
  [ -f $FP_FREE ] || printf '0' > $FP_FREE 2>/dev/null
  # ===== v2.9.3 【🔴 跨模块破坏修复】=====
  # 【旧行为】无条件 `rm -f $FP/module.prop`
  #   本意：模块在 /data/adb/modules/freepps 下建目录放状态文件（free），
  #         若该目录里出现 module.prop，KernelSU 会把它当成一个模块列出来（"幽灵模块"）。
  # 【为什么危险】如果用户【单独装了真正的 FreePPS 模块】，那个目录里本来就有
  #   合法的 module.prop —— 这行会把它删掉 → 用户的 FreePPS 模块从管理器消失。
  # 【新行为】只在"这个 module.prop 是我自己造的幽灵"时才删：
  #   判据 = 目录里【没有】真模块的启动脚本（post-fs-data.sh / service.sh）。
  if [ -f "$FP/module.prop" ]; then
    if [ ! -f "$FP/post-fs-data.sh" ] && [ ! -f "$FP/service.sh" ]; then
      rm -f "$FP/module.prop" 2>/dev/null
      log "freepps: removed self-created ghost module.prop"
    else
      log "freepps: detected REAL FreePPS module at $FP -> left untouched"
    fi
  fi
}

is_running() {
  # pgrep 快筛（主路径，内核遍历 ~几十 ms）；无 pgrep 时回退 /proc 遍历
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f 'battery_tune/bin/[f]reepps' >/dev/null 2>&1 && return 0
    return 1
  fi
  # v2.6.23：降级分支加超时保护（读 /proc/<pid>/cmdline 在进程退出瞬间会永久阻塞）
  for _p in /proc/[0-9]*; do
    case "$(timeout 1 cat $_p/comm 2>/dev/null)" in
      freepps)
        case "$(timeout 1 cat "$_p/cmdline" 2>/dev/null | tr '\0' ' ')" in
          *battery_tune/bin/freepps*) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

# restore_node —— 【v2.7.7 修复】确保关闭 PPS 时 pd_verifed 一定被还原为 0
# 【为什么需要】实测：FreePPS 二进制在 free=0 时确实会把节点写回 0，但它必须先收到
#   inotify 事件。若【进程已死】再执行 off，就没人去还原 → pd_verifed 永久卡在 1
#   （实测复现：杀进程 → off → 20 秒后仍是 1；cloud_guard 因 freepps=0 也不会拉起）。
#   节点卡在 1 的后果：官方小米头（走私有协议，不协商公版 PPS）插上后
#   「PD 已验证」门一直开着 → 协议/功率判断失真，用户以为模块把功率改乱了。
# 【做法】先把 free 文件置 0，必要时临时拉起进程让它处理一次；
#   无论进程在不在，最后都直接确认节点已归 0（节点实测可写，权限 664）。
restore_node() {
  _q=/sys/class/qcom-battery/pd_verifed
  _c=/sys/class/Charging_Adapter/pd_adapter/usbpd_verifed
  # 先确保 free=0（二进制据此暂停）
  printf '0' > $FP_FREE 2>/dev/null

  _need=0
  for _n in $_q $_c; do
    [ -e "$_n" ] || continue
    [ "$(cat "$_n" 2>/dev/null)" = "1" ] && _need=1
  done
  [ "$_need" = "0" ] && return 0     # 已是 0，无需处理

  # 进程活着 → 它会自己还原（实测 8 秒内）；给它时间
  if is_running; then
    _i=0
    while [ $_i -lt 6 ]; do
      _i=$((_i + 1))
      sleep 1
      _still=0
      for _n in $_q $_c; do
        [ -e "$_n" ] || continue
        [ "$(cat "$_n" 2>/dev/null)" = "1" ] && _still=1
      done
      [ "$_still" = "0" ] && return 0
    done
  fi

  # 进程不在（或没能在 6 秒内还原）→ 直接兜底写 0，不依赖二进制
  _ok=0
  for _n in $_q $_c; do
    [ -e "$_n" ] || continue
    chmod 664 "$_n" 2>/dev/null
    echo 0 > "$_n" 2>/dev/null && _ok=1
  done
  [ "$_ok" = "1" ] && log "freepps: pd_verifed force-restored to 0 (process was not running)"
  return 0
}

kill_legacy() {
  if command -v pgrep >/dev/null 2>&1; then
    for _k in $(timeout 5 pgrep -f 'FreePPS/bin/[F]reePPS' 2>/dev/null); do
      kill -9 "$_k" 2>/dev/null
    done
    return
  fi
  # v2.6.23：降级分支加超时保护
  for _p in /proc/[0-9]*; do
    case "$(timeout 1 cat $_p/comm 2>/dev/null)" in
      FreePPS)
        case "$(timeout 1 cat "$_p/cmdline" 2>/dev/null | tr '\0' ' ')" in
          */FreePPS/bin/FreePPS*) kill -9 "${_p#/proc/}" 2>/dev/null ;;
        esac
        ;;
    esac
  done
}

ensure_running() {
  [ -x $FP_BIN ] || { echo "二进制缺失: $FP_BIN"; return 1; }
  # 并发启动锁（mkdir 原子）：陈旧锁(>30s)自动清理；锁被占时等一拍复查，能自愈
  _lk=$XBT/state/.freepps.lock
  _owns=""
  if [ -d "$_lk" ]; then
    _age=$(( $(date +%s) - $(stat -c %Y "$_lk" 2>/dev/null || echo 0) ))
    [ "$_age" -gt 30 ] && rm -rf "$_lk" 2>/dev/null
  fi
  if mkdir "$_lk" 2>/dev/null; then
    _owns=1
  else
    # 锁被占：短暂等待后复查——对方若已拉起进程就直接返回；否则清陈旧锁重抢
    sleep 0.4
    if is_running; then return 0; fi
    rm -rf "$_lk" 2>/dev/null
    if mkdir "$_lk" 2>/dev/null; then _owns=1; else return 0; fi
  fi
  trap '[ -n "$_owns" ] && rmdir "$_lk" 2>/dev/null' EXIT
  if ! is_running; then
    ( setsid $FP_BIN >/dev/null 2>&1 < /dev/null & )
    log "freepps: process started"
    echo "FreePPS 进程已启动"
  fi
  sleep 0.3
  if ! is_running; then
    # 一次重试（慢启动/竞态兜底）
    ( setsid $FP_BIN >/dev/null 2>&1 < /dev/null & )
    sleep 0.3
    if is_running; then
      log "freepps: process restarted (2nd try)"
      echo "FreePPS 进程已启动（重试）"
    else
      log "freepps: ERROR process not running after retry"
      echo "警告: FreePPS 进程启动失败，请查看模块日志"
    fi
  fi
  rmdir "$_lk" 2>/dev/null
}

case "$1" in
  status)
    _en=$(cfg_get freepps 0)
    if [ "$_en" = "1" ]; then _ens="开启"; else _ens="关闭"; fi
    _fv=$(cat $FP_FREE 2>/dev/null)
    case "$_fv" in
      1) _fs="锁定PPS支持" ;;
      0) _fs="已暂停" ;;
      *) _fs="未初始化" ;;
    esac
    if is_running; then _rs="运行中"; else _rs="未运行"; fi
    echo "总开关 : $_ens (settings freepps=$_en)"
    echo "运行时 : $_fs (free=${_fv:-无})"
    echo "进程   : $_rs"
    echo "节点   : pd_verifed=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)"
    _pv=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)
    if [ "$_en" = "0" ] && [ "$_pv" = "1" ]; then
      echo "警告   : ⚠ 已关闭但 pd_verifed 仍为 1（残留）→ 执行 freepps.sh restore 还原"
    fi
    ;;
  on)
    cfg_set freepps 1
    ensure_dir
    printf '1' > $FP_FREE 2>/dev/null
    kill_legacy
    ensure_running
    log "freepps: ON"
    echo "公版PPS解锁已开启（含金标动画；切换/重插充电器后生效）"
    ;;
  off)
    cfg_set freepps 0
    ensure_dir
    printf '0' > $FP_FREE 2>/dev/null
    restore_node
    log "freepps: OFF"
    echo "公版PPS解锁已关闭（验证节点已还原；进程保留待命）"
    ;;
  boot)
    if [ "$(cfg_get freepps 0)" = "1" ]; then
      ensure_dir
      printf '1' > $FP_FREE 2>/dev/null
      kill_legacy
      ensure_running
      log "freepps: boot -> locked"
    else
      if [ -d $FP ]; then
        ensure_dir
        # v2.7.7：开机且配置为关时，顺带确认节点没残留（上次异常退出可能留下 1）
        restore_node
      fi
      log "freepps: boot -> paused"
    fi
    ;;
  restore)
    # v2.7.7 新增：独立还原入口 —— 供诊断/排障时把残留的 pd_verifed 清回 0
    ensure_dir
    restore_node
    echo "验证节点已还原: pd_verifed=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)"
    log "freepps: restore node -> $(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)"
    ;;
  ensure)
    ensure_dir
    if [ "$(cfg_get freepps 0)" = "1" ]; then
      [ "$(cat $FP_FREE 2>/dev/null)" = "1" ] || printf '1' > $FP_FREE 2>/dev/null
      ensure_running
    else
      if [ "$(cat $FP_FREE 2>/dev/null)" != "0" ]; then
        restore_node
      else
        # free 已是 0，但进程可能已死导致节点残留 → 直接确认一次（开销极小）
        _pv=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)
        [ "$_pv" = "1" ] && restore_node
      fi
    fi
    ;;
  *)
    echo "用法: freepps.sh status|on|off|boot|ensure|restore"
    exit 9
    ;;
esac