#!/system/bin/sh
# 电池解容工具箱 - late_start service
XBT=/data/adb/modules/battery_tune
. $XBT/scripts/common.sh

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 90 ]; do
  sleep 2; i=$((i+1))
done
# ============================================================================
# v3.0.1-xyexp-mix：卡死 `tr` 清理（移植自 v3.4.4，并加周期化）
#   根因：读 /proc/<pid>/cmdline 时目标进程恰好退出 → read 永久阻塞 → 裸 tr 卡死
#         烧 CPU → 设备进不了 Doze → 待机大量掉电（实测单条 tr 烧 5 小时 CPU）
#   判据：ppid=1（父 shell 已退出，孤儿）且 累计 CPU ≥ 600s
#         —— 正常 tr 活不到 10 分钟 CPU，命中即卡死；也不会误杀用户自己跑的 tr
# 开机清一次。周期复查交给 charge_guard 主循环
#   （不用匿名 subshell：uninstall 无法定位它，卸载后会永久残留）
xbt_clean_stuck_tr

log "service: start (boot_completed=$(getprop sys.boot_completed), waited ${i}x2s)"

UNLOCK=$(cfg_get unlock 1)
FV=$(cfg_get fv_guard 1)
PSSD=$(cfg_get pss_disable 1)

# 1. BAA 挂载
if [ "$UNLOCK" = "1" ]; then
  _st=$(sh $XBT/scripts/baa_ops.sh check 2>/dev/null)
  case "$_st" in
    active) log "service: baa active" ;;
    skipped) log "service: baa skipped (target empty) [v3.9.9 起此分支已不产生，空BAA会照常挂载]" ;;
    *)
      log "service: baa state=$_st, retry mount"
      baa_refresh_src >/dev/null 2>>"$LOG"
      sh $XBT/scripts/baa_ops.sh mount >>"$LOG" 2>&1
      ;;
  esac
else
  sh $XBT/scripts/baa_ops.sh umount >>"$LOG" 2>&1
fi

# 2. smart_fv 守护
if [ "$UNLOCK" = "1" ] && [ "$FV" = "1" ]; then
  sh $XBT/scripts/fv_guard.sh start >>"$LOG" 2>&1
else
  sh $XBT/scripts/fv_guard.sh stop >>"$LOG" 2>&1
fi

# 3. 低电量锁容服务（PSS）
# ===== v2.9.10【不再默认禁用 PSS —— 它会让「电池健康度」不显示】=====
# 【真机实测（xuanyuan，2026-10-17）】
#   禁用 com.miui.powercenter.provider.PowerSaveService 后：
#     · 承载电池健康度计算的 com.miui.securitycenter.remote 进程不会启动
#     · BatteryHealthUtils 一行日志都不输出 → 设置里的「电池健康度」无数据/不显示
#     · 手动 `pm enable` 该组件后 5 秒内立即恢复：
#         isBatteryLifeFunctionSupported: true
#         getBatterySoh: 95 / getBatteryCycleCount: 20
#         batteryHealthByUsingTime/byCycleCount/bySoh / calculateUiSohSum: 217
#   ⇒ 这就是用户反馈"刷了模块后设置里看不到电池健康度"的根因。
# 【为什么改默认】解容本身由 DTBO + BAA 完成；PSS 禁用只是边际收益，
#   却拿掉了用户可见的健康度页面，性价比为负。settings.conf 默认已改为 0。
# 【兼容】仍想禁用的用户把 pss_disable 设为 1 即可（模块照旧执行）。
# 【还原】新增 pss_disabled_by_module 标记：只有【模块亲手】把 enabled→disabled
#   才写这个标记，卸载时据此决定是否还原（避免像旧版那样因 pss_initial=disabled
#   的污染快照而永久不还原）。
#   （PSSD 已在本文件顶部 L14 赋值）
_ps=$(pss_state)
# 首次记录安装前初始状态（卸载时按此还原；此后不再更新）
if [ ! -f "$XBT/state/pss_initial" ] && [ -n "$_ps" ]; then
  mkdir -p "$XBT/state" 2>/dev/null
  echo "$_ps" > "$XBT/state/pss_initial" 2>/dev/null
fi
if [ "$PSSD" = "1" ]; then
  # v2.9.10：支持"动态模式"—— pss_low_soc>0 时只在低电量禁用 PSS，
  #   非低电量启用 → 电池健康度可正常显示（详见 common.sh 的 pss_guard_tick 注释）
  _pss_low=$(cfg_get pss_low_soc 0)
  case "$_pss_low" in ''|*[!0-9]*) _pss_low=0 ;; esac
  if [ "$_pss_low" -gt 0 ] 2>/dev/null; then
    pss_guard_tick
    log "service: PSS dynamic mode (low_soc=${_pss_low}%, now=$(pss_state))"
  elif [ "$_ps" != "disabled" ]; then
    pm disable "$PSS" >>"$LOG" 2>&1
    # 只有"模块亲手禁的"才打标记 → 卸载时据此还原
    echo 1 > "$XBT/state/pss_disabled_by_module" 2>/dev/null
    rm -f "$XBT/state/pss_dynamic" 2>/dev/null
    log "service: PSS disable requested (now $(pss_state))"
  else
    log "service: PSS already disabled"
  fi
