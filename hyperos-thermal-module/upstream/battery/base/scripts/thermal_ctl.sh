#!/system/bin/sh
# thermal_ctl.sh v1.0 - 温控守护控制（供 WebUI/终端）
# 用法: thermal_ctl.sh status | on | off | ensure | restore-now | set <limit N|hyst N|action slow|mid|fast|stop>
XBT=/data/adb/modules/battery_tune
. $XBT/scripts/common.sh
BAT=/sys/class/power_supply/battery
BT=/sys/class/xm_power/charger/smart_charge/board_temp

act_cn() {
  # v2.7：新增 fast（40W）档；文案改为用户视角，说明"压到哪一档"
  case "$1" in
    slow) echo "压到【慢充 ${SLOW_W:-10}W】" ;;
    mid)  echo "压到【中速 ${MID_W:-25}W】" ;;
    fast) echo "压到【快充 ${FAST_W:-40}W】" ;;
    stop) echo "压到【停充约 2W】" ;;
    *)    echo "$1" ;;
  esac
}
# 一句话人话解释（给完全不懂的用户看）
act_plain() {
  case "$1" in
    slow) echo "电池一到温度上限，就把充电降到 ${SLOW_W:-10}W 慢充，降温后再自动恢复原档" ;;
    mid)  echo "电池一到温度上限，就把充电降到 ${MID_W:-25}W 中速，降温后再自动恢复原档" ;;
    fast) echo "电池一到温度上限，就把充电降到 ${FAST_W:-40}W 快充，降温后再自动恢复原档" ;;
    stop) echo "电池一到温度上限，就几乎停止充电（约 2W），降温后再自动恢复原档" ;;
    *)    echo "$1" ;;
  esac
}

# 档位中文名（用于恢复提示）
tier_cn() {
  case "$1" in
    inf)  echo "全速（${DEV_MAXW}W MAX）" ;;
    fast) echo "快充（${FAST_W:-40}W）" ;;
    mid)  echo "中速（${MID_W:-25}W）" ;;
    slow) echo "慢充（${SLOW_W:-10}W）" ;;
    *)    echo "$1" ;;
  esac
}

read_vals() {
  T_LIMIT=$(cfg_get thermal_limit 45)
  T_HYST=$(cfg_get thermal_hyst 4)
  T_ACT=$(cfg_get thermal_action slow)
  case "$T_LIMIT" in ''|*[!0-9]*) T_LIMIT=45 ;; esac
  case "$T_HYST" in ''|*[!0-9]*) T_HYST=4 ;; esac
  case "$T_ACT" in slow|mid|fast|stop) ;; *) T_ACT=slow ;; esac
}

guard_pids() {
  # v2.6.23 关键修复：旧实现用 `for p in /proc/[0-9]*; do tr '\0' ' ' < $p/cmdline` 扫描，
  #   而**进程在扫描瞬间退出时读 /proc/<pid>/cmdline 会永久阻塞**（内核已知行为）。
  #   实测：900+ 进程时 10 秒只扫到 300 个，且 thermal_ctl.sh on 直接卡死 5 分钟不返回。
  #   改用 toybox/busybox 的 pgrep（瞬时且原子），并用 timeout 兜底。
  if command -v pgrep >/dev/null 2>&1; then
    timeout 5 pgrep -f 'battery_tune/scripts/thermal_guard\.sh' 2>/dev/null | grep -v "^$$\$"
  else
    # 极老设备无 pgrep 时的降级实现：每次读取都带超时，避免永久阻塞
    for _p in /proc/[0-9]*; do
      _pid=${_p#/proc/}
      [ "$_pid" = "$$" ] && continue
      case "$(timeout 1 cat "$_p/cmdline" 2>/dev/null | tr '\0' ' ')" in
        *battery_tune/scripts/thermal_guard.sh*) echo "$_pid" ;;
      esac
    done
  fi
}
is_running() {
  [ -n "$(guard_pids)" ]
}

