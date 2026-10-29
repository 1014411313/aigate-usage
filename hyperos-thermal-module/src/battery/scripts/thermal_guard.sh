#!/system/bin/sh
# thermal_guard.sh v1.6 - 自定义温控守护（动作：slow|mid|fast|stop；restore 已移除）
#   默认 45℃：电池温度 ≥限制 → 动作（slow|mid|fast|stop）；回落 -hyst → 恢复（板温仅显示）
#   v1.6：新增 fast(40W) 档；单实例锁改为"确认旧实例仍存活才让位"，消除启动竞态
# 配置: thermal_guard=1(0关) / thermal_limit=45 / thermal_hyst=4 / thermal_action=slow
#
# v1.5 修复（用户反馈"关了温控守护功率一直上不去"）：
#   ① 关闭守护时**无条件恢复**保护前档位并退出进程
#      旧版只在"当前档 == 保护动作档"时才恢复，用户手动改过档就永远回不去（卡死）
#   ② 温度回落恢复时仍尊重用户手动改档；**关闭守护时不再"尊重"**（否则无法回退）
#   ③ 关闭守护→恢复完成即 exit，不再常驻空转；重开由 thermal_ctl.sh 拉起
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh
BAT=/sys/class/power_supply/battery
BT=/sys/class/xm_power/charger/smart_charge/board_temp
SNAP=$XBT/state/thermal_prev
SILENT=$XBT/state/thermal_restore_active
read_cfg() {
  LIMIT=$(cfg_get thermal_limit 45); HYST=$(cfg_get thermal_hyst 4); ACT=$(cfg_get thermal_action slow)
  case "$LIMIT" in ''|*[!0-9]*) LIMIT=45 ;; esac
  case "$HYST" in ''|*[!0-9]*) HYST=4 ;; esac
  case "$ACT" in slow|mid|fast|stop) ;; *) ACT=slow ;; esac
  lim10=$((LIMIT * 10)); hys10=$((HYST * 10))
}
read_cfg
tlog() { log "thermal_guard: $*"; }
temp_batt() {
  t1=$(cat $BAT/temp 2>/dev/null); case "$t1" in ''|*[!0-9]*) t1=0 ;; esac
  echo "$t1"
}
temp_board() {
  t2=$(cat $BT 2>/dev/null);  case "$t2" in ''|*[!0-9]*) t2=0 ;; esac
  echo "$t2"
}
tier_rank() {
  case "$1" in inf) echo 3 ;; fast) echo 2 ;; mid) echo 1 ;; slow) echo 0 ;; *) echo 3 ;; esac
}
action_rank() {
  # v2.7：新增 fast 档（用户要求"40W 那档也能选自动降档"）
  case "$ACT" in slow) echo 0 ;; mid) echo 1 ;; fast) echo 2 ;; stop) echo 0 ;; *) echo 3 ;; esac
}
snapshot() {
  [ -f $SNAP ] && return
  rm -f $XBT/state/thermal_reapply 2>/dev/null
  {
    echo "tier=$(power_now)"
    echo "slow_w=$(cfg_get slow_w 10)"
    echo "th=$(cat $DIRECT_WIRED_THERMAL_REMOVE 2>/dev/null)"
  } > $SNAP 2>/dev/null
}
apply_action() {
  _t="$1"
  case "$ACT" in
    slow) sh $XBT/scripts/power_limit.sh set slow >/dev/null 2>&1 ;;
    mid)  sh $XBT/scripts/power_limit.sh set mid  >/dev/null 2>&1 ;;
    fast) sh $XBT/scripts/power_limit.sh set fast >/dev/null 2>&1 ;;
    stop)
      # v1.5：改用 cfg_set（键不存在时自动 append 且带防粘连守卫）
      #   旧写法 `echo 'slow_w=2' >> settings.conf` 在末行无换行时会与末行粘连，
      #   把 `dev_code=` 粘成 `dev_code=slow_w=2` → 机型识别失败 → BAA 挂载整机失效
      # v2.7.13：先把原值备份到 state/thermal_slow_w_prev，保证快照丢失时也能恢复
      #   （service.sh 开机清 thermal_prev；若用户在保护生效中重启，旧版会把 slow_w 永久锁在 2）
      if [ ! -f $XBT/state/thermal_slow_w_prev ]; then
        cfg_get slow_w 10 > $XBT/state/thermal_slow_w_prev 2>/dev/null
      fi
      cfg_set slow_w 2
      sh $XBT/scripts/power_limit.sh set slow >/dev/null 2>&1
      ;;
  esac
  tlog "ON temp=$_t limit=$LIMIT action=$ACT"
}
# restore_action [force]
#   force=1（关闭守护时）：**无条件**恢复到保护前档位 —— 否则用户永远回不到原档
#   force 空（温度回落时）：若用户已手动改档（当前档≠保护动作档）则尊重用户，不改
restore_action() {
  _force="$1"
  # ===== v2.7.13 加固：快照丢失时也要把 slow_w 恢复 =====
  # 【问题】旧版第一行就是 `[ -f $SNAP ] || return`。
  #   而 service.sh 开机第 164 行会 rm -f state/thermal_prev（清开机残留），
  #   若用户在"保护生效中"重启，或快照被别处清掉，就会出现：
  #     thermal_action=stop 已把 slow_w 写成 2（apply_action 里 cfg_set 是持久化的），
  #     但保留动作时快照不在 → 直接 return → slow_w 永久停在 2
  #   → 用户从此被锁在 2W，且找不到原因。
  # 【修法】把「slow_w 恢复」独立成不依赖快照的一步：
  #   优先用快照里的原值；没有快照则用 state/thermal_slow_w_prev（apply_action 写入的备份）；
  #   两者都没有时兜底回默认 10。
  _sw=""
  if [ -f $SNAP ]; then
    _sw=$(grep '^slow_w=' $SNAP | cut -d= -f2)
  fi
  if [ -z "$_sw" ]; then
    _sw=$(cat $XBT/state/thermal_slow_w_prev 2>/dev/null)
    [ -n "$_sw" ] && tlog "restore: snapshot missing, slow_w from prev-backup = $_sw"
  fi
  case "$ACT" in
    stop)
      if [ -n "$_sw" ]; then
        sed -i "s/^slow_w=.*/slow_w=$_sw/" $XBT/config/settings.conf
      elif [ ! -f $SNAP ]; then
        # 连备份都没有：回到默认 10W，绝不把用户留在 2W
        sed -i "s/^slow_w=.*/slow_w=10/" $XBT/config/settings.conf
        tlog "restore: no snapshot & no backup -> slow_w reset to default 10"
      fi
      rm -f $XBT/state/thermal_slow_w_prev 2>/dev/null
      ;;
  esac
  [ -f $SNAP ] || { tlog "restore: nothing else to do (no snapshot)"; return; }
  _tier=$(grep '^tier=' $SNAP | cut -d= -f2)
  _sw=$(grep '^slow_w=' $SNAP | cut -d= -f2)
  case "$ACT" in
    slow|mid|fast|stop)
      [ -n "$_sw" ] && sed -i "s/^slow_w=.*/slow_w=$_sw/" $XBT/config/settings.conf
      case "$ACT" in slow|stop) _expect=slow ;; mid) _expect=mid ;; fast) _expect=fast ;; esac
      if [ "$_force" = "1" ]; then
        _was=$(power_now)
        sh $XBT/scripts/power_limit.sh set "${_tier:-mid}" >/dev/null 2>&1
        tlog "OFF force-restore tier=${_tier:-mid} (was $_was)"
      elif [ "$(power_now)" = "$_expect" ]; then
        sh $XBT/scripts/power_limit.sh set "${_tier:-mid}" >/dev/null 2>&1
      else
        tlog "restore: tier kept (user=$(power_now), expect=$_expect)"
      fi
      ;;
  esac
  rm -f $SNAP
  rm -f $XBT/state/thermal_reapply 2>/dev/null
  tlog "OFF restored"
}
# 启动自检：
#  ① 单实例锁（v2.6.23）：同一时刻只允许一个守护在跑，避免重复启动导致档位互相打架
#  ② 开关已关但仍有残留保护标记 → 无条件恢复后退出（防"关了守护功率上不去"）
#  ③ 清理残留静默标记（防止 charge_guard 被永久静默）
PIDFILE=/data/local/tmp/xt_thermal_guard.pid
# v2.6.23：单实例保护 —— 只在**确认旧实例仍存活**时让位，并给它 1.5 秒退场时间。
#   旧写法"看到别的 pid 就退出"存在竞态：旧实例已被 kill 但尚未完全消失时新实例会自杀，
#   导致没人处理残留快照、守护形同未启动（实测 T2/T3 复现）。
#   若等待后旧实例仍在，则让位退出（旧实例会正常处理快照），避免两实例互相打架。
_me=$$
if command -v pgrep >/dev/null 2>&1; then
  _other=""
  for _w in 1 2 3; do
    _other=""
    for _p in $(timeout 5 pgrep -f 'HyperOS_XJ/battery/scripts/thermal_guard\.sh' 2>/dev/null); do
      [ "$_p" = "$_me" ] && continue
      kill -0 "$_p" 2>/dev/null && _other="$_p" && break
    done
    [ -z "$_other" ] && break
    sleep 0.5
  done
  if [ -n "$_other" ]; then
    tlog "another guard alive (pid $_other), yielding self=$_me"
    exit 0
  fi