else
  # v2.9.10：pss_disable=0 时，若发现是【模块自己】禁的 → 主动解禁恢复健康度
  #   （处理"从旧版升级上来、旧版已把它禁掉"的情况，无需等用户手动操作）
  if [ "$_ps" = "disabled" ] && [ "$(cat "$XBT/state/pss_disabled_by_module" 2>/dev/null)" = "1" ]; then
    pm enable "$PSS" >>"$LOG" 2>&1
    rm -f "$XBT/state/pss_disabled_by_module" 2>/dev/null
    log "service: PSS re-enabled (was disabled by module, restore battery health)"
  elif [ "$_ps" = "disabled" ]; then
    # 安装前就是禁用状态（用户自主/其他工具）→ 不动它，但记一条日志便于排障
    log "service: PSS disabled but not by module (left as-is; battery health may be hidden)"
  fi
fi


# 5a. 记录 FG 真实循环值
#   v2.7 修复：旧版用「只增不减」防伪装残留，但用户首次设置伪装走的是 unlock.sh，
#     那条路径不记录真实值 → 真实值当场被覆盖丢失（用户反馈：初始50→伪装20→回退成20）。
#     现在改为：
#       ① 真实值权威来源 = fg_master/qmax_cyclecount（不随伪装变化，实测稳定）
#       ② 未伪装时跟随增长（只增不减）；伪装中只做"污染纠正"，绝不把伪装值当真值
cycle_real_capture
_rc=$(cat "$CYCLE_REAL_FILE" 2>/dev/null)
log "service: real cycle = ${_rc:-未知} (qmax=$(cat $CYCLE_REAL_NODE 2>/dev/null) node=$(cat $CYCLE_NODE 2>/dev/null))"

# 5b. 循环伪装（可选，默认空=不干预）
CF=$(cfg_get cycle_fake "")
if [ -n "$CF" ]; then
  _cur=$(cat "$CYCLE_NODE" 2>/dev/null)
  if [ -n "$_cur" ] && [ "$_cur" != "$CF" ]; then
    chmod 666 "$CYCLE_NODE" 2>/dev/null
    echo "$CF" > "$CYCLE_NODE" 2>/dev/null
    log "service: cycle_fake $_cur -> $CF"
  fi
  # v2.7：同步第二节点，保证各读取端一致（部分机型该节点可写）
  if [ -e "$CYCLE_NODE2" ]; then
    _cur2=$(cat "$CYCLE_NODE2" 2>/dev/null)
    if [ -n "$_cur2" ] && [ "$_cur2" != "$CF" ]; then
      chmod 666 "$CYCLE_NODE2" 2>/dev/null
      echo "$CF" > "$CYCLE_NODE2" 2>/dev/null
    fi
  fi
fi
# 5c. 循环伪装守护（FG 回滚时自动重压；仅当设置了 cycle_fake）
if [ -n "$CF" ]; then
  sh $XBT/scripts/cycle_guard.sh start >>"$LOG" 2>&1
else
  sh $XBT/scripts/cycle_guard.sh stop >>"$LOG" 2>&1
fi
# 6. 更新模块描述
BAT=/sys/class/power_supply/battery
_HEALTH=$(awk -v c="$(cat $BAT/charge_full 2>/dev/null || echo 0)" -v d="$(cat $BAT/charge_full_design 2>/dev/null || echo 0)" 'BEGIN{ if (d>0) printf "%.1f", c/d*100; else printf "?" }')
_CYCLE=$(cat /sys/class/xm_power/fg_master/cyclecount 2>/dev/null)
[ -z "$_CYCLE" ] && _CYCLE=$(cat $BAT/cycle_count 2>/dev/null)
update_desc "$_HEALTH" "$_CYCLE" "$UNLOCK"

# 7. 日志轮转（超 2MiB 时保留最近 10000 行；日志统一出口 = WebUI「一键导出诊断包」）
_log_sz=$(wc -c < "$LOG" 2>/dev/null)
case "$_log_sz" in
  ''|*[!0-9]*) ;;
  *)
    if [ "$_log_sz" -gt 2097152 ]; then
      tail -n 10000 "$LOG" > "$LOG.rot" 2>/dev/null && mv -f "$LOG.rot" "$LOG" 2>/dev/null
      log "service: log rotated (was ${_log_sz} bytes -> keep last 10000 lines)"
    fi
    ;;
