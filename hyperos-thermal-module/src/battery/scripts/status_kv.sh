#!/system/bin/sh
# status_kv.sh - 供 WebUI 读取的轻量状态输出
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh

BAT=/sys/class/power_supply/battery
_nodes=$(direct_current_nodes)
_node=$(echo "$_nodes" | head -n 1)
_v=$(read_voltage_uv)
_target=$(target_current_ma "$_v")
# 一次 awk 读完这批节点（原来是 9 次 cat，每次刷新都要 fork 9 次；
# 1 秒一刷时这部分开销直接体现为界面发滞）
_kv_files=""
for _x in "$BAT/current_now" "$BAT/capacity" "$BAT/status" "$BAT/temp" \
          "$BAT/charge_full" "$BAT/charge_full_design" "$BAT/health" \
          /sys/class/xm_power/fg_master/cyclecount "$BAT/cycle_count"; do
    [ -f "$_x" ] && _kv_files="$_kv_files $_x"
done
if [ -n "$_kv_files" ]; then
    eval "$(awk 'FNR==1 { n=split(FILENAME,p,"/"); printf "kv_%s=\"%s\"\n", p[n], $0 }' $_kv_files 2>/dev/null)"
fi
_ma_raw="$kv_current_now"
_soc="$kv_capacity"
_st="$kv_status"
_tmp="$kv_temp"
_cfull="$kv_charge_full"
_cdes="$kv_charge_full_design"
_health="$kv_health"
_cycle="$kv_cyclecount"
[ -z "$_cycle" ] && _cycle="$kv_cycle_count"
# 慢变节点偶发读到空行（驱动瞬时报错）时重试一次，降低 UI 闪成 -- 的机率
if [ -z "$_cfull" ] && [ -f "$BAT/charge_full" ]; then _cfull=$(cat "$BAT/charge_full" 2>/dev/null); fi
if [ -z "$_cdes" ] && [ -f "$BAT/charge_full_design" ]; then _cdes=$(cat "$BAT/charge_full_design" 2>/dev/null); fi
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
# ===== v3.9.8【修 bug】上报 thermal_guard 的【真实存活状态】 =====
# 【群友反馈】开关显示「开」但温控守护实际没跑。
# 【根因】旧版这里只 echo(cfg_get thermal_guard) —— 它是【配置值】不是【运行状态】。
#   thermal_guard.sh 有 3 个 exit 0 路径（单实例让位 / 开机时开关=0 / 循环里开关=0），
#   一旦退出，配置仍是 1 → 前端永远显示"开"，用户完全无感。
# 【修法】额外输出 thermal_guard_alive（进程是否存活）与 thermal_guard_ok（两者是否一致）。
#   前端可用 thermal_guard_ok 判红：=0 表示「开关是开但进程没跑」。
_tgpid=$(cat /data/local/tmp/xt_thermal_guard.pid 2>/dev/null)
case "$_tgpid" in ''|*[!0-9]*) _tgalive=0 ;; *)
  if kill -0 "$_tgpid" 2>/dev/null; then _tgalive=1; else _tgalive=0; fi ;;
esac
echo "thermal_guard_alive=$_tgalive"
echo "thermal_guard_pid=$_tgpid"
if [ "$(cfg_get thermal_guard 0)" = "1" ] && [ "$_tgalive" = "1" ]; then
  echo "thermal_guard_ok=1"
elif [ "$(cfg_get thermal_guard 0)" = "0" ] && [ "$_tgalive" = "0" ]; then
  echo "thermal_guard_ok=1"
else
  echo "thermal_guard_ok=0"      # ← 开关与进程不一致，前端应提示/自动修复
fi
# charge_guard 同理（v3.9.5 起它也有 PID 文件）
_cgpid=$(cat $XBT/state/cg.pid 2>/dev/null)
case "$_cgpid" in ''|*[!0-9]*) _cgalive=0 ;; *)
  if kill -0 "$_cgpid" 2>/dev/null; then _cgalive=1; else _cgalive=0; fi ;;
esac
echo "charge_guard_alive=$_cgalive"
echo "charge_guard_ok=$_cgalive"
echo "watchdog_alive=$(timeout 5 pgrep -f 'battery_tune/scripts/guard_watchdog\.sh' 2>/dev/null | head -n1)"
# ===== v3.11.0 自适应功率爬坡器状态 =====
_apl_pid=$(cat $XBT/state/apl.pid 2>/dev/null)
case "$_apl_pid" in ''|*[!0-9]*) _apl_live=0 ;; *)
  if kill -0 "$_apl_pid" 2>/dev/null; then _apl_live=1; else _apl_live=0; fi ;;
esac
echo "apl_alive=$_apl_live"
echo "apl_pid=$_apl_pid"
echo "apl_target_ma=$(cat $XBT/state/apl_target_ma 2>/dev/null)"
echo "apl_cap_ma=$(dt_curr_cap_ma 2>/dev/null)"
echo "apl_locked=$( [ -f $XBT/state/apl_lock_until ] && echo 1 || echo 0 )"
echo "apl_profile=$( [ -f $XBT/state/apl_profile.$(cfg_get dev_code unknown).kv ] && echo 1 || echo 0 )"
echo "apl_best_ma=$(_pb=$XBT/state/apl_profile.$(cfg_get dev_code unknown).kv; [ -f "$_pb" ] && grep -a '^b[0-9]=' "$_pb" 2>/dev/null | cut -d= -f2 | awk '{if($1+0>m)m=$1+0}END{if(m>0)print m}')"
echo "apl_reset_reason=$(grep -a '^_reset_' $XBT/state/apl_profile.$(cfg_get dev_code unknown).kv 2>/dev/null | tail -n1 | cut -d= -f2-)"

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
echo "apl_enable=$(cfg_get apl_enable 0)"
echo "cycle_fake=$(cfg_get cycle_fake '')"
echo "cycle_real=$(cycle_real_read)"
if [ -f "$XBT/dtbo/local.img" ]; then echo "dtbo_local=1"; else echo "dtbo_local=0"; fi
# DTBO 刷入结果：安装脚本写 install_flash_*，界面刷入写 flash_OK / auto_before_flash，两种都要认
_dm=/sdcard/Download/dtbo_backup/manifest.txt
_dl=$(grep -aE 'install_flash_OK|install_flash_SKIP|install_flash_.*FAIL|flash_OK|auto_before_flash' "$_dm" 2>/dev/null | tail -n 1)
case "$_dl" in
    *flash_OK*) echo "dtbo_flash=OK" ;;
    *SKIP*)     echo "dtbo_flash=SKIP" ;;
    *_FAIL*|*ABORT*) echo "dtbo_flash=FAIL" ;;
    *)          echo "dtbo_flash=" ;;
esac
echo "dtbo_flash_time=$(echo "$_dl" | cut -d' ' -f1-2)"
# 满电电压生效状态：载荷改写标记 + 当前加载的 vterm 上限
echo "fv_force=$(cfg_get fv_force 0)"
echo "fv_set=$(cfg_get fv_v '')"
echo "fv_applied=$(cat "$XBT/state/fv_force_applied" 2>/dev/null)"
echo "fv_vterm=$(get_vterm_max 2>/dev/null)"
echo "fv_vterm_orig=$(cat "$XBT/state/fv_vterm_orig" 2>/dev/null)"
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
echo "fv_v=$(cfg_get fv_v '')"
echo "term_v=$(cfg_get term_v '')"
echo "fv_force=$(cfg_get fv_force 0)"
echo "vterm_max=$(get_vterm_max)"
