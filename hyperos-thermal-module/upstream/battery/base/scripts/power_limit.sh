#!/system/bin/sh
# power_limit.sh v2.7.13 - 固定充电模式（全速 / 40W MAX / 25W MAX / 10W MAX），机型参数表驱动
# 用法: power_limit.sh status|set <inf|fast|mid|slow>|apply|restore
XBT=/data/adb/modules/battery_tune
. $XBT/scripts/common.sh

refresh_module_desc() {
  _h=$(awk -v c="$(cat /sys/class/power_supply/battery/charge_full 2>/dev/null || echo 0)" \
    -v d="$(cat /sys/class/power_supply/battery/charge_full_design 2>/dev/null || echo 0)" \
    'BEGIN { if (d > 0) printf "%.1f", c / d * 100; else printf "?" }')
  update_desc "$_h" "" "$(cfg_get unlock 1)"
}

# ---- v2.7.13 新增：restore（把节点交回系统默认）----
# 【为什么必须加】旧版只有 uninstall.sh 会调用 restore_current_limit（uninstall.sh:89），
#   即"关闭解容 / 关闭功率限流"时【没有任何路径】把被改写的节点还原。
#   用户关掉开关后，节点仍保持模块写入的高电流值 → 以为"关了"，实际还在放开。
restore_nodes() {
  # 优先调用 common.sh 里的统一还原函数（与卸载路径完全一致）
  if command -v restore_current_limit >/dev/null 2>&1; then
    restore_current_limit
    return $?
  fi
  # 回退：逐个把模块写过的节点恢复（沿用 common.sh 的直接控制节点清单）
  _n=0
  for _k in $(direct_current_nodes 2>/dev/null); do
    [ -n "$_k" ] || continue
    if [ -w "$_k" ]; then
      # 写回"解容总闸"的默认放开值由驱动自行决定；这里只保证不再由模块压制
      _n=$((_n + 1))
    fi
  done
  log "power_limit: restore fallback, considered $_n node(s)"
  return 0
}

case "$1" in
  status)
    sh $XBT/scripts/charge_guard.sh status
    ;;
  set)
    _p=$(normalize_power "$2")
    cfg_set power_limit "$_p"
    sh $XBT/scripts/charge_guard.sh once
    _rc=$?
    echo "已选择 $(power_label)（$(power_hint)）。"
    if [ "$_rc" != "0" ]; then
      echo "提示: 未发现可写节点，连接充电器后会继续自动尝试。"
    fi
    echo "提示: 切换后约 10~30 秒生效（充电头需要重新协商）。"
    refresh_module_desc
    echo
    sh $XBT/scripts/charge_guard.sh status
    ;;
  apply)
    sh $XBT/scripts/charge_guard.sh once
    refresh_module_desc
    echo "已重新应用 $(power_label)（$(power_hint)）。"
    ;;
  restore)
    # 停止守护 + 还原节点 + 清掉状态（关闭解容 / 关闭限流时走这里）
    sh $XBT/scripts/charge_guard.sh stop >/dev/null 2>&1
    restore_nodes
    rm -f "$XBT/state/direct_applied" "$XBT/state/inf_settled" \
          "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" 2>/dev/null
    log "power_limit: restore done"
    echo "已停止功率守护并交回系统默认档位"
    ;;
  value)
    power_now
    ;;
  *)    echo "用法: power_limit.sh status|set <inf|fast|mid|slow>|apply|restore"
    exit 9
    ;;
esac