esac

# 8. 功率守护（∞/40/25/10W，按实时电压换算电流上限）
POWER_NODE=$(direct_current_nodes | head -n 1)
CUR_NODE=$(current_node)
if { [ -n "$POWER_NODE" ] && [ -w "$POWER_NODE" ]; } || { [ -n "$CUR_NODE" ] && [ -w "$CUR_NODE" ]; }; then
  mkdir -p $XBT/state 2>/dev/null
  # ===== v2.9.3 【🔴 快照时序修复】=====
  # 【问题】这两个快照是"模块接管前原值"的唯一来源，卸载时靠它们还原节点。
  #   旧版只在这里抓了 snapshot_current_limit，【没抓 snapshot_control_limit】；
  #   控制类快照实际是在 charge_guard.sh:203-204 抓的 —— 那时模块已经把
  #   wired_thermal_remove 写成 1、ctrl_limit 写成 0 了
  #   → 快照里存的是【模块自己的值】。
  #   真机实测（xuanyuan）：state/direct_control_defaults 里
  #     wired_thermal_remove|1     ← 模块写的值（驱动原厂默认是 0）
  #   → 卸载时"还原"成 1 = 温控总闸仍然放开 → 温控保护永久失效，用户看不出来。
  # 【修法】必须在 direct_set_thermal 之前抓。snapshot_* 是幂等追加
  #   （common.sh:981/995 用 `grep -qF ... && continue`），已存在则不覆盖，
  #   所以只要这次抓到真原值，后续 charge_guard 的重复调用不会再污染它。
  snapshot_current_limit "$CUR_NODE"
  snapshot_control_limit
  # 功率总闸按当前档位设置（默认 1），否则驱动温控表会把功率压到 ~2W。
  direct_set_thermal
  log "service: thermal_remove -> $(thermal_target) ($(power_label))"
else
  log "service: no writable charge-current node; thermal node left unchanged"
fi

# Re-launch so an in-place module update never keeps an old guard process.
# v2.6.23：全部改用 xbt_kill（内部走 pgrep）—— 直接扫 /proc 读 cmdline 在进程退出瞬间会永久阻塞
if [ "$UNLOCK" = "1" ]; then
  xbt_kill 'battery_tune/scripts/charge_guard\.sh' 'battery_tune/scripts/charge_guard.sh'
  ( setsid sh $XBT/scripts/charge_guard.sh >/dev/null 2>&1 < /dev/null & )
  log "service: charge_guard started (direct) for $(power_label)"
  # 【v3.9.5】重新启用 charge_guard 掉线自愈看护（v3.4.0 因 tr 裸读 proc 的 bug 被整只删除，
  #   自愈功能也一起没了）。新版 guard_watchdog.sh 改用 state/cg.pid + kill -0 判活，
  #   完全不读 /proc/<pid>/cmdline，从根上消除「toybox tr 遇 ESRCH 死循环烧满单核」那个 bug。
  sleep 2
  xbt_kill 'battery_tune/scripts/guard_watchdog\.sh' 'battery_tune/scripts/guard_watchdog.sh'
  ( setsid sh $XBT/scripts/guard_watchdog.sh >/dev/null 2>&1 < /dev/null & )
  log "service: guard_watchdog started (PID-file 模式，charge_guard 掉线自愈)"
else
  log "service: unlock=0, charge_guard not started"
fi
# 6c. cloud_guard：云控屏蔽巡检（v1.6.0）——先清理旧实例，避免重复巡检/重复计数
xbt_kill 'battery_tune/scripts/cloud_guard\.sh watch' 'battery_tune/scripts/cloud_guard.sh watch'
( setsid sh $XBT/scripts/cloud_guard.sh watch >/dev/null 2>&1 < /dev/null & )
log "service: cloud_guard watch started"
# 8.5 自适应功率爬坡器（v3.11.0）
#   让 inf 档目标不再写死 20000，而是按实测量出来的硬件上限动态调整。
#   与 charge_guard 解耦：只写 state/apl_target_ma，由 closed_loop_ma() 读取。
xbt_kill 'battery_tune/scripts/apl\.sh' 'battery_tune/scripts/apl.sh'
if [ "$(cfg_get power_limit inf)" = "inf" ]; then
  rm -f "$XBT/state/apl_target_ma" "$XBT/state/apl_lock_until" "$XBT/state/apl_urgent" 2>/dev/null
  ( setsid sh $XBT/scripts/apl.sh >/dev/null 2>&1 < /dev/null & )
  log "service: apl(自适应功率爬坡器) started"
else
  log "service: apl skipped (power_limit=$(cfg_get power_limit inf))"
fi

