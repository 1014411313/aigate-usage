#!/system/bin/sh
# 电池解容工具箱 - 电池信息
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh

BAT=/sys/class/power_supply/battery
FG=/sys/class/xm_power/fg_master
get() { cat "$1" 2>/dev/null; }

CAP=$(get $BAT/capacity)
ST=$(get $BAT/status)
T=$(get $BAT/temp)
V=$(get $BAT/voltage_now)
I=$(get $BAT/current_now)
DESIGN=$(get $BAT/charge_full_design)
FULL=$(get $BAT/charge_full)
CYCFG=$(get $FG/cyclecount)
[ -z "$CYCFG" ] && CYCFG=$(get $BAT/cycle_count)
QMAX=$(get $FG/qmax)
SOH=$(get $FG/soh)

_CF=$(cfg_get cycle_fake "")
# v2.7：真实值优先取 qmax_cyclecount（不随伪装变化），避免显示到被污染的记录文件
_LR=$(cycle_real_read 2>/dev/null)
case "$_LR" in ''|*[!0-9]*) _LR=$(cat $CYCLE_REAL_FILE 2>/dev/null) ;; esac
case "$_LR" in ''|*[!0-9]*) _LR="" ;; esac
if [ -n "$_CF" ]; then
  if [ -n "$_LR" ]; then CYCFG_D="${CYCFG}（伪装中；真实 ${_LR}）"
  else CYCFG_D="${CYCFG}（伪装中）"; fi
else
  CYCFG_D="${CYCFG}"
fi

case "$ST" in
  Discharging) ST_CN="放电中" ;;
  Charging) ST_CN="充电中" ;;
  Full) ST_CN="已充满" ;;
  "Not charging") ST_CN="未充电" ;;
  *) ST_CN="$ST" ;;
esac

MAH_D=$(awk -v v="$DESIGN" 'BEGIN{ if(v>0) printf "%.0f", v/1000; else printf "?" }')
MAH_F=$(awk -v v="$FULL" 'BEGIN{ if(v>0) printf "%.0f", v/1000; else printf "?" }')
HEALTH=$(awk -v c="$FULL" -v d="$DESIGN" 'BEGIN{ if(d>0) printf "%.1f", c/d*100; else printf "?" }')
T_C=$(awk -v t="$T" 'BEGIN{ if(t!="") printf "%.1f", t/10; else printf "?" }')
V_V=$(awk -v v="$V" 'BEGIN{ if(v!="") printf "%.3f", v/1000000; else printf "?" }')
I_M=$(awk -v i="$I" 'BEGIN{ if(i!="") printf "%.0f", i/1000; else printf "?" }')

UNLOCK=$(cfg_get unlock 1)
if [ "$UNLOCK" = "1" ]; then _u="开"; else _u="关"; fi

FVS=$(sh $XBT/scripts/fv_guard.sh status 2>/dev/null | head -n 1)

echo "===================================="
echo " [电池信息]"
echo "===================================="
echo "设备型号 : $DEV_NAME ($DEV_CODE)"
echo "电芯厂商 : $(get $FG/cell_vendor)"
echo "电池序列 : $(get $FG/batt_sn)"
echo "生产日期 : $(get $FG/manufacturing_date) 首次使用: $(get $FG/first_usage_date)"
echo "------------------------------------"
echo "设计容量 : ${MAH_D} mAh"
echo "真实容量 : ${QMAX} mAh (Qmax)  SOH: ${SOH}%"
echo "当前满充容量: ${MAH_F} mAh"
echo "健康度   : ${HEALTH}%"
echo "循环计数 : ${CYCFG_D}"
echo "------------------------------------"
echo "电量     : ${CAP}%  (${ST_CN})"
echo "电压     : ${V_V} V   电流: ${I_M} mA"
echo "温度     : ${T_C} C"
echo "------------------------------------"
echo "解容开关 : ${_u}"
echo "充电模式 : $(power_label)（$(power_hint)）"
echo "BAA挂载  : $(baa_state_cn)"
echo "smart_fv : $(get $FV_NODE)  ($FVS)"
echo "当前槽   : _$(slot_letter)"
echo "===================================="