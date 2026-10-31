#!/system/bin/sh
# apl_ctl.sh —— 自适应功率爬坡器控制  v3.12.0
# 用法: apl_ctl.sh status | reset | boost | freeze
XBT=/data/adb/modules/HyperOS_XJ/battery
DEV=$(grep -a '^dev_code=' $XBT/config/settings.conf 2>/dev/null | head -n1 | cut -d= -f2)
[ -n "$DEV" ] || DEV=$(getprop ro.product.device)
PROF="$XBT/state/apl_profile.$DEV.kv"
case "$1" in
  status)
    echo "档案: $PROF"
    [ -f "$PROF" ] && cat "$PROF" || echo "  (无)"
    echo "当前目标: $(cat $XBT/state/apl_target_ma 2>/dev/null) mA"
    echo "进程: $(cat $XBT/state/apl.pid 2>/dev/null)"
    ;;
  reset)
    # 清空学习档案（保留适配器指纹无效，下次自动重建）
    echo "_reset_$(date +%s)=manual" > "$PROF" 2>/dev/null
    rm -f "$XBT/state/apl_lock_until" "$XBT/state/apl_urgent" 2>/dev/null
    echo "✅ APL 学习档案已清空，下次插枪从上限重新学"
    ;;
  boost)
    # 强制回到上限（不信任任何学习值，让实测自己退让）
    # 【v3.12.1 修】旧写法把 grep 和 sh -c 塞进同一个 $()，grep 的退出码被丢弃、
    #   且 . common.sh 依赖 XBT 已定义 —— 在 apl_ctl 里 XBT 已定义，但 grep 无意义。
    #   改为直接 source 后调用 dt_curr_cap_ma。
    _cap=""
    ( . $XBT/scripts/common.sh 2>/dev/null; dt_curr_cap_ma 2>/dev/null ) | {
      read -r _c; [ -n "$_c" ] && echo "$_c" > /tmp/.apl_cap_$$ 2>/dev/null
    }
    [ -f /tmp/.apl_cap_$$ ] && { _cap=$(cat /tmp/.apl_cap_$$ 2>/dev/null); rm -f /tmp/.apl_cap_$$ 2>/dev/null; }
    [ -n "$_cap" ] || _cap=17600
    echo "$_cap" > "$XBT/state/apl_target_ma" 2>/dev/null
    rm -f "$XBT/state/apl_lock_until" 2>/dev/null
    echo 1 > "$XBT/state/apl_urgent" 2>/dev/null
    echo "✅ 已强制回到上限 ${_cap}mA（给不上会自动退让）"
    ;;
  freeze)
    rm -f "$XBT/state/apl_target_ma" 2>/dev/null
    echo "✅ 已清除 APL 目标（charge_guard 退回 DTBO 上限，APL 下轮重写）"
    ;;
  *) echo "用法: $0 status|reset|boost|freeze"; exit 9 ;;
esac