# 9. 温控守护（thermal_guard：到达自定义上限自动降档/还原/停止，回落自动恢复）
if [ "$(cfg_get thermal_guard 0)" = "1" ]; then
  xbt_kill 'battery_tune/scripts/thermal_guard\.sh' 'battery_tune/scripts/thermal_guard.sh'
  ( setsid sh $XBT/scripts/thermal_guard.sh >/dev/null 2>&1 < /dev/null & )
  log "service: thermal_guard started (limit=$(cfg_get thermal_limit 45)C action=$(cfg_get thermal_action slow))"
else
  xbt_kill 'battery_tune/scripts/thermal_guard\.sh' 'battery_tune/scripts/thermal_guard.sh'
  # v2.7.4：温控守护=0 时做一次残留快照清理。
  #   原先此分支只 kill，不做自检 —— 若用户在"保护中"用改配置的方式把 guard 置 0
  #   （service.sh 只 kill 不启动、thermal_ctl.sh 的 ensure 也不启动），档位会永久停在
  #   保护档且无人恢复（v1.5 修过同类症状，但只覆盖了"走 WebUI 关闭"这条路径）。
  if [ -f "$XBT/state/thermal_prev" ]; then
    _tp_tier=$(grep -a '^tier=' "$XBT/state/thermal_prev" 2>/dev/null | head -n1 | cut -d= -f2)
    case "$_tp_tier" in
      inf|fast|mid|slow)
        sh $XBT/scripts/power_limit.sh set "$_tp_tier" >>"$LOG" 2>&1
        log "service: thermal_guard=0，已从残留快照恢复档位 -> $_tp_tier"
        ;;
      *)
        # 快照里没有可识别的档位（或为空）→ 退回全速，避免卡在保护档
        sh $XBT/scripts/power_limit.sh set inf >>"$LOG" 2>&1
        log "service: thermal_guard=0，快照档位不可识别，已退回 inf"
        ;;
    esac
    rm -f "$XBT/state/thermal_prev" "$XBT/state/thermal_restore_active" 2>/dev/null
  fi
  log "service: thermal_guard disabled"
fi
# 10. 公版 PPS 解锁（FreePPS 整合；freepps=1 时启用）
sh $XBT/scripts/freepps.sh boot >>"$LOG" 2>&1

# 11. 【v2.7.12】开机清理"持久节流时间戳"
#   【为什么必须清】下面这些时间戳是【跨开机保留】的（实测 inf_settle_ts 的 mtime
#     比开机时刻早 8.5 小时），而它们唯一的用途是"距上次写入是否够 60 秒"。
#     陈旧值会让这个节流【完全失效】：
#       · inf_settle_ts  → 插枪后 (now - 陈旧值) 必然 ≥60 → 每次插枪都立即写一次 20000mA
#                          → 每次插枪触发一次 PD 重协商（正是要防的那个锯齿）
#       · inf_node_capped 标记 → 保留是对的（机型物理上限不随重启改变，故意不清）
#   注意：inf_node_capped【不清】—— 它是机型属性，清了会让每 5 分钟的
#         "写入3次失败→落旗" 循环在每次开机后重演一遍。
rm -f "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" \
      "$XBT/state/cg_last_write_ts" "$XBT/state/cg_gap_log_ts" 2>/dev/null
# inf_settled 旗【也清】：开机后充电器尚未插上，此时"已安顿"的语义无效；
#   清掉让首次插枪走一次正常的"节流写入 + 回读确认"。
#   （v2.7.5 曾因不清此旗 + 节点恰好≥10A 而永久卡低功率，见 charge_guard.sh 的注释）
rm -f "$XBT/state/inf_settled" "$XBT/state/inf_settle_fail" 2>/dev/null

# ★v3.8.1 一次性迁移：清掉旧版 bug 误判出来的 inf_node_capped
#   旧版 direct_node_read_ma_all() 把 wireless_chg_curr(恒为 20) 一起取最小值，
#   导致「inf 安顿」永远判失败 → 3 次后落 inf_node_capped=20 并永久停止补写。
#   实测 xuanyuan / nezha / haotian 全部中招（值都是 20）。
#   修好后该标记可以正常重建（真有 <10A 上限的机型会重新落旗），所以这里只清一次。
if [ -f "$XBT/state/inf_node_capped" ] && [ ! -f "$XBT/state/_mig_381_capped" ]; then
  _oc=$(cat "$XBT/state/inf_node_capped" 2>/dev/null)
  rm -f "$XBT/state/inf_node_capped" 2>/dev/null
  : > "$XBT/state/_mig_381_capped" 2>/dev/null
  log "service: v3.8.1 迁移 — 已清除旧版误判的 inf_node_capped (原值 ${_oc:-?}；无线节点被误算进最小值所致)"
fi

log "service: cleared stale throttle timestamps (inf_settle_ts/cg_last_write_ts/inf_settled)"
log "service: end"

exit 0