fi
echo "$_me" > "$PIDFILE" 2>/dev/null
# 退出时清理 pidfile（仅当仍属于自己）
trap 'rm -f "$PIDFILE" 2>/dev/null' EXIT INT TERM

if [ "$(cfg_get thermal_guard 0)" != "1" ]; then
  if [ -f $SNAP ]; then
    tlog "startup: guard=0 but thermal_prev exists -> force restore then exit"
    restore_action 1
  fi
  rm -f $SILENT 2>/dev/null
  tlog "startup: guard disabled, exiting (pid $$)"
  exit 0
fi
if [ ! -f $SNAP ] && [ -f $SILENT ]; then
  rm -f $SILENT 2>/dev/null
fi
tlog "started (pid $$, limit=${LIMIT}C hyst=${HYST}C action=$ACT)"
_m=0
while true; do
  EN=$(cfg_get thermal_guard 0)
  read_cfg
  if [ "$EN" != "1" ]; then
    # v1.5：关闭守护 = 无条件恢复到保护前档位，然后退出（不再常驻空转）
    if [ -f $SNAP ]; then
      tlog "guard turned off -> force restore"
      restore_action 1
    fi
    rm -f $SILENT 2>/dev/null
    tlog "guard off, exiting (pid $$)"
    exit 0
  fi
  _tb=$(temp_batt); _td=$(temp_board)
  if [ -f $SNAP ]; then
    if [ "$_tb" -le $((lim10 - hys10)) ]; then
      restore_action
    else
      # v1.3：触发期间档位被手动调得更激进 -> 节流重压（守护优先；要强行快充请关闭温控开关）
      # v2.7.4：case 原先漏了 fast —— action_rank 里虽已定义 `fast) echo 2`，但因这里不匹配，
      #   选了「降到快充」的用户在保护期把档位调回全速时，守护**不会**压回（slow/mid/stop 都会），
      #   保护静默失效直到温度回落。补上 fast。
      case "$ACT" in
        slow|mid|fast|stop)
          _cur=$(power_now)
          if [ "$(tier_rank "$_cur")" -gt "$(action_rank)" ]; then
            _last=$(cat $XBT/state/thermal_reapply 2>/dev/null)
            case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
            _now=$(date +%s)
            if [ $((_now - _last)) -ge 30 ]; then
              echo "$_now" > $XBT/state/thermal_reapply 2>/dev/null
              tlog "re-apply: tier=$_cur -> $ACT"
              apply_action "$_tb"
            fi
          fi
          ;;
      esac
    fi
  else
    if [ "$_tb" -ge "$lim10" ]; then
      snapshot
      apply_action "$_tb"
    fi
  fi
  _m=$((_m + 1))
  [ $((_m % 6)) -eq 0 ] && tlog "watch batt=$_tb board=$_td limit=${LIMIT}C action=$ACT state=$([ -f $SNAP ] && echo ON || echo off)"
  sleep 10
done