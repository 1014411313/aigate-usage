#!/system/bin/sh
# status_kv.sh - 供 WebUI 读取的轻量状态输出
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh

BAT=/sys/class/power_supply/battery
_nodes=$(direct_current_nodes)
_node=$(echo "$_nodes" | head -n 1)
_v=$(read_voltage_uv)
_target=$(target_current_ma "$_v")
_ma_raw=$(cat "$BAT/current_now" 2>/dev/null)
_soc=$(cat "$BAT/capacity" 2>/dev/null)
_st=$(cat "$BAT/status" 2>/dev/null)
_tmp=$(cat "$BAT/temp" 2>/dev/null)
_cfull=$(cat "$BAT/charge_full" 2>/dev/null)
_cdes=$(cat "$BAT/charge_full_design" 2>/dev/null)
_health=$(cat "$BAT/health" 2>/dev/null)
_cycle=$(cat /sys/class/xm_power/fg_master/cyclecount 2>/dev/null)
[ -z "$_cycle" ] && _cycle=$(cat "$BAT/cycle_count" 2>/dev/null)
# µAh -> mAh
case "$_cfull" in ''|*[!0-9]*) _cfull_mah="" ;; *) _cfull_mah=$(awk -v x="$_cfull" 'BEGIN{printf "%d", x/1000}') ;; esac
case "$_cdes"  in ''|*[!0-9]*) _cdes_mah=""  ;; *) _cdes_mah=$(awk -v x="$_cdes" 'BEGIN{printf "%d", x/1000}') ;; esac
case "$_cycle" in ''|*[!0-9]*) _cycle="" ;; esac

case "$_ma_raw" in
  ''|*[!0-9-]*) _ma="" ;;
  *) _ma=$(awk -v r="$_ma_raw" 'BEGIN { printf "%d", r / 1000 }') ;;
esac
case "$_soc" in ''|*[!0-9]*) _soc="" ;; esac
if [ -n "$_ma" ] && [ -n "$_v" ]; then
  _ma_abs=${_ma#-}
  _battery_power_w=$(awk -v i="$_ma_abs" -v v="$_v" 'BEGIN { printf "%.1f", i * v / 1000000000 }')
else
  _ma_abs=""
  _battery_power_w=""
fi

echo "power_w=$(power_now)"
if [ -n "$_nodes" ]; then echo "direct_control=1"; else echo "direct_control=0"; fi
echo "direct_nodes=$(echo "$_nodes" | tr '\n' ',' | sed 's/,$//')"
echo "voltage_uv=${_v}"
echo "target_ma=${_target}"
echo "current_node=${_node}"
if [ -n "$_node" ] && [ -w "$_node" ]; then echo "node_ok=1"; else echo "node_ok=0"; fi
echo "battery_current_ma=${_ma}"
echo "battery_current_abs_ma=${_ma_abs}"
echo "battery_power_w=${_battery_power_w}"
echo "soc=${_soc}"
echo "status=${_st}"
echo "temp_c=${_tmp}"
echo "charge_full_mah=${_cfull_mah}"
echo "charge_design_mah=${_cdes_mah}"
echo "health=${_health}"
echo "cycle=${_cycle}"
echo "unlock=$(cfg_get unlock 1)"
echo "cloud_guard=$(cfg_get cloud_guard 1)"
echo "baa_state=$(baa_state)"
echo "thermal_remove=$(cat /sys/class/xm_power/charger/charger_thermal/wired_thermal_remove 2>/dev/null)"
echo "ctrl_limit=$(cat /sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit 2>/dev/null)"
# 温控守护（自定义上限）
echo "thermal_guard=$(cfg_get thermal_guard 0)"
echo "thermal_limit=$(cfg_get thermal_limit 45)"
echo "thermal_action=$(cfg_get thermal_action slow)"
# v2.7：下发滞回值（前端要显示"降回 x℃ 自动还原"，此前前端只能硬编码 fallback 4）
echo "thermal_hyst=$(cfg_get thermal_hyst 4)"
_tgc=$(cat $BAT/temp 2>/dev/null); case "$_tgc" in ''|*[!0-9]*) _tgc=0 ;; esac
_tgb=$(cat /sys/class/xm_power/charger/smart_charge/board_temp 2>/dev/null); case "$_tgb" in ''|*[!0-9]*) _tgb=0 ;; esac
echo "thermal_temp=$_tgc"
echo "thermal_temp_board=$_tgb"
if [ -f $XBT/state/thermal_prev ]; then echo "thermal_active=1"; else echo "thermal_active=0"; fi
echo "freepps=$(cfg_get freepps 0)"
echo "freepps_runtime=$(cat /data/adb/modules/freepps/free 2>/dev/null)"
echo "fast_w=$FAST_W"
echo "mid_w=$MID_W"
echo "slow_w=$SLOW_W"
echo "dev_code=$DEV_CODE"
echo "dev_name=$DEV_NAME"
# v2.6.23：下发机型最大功率，消除前端硬编码机型表（新增机型时两处必漂移）
echo "dev_maxw=$DEV_MAXW"
echo "version=$(grep '^version=' "$XBT/module.prop" 2>/dev/null | head -n1 | cut -d= -f2)"

# ---- 附加项：供主页/场景页一次取齐，减少前端 su 请求次数 ----
echo "power_limit=$(cfg_get power_limit inf)"
echo "cycle_fake=$(cfg_get cycle_fake '')"
echo "cycle_real=$(cycle_real_read)"
if [ -f "$XBT/dtbo/local.img" ]; then echo "dtbo_local=1"; else echo "dtbo_local=0"; fi
_proto=""
for _p in /sys/class/power_supply/usb/real_type \
          /sys/class/xm_power/charger/charger_common/real_type \
          /sys/class/qcom-battery/real_type \
          /sys/class/power_supply/usb/typec_mode; do
  if [ -f "$_p" ]; then
    _proto=$(cat "$_p" 2>/dev/null)
    [ -n "$_proto" ] && break
  fi
done
echo "charge_proto=$_proto"
_pmax=$(cat /sys/class/xm_power/charger/charger_common/power_max 2>/dev/null)
case "$_pmax" in ''|*[!0-9]*) ;; *) echo "power_max_w=$((_pmax / 1000000))" ;; esac