ensure_running() {
  if ! is_running; then
    ( setsid sh $XBT/scripts/thermal_guard.sh >/dev/null 2>&1 < /dev/null & )
    log "thermal_ctl: guard (re)started"
    echo "守护进程已启动"
  fi
}

case "$1" in
  status)
    read_vals
    _en=$(cfg_get thermal_guard 0)
    t1=$(cat $BAT/temp 2>/dev/null); case "$t1" in ''|*[!0-9]*) t1=0 ;; esac
    t2=$(cat $BT 2>/dev/null);  case "$t2" in ''|*[!0-9]*) t2=0 ;; esac
    _snap=0; [ -f $XBT/state/thermal_prev ] && _snap=1
    if is_running; then _rs=1; else _rs=0; fi
    # ---- 主状态行（用户最关心：现在开没开、有没有在保护）----
    if [ "$_en" != "1" ]; then
      echo "温控守护 : ⭕ 已关闭 —— 不会自动降档（电池过热由系统自己处理）"
    elif [ "$_snap" = "1" ]; then
      _tier=$(grep '^tier=' $XBT/state/thermal_prev 2>/dev/null | cut -d= -f2)
      echo "温控守护 : 🔴 保护中 —— 已把充电压到【$(tier_cn "$T_ACT")】，等降温后自动恢复到【$(tier_cn "${_tier:-inf}")】"
    elif [ "$_rs" = "1" ]; then
      echo "温控守护 : 🟢 已开启（守候中，未触发）"
    else
      echo "温控守护 : 🟡 已开启但进程未运行 —— 请关闭再打开一次，或重启手机"
    fi
    echo ""
    # ---- 当前温度与距离阈值 ----
    _gap=$(( T_LIMIT * 10 - t1 ))
    awk -v a="$t1" -v b="$t2" 'BEGIN{printf "当前温度 : 电池 %.1f°C  /  主板 %.1f°C（判据=电池，主板仅参考）\n", a/10, b/10}'
    if [ "$_gap" -gt 0 ]; then
      awk -v g="$_gap" 'BEGIN{printf "距离触发 : 还有 %.1f°C 就到上限\n", g/10}'
    elif [ "$_snap" = "1" ]; then
      awk -v g="$(( -_gap ))" 'BEGIN{printf "距离触发 : 已超过上限 %.1f°C（正在保护）\n", g/10}'
    else
      echo "距离触发 : 已达/超过上限"
    fi
    echo ""
    # ---- 规则说明（人话）----
    echo "触发温度 : ${T_LIMIT}°C 以上 → 开始降档"
    echo "恢复温度 : ${T_LIMIT}°C 降回 $(( T_LIMIT - T_HYST ))°C 以下 → 自动还原原档位"
    echo "降档动作 : $(act_cn "$T_ACT")"
    echo "说明     : $(act_plain "$T_ACT")"
    echo "           （上面 ${T_HYST}°C 的差值叫滞回，防止在临界温度反复横跳）"
    ;;
  on)
    cfg_set thermal_guard 1
    log "thermal_ctl: guard=1"
    echo "温控守护已开启（配置热读取，≤10秒生效）"
    ensure_running
    ;;
  off)
    # v1.4：关闭守护必须**自己**完成恢复，不能依赖守护进程
    #   （守护可能在触发后被系统杀掉/未启动，那样档位就永远卡在保护档）
    _was_triggered=0
    [ -f $XBT/state/thermal_prev ] && _was_triggered=1
    cfg_set thermal_guard 0
    if [ "$_was_triggered" = "1" ]; then
      # 若守护在跑，先让它走 force-restore 分支；否则本地补做
      if is_running; then
        _i=0
        while [ $_i -lt 16 ] && [ -f $XBT/state/thermal_prev ]; do
          sleep 0.5; _i=$((_i + 1))
        done
      fi
      if [ -f $XBT/state/thermal_prev ]; then
        sh $XBT/scripts/thermal_ctl.sh restore-now >/dev/null 2>&1
      fi
      _t=$(cfg_get power_limit inf)
      log "thermal_ctl: guard=0, restored (tier=$_t)"
      echo "温控守护已关闭（已恢复到保护前档位：$(tier_cn "$_t")）"
    else
      log "thermal_ctl: guard=0 (not triggered)"
      echo "温控守护已关闭（未处于触发状态）"
    fi
    # v2.6.23：等守护真正退场再返回 —— 旧版直接返回，调用方（含 WebUI 3 秒轮询）
    #   会立刻看到"仍显示运行中"的残留进程，造成"关了但没关掉"的错觉
    _i=0
    while [ $_i -lt 20 ]; do
      is_running || break
      sleep 0.25; _i=$((_i + 1))
    done
    if is_running; then
      # 兜底：守护未响应 exit（卡在某处）→ 强制结束
      for _k in $(guard_pids); do kill -9 "$_k" 2>/dev/null; done
      sleep 0.5
    fi
    ;;
  restore-now)
    # 强制把档位恢复到 state/thermal_prev 记录的保护前档位，然后清标记（供 off / 排障用）
    SNAP=$XBT/state/thermal_prev
    if [ -f "$SNAP" ]; then
      _tier=$(grep '^tier=' "$SNAP" | cut -d= -f2)
      _sw=$(grep '^slow_w=' "$SNAP" | cut -d= -f2)
      [ -n "$_sw" ] && sed -i "s/^slow_w=.*/slow_w=$_sw/" $XBT/config/settings.conf
      sh $XBT/scripts/power_limit.sh set "${_tier:-inf}" >/dev/null 2>&1
      rm -f "$SNAP" $XBT/state/thermal_reapply 2>/dev/null
      log "thermal_ctl: restore-now tier=${_tier:-inf}"
      echo "已恢复档位: $(tier_cn "${_tier:-inf}")"
    else
      rm -f $XBT/state/thermal_reapply 2>/dev/null
      echo "无待恢复的触发记录（档位未改动）"
    fi
    ;;
  ensure)
    read_vals
    if [ "$(cfg_get thermal_guard 0)" = "1" ]; then ensure_running; else echo "温控守护已关闭，未启动"; fi
    ;;
  set)
    _k="$2"; _v="$3"
    case "$_k" in
      limit)
        case "$_v" in ''|*[!0-9]*) echo "无效温度: $_v"; exit 1 ;; esac
        if [ "$_v" -lt 35 ] || [ "$_v" -gt 58 ]; then echo "温度范围 35~58: $_v"; exit 1; fi
        cfg_set thermal_limit "$_v"
        log "thermal_ctl: set limit=$_v"
        echo "温度上限 = ${_v}°C（≤10秒内生效）"
        ;;
      hyst)
        case "$_v" in ''|*[!0-9]*) echo "无效滞回: $_v"; exit 1 ;; esac
        if [ "$_v" -lt 1 ] || [ "$_v" -gt 10 ]; then echo "滞回范围 1~10: $_v"; exit 1; fi
        cfg_set thermal_hyst "$_v"
        log "thermal_ctl: set hyst=$_v"
        echo "恢复滞回 = ${_v}°C"
        ;;
      action)
        case "$_v" in slow|mid|fast|stop) ;; *) echo "无效动作: $_v（可选 slow|mid|fast|stop）"; exit 1 ;; esac
        cfg_set thermal_action "$_v"
        log "thermal_ctl: set action=$_v"
        echo "触发动作 = $(act_cn "$_v")（≤10秒内生效）"
        ;;
      *)
        echo "用法: thermal_ctl.sh set <limit N|hyst N|action slow|mid|fast|stop>"
        exit 9
        ;;
    esac
    ;;
  *)
    echo "用法: thermal_ctl.sh status|on|off|ensure|restore-now|set ..."
    exit 9
    ;;
esac
