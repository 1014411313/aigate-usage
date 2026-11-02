#!/system/bin/sh
# status_kv.sh - 供 WebUI 读取的轻量状态输出
# 本脚本由 WebUI 每 6 拍通过 ksu.exec 调用一次；ksu.exec 是同步调用，脚本跑多久
# WebView 的 JS 线程就阻塞多久（每次还要新建 root shell）。因此这里的一切读取
# 都按「每秒采样」的零 fork 方式写：节点用内建 read，配置一次读入变量。
# 注意：common.sh 曾回退过 cfg_get 的变量缓存（长驻守护 source 后读到旧值的 bug）；
# 那条教训只适用于常驻进程——本脚本每次都是新进程、读完即退，缓存安全。
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh

BAT=/sys/class/power_supply/battery

# ---- settings.conf 一次读入（0 fork；键名限定字母数字下划线，防止 eval 注入）----
while IFS= read -r _line; do
  case "$_line" in ''|\#*) continue ;; esac
  case "$_line" in *=*) ;; *) continue ;; esac
  _ck=${_line%%=*}
  case "$_ck" in *[!A-Za-z0-9_]*|'') continue ;; esac
  eval "_cfg_$_ck=\${_line#*=}"
done < "$CONF" 2>/dev/null
# 覆盖 common.sh 的 cfg_get：空值/缺失仍回落默认值，与原实现语义一致
cfg_get() {
  eval _cg=\"\${_cfg_$1-}\"
  if [ -n "$_cg" ]; then echo "$_cg"; else echo "${2:-}"; fi
}
# 内建读文件到变量（不可读/空文件置空，等价原来的 cat 2>/dev/null）
rdf() {
  eval "$1="
  [ -r "$2" ] && IFS= read -r "$1" < "$2" 2>/dev/null
  return 0
}

_nodes=$(direct_current_nodes)
_node=$(echo "$_nodes" | head -n 1)
# 电压：单串值给界面/曲线，总压用来算功率（双电芯机型 battery/voltage_now 报的可能是串联总压）
cell_voltage_ctx
_v="${CV_CELL:-}"
_pack_v="${CV_PACK:-$_v}"
_target=$(target_current_ma "$_pack_v")
# 一次 awk 读完这批节点（含 qmax 真实循环节点；原来是 9 次 cat，每次刷新都要 fork 9 次）
_kv_files=""
for _x in "$BAT/current_now" "$BAT/capacity" "$BAT/status" "$BAT/temp" \
          "$BAT/charge_full" "$BAT/charge_full_design" "$BAT/health" \
          /sys/class/xm_power/fg_master/cyclecount "$BAT/cycle_count" \
          /sys/class/xm_power/fg_master/qmax_cyclecount; do
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
_cycle_real="$kv_qmax_cyclecount"
# 与 common.sh 的 cycle_real_read 回退链一致：qmax → fg_master/cyclecount（已在 awk 批读内）
case "$_cycle_real" in ''|*[!0-9]*) _cycle_real="$kv_cyclecount" ;; esac
case "$_cycle_real" in ''|*[!0-9]*) _cycle_real="" ;; esac
# 慢变节点偶发读到空行（驱动瞬时报错）时重试一次，降低 UI 闪成 -- 的机率
if [ -z "$_cfull" ]; then rdf _cfull "$BAT/charge_full"; fi
if [ -z "$_cdes" ]; then rdf _cdes "$BAT/charge_full_design"; fi
# µAh -> mAh（整除截断，与原 awk printf %d 一致）
case "$_cfull" in ''|*[!0-9]*) _cfull_mah="" ;; *) _cfull_mah=$((_cfull / 1000)) ;; esac
case "$_cdes"  in ''|*[!0-9]*) _cdes_mah="" ;; *) _cdes_mah=$((_cdes / 1000)) ;; esac
case "$_cycle" in ''|*[!0-9]*) _cycle="" ;; esac

case "$_ma_raw" in
  ''|*[!0-9-]*) _ma="" ;;
  *) _ma=$((_ma_raw / 1000)) ;;
esac
case "$_soc" in ''|*[!0-9]*) _soc="" ;; esac
if [ -n "$_ma" ] && [ -n "$_v" ]; then
  _ma_abs=${_ma#-}
  _battery_power_w=$(awk -v i="$_ma_abs" -v v="$_pack_v" 'BEGIN { printf "%.1f", i * v / 1000000000 }')
else
  _ma_abs=""
  _battery_power_w=""
fi

echo "power_w=$(power_now)"
if [ -n "$_nodes" ]; then echo "direct_control=1"; else echo "direct_control=0"; fi
# 换行转逗号（原 tr|sed 两叉，改纯 shell）
echo "direct_nodes=${_nodes//$'\n'/,}"
echo "voltage_uv=${_v}"
echo "pack_voltage_uv=${_pack_v}"
echo "battery_cells=${CV_CELLS}"
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
rdf _trm /sys/class/xm_power/charger/charger_thermal/wired_thermal_remove
echo "thermal_remove=$_trm"
rdf _clm /sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit
echo "ctrl_limit=$_clm"
# charge_guard 同理（v3.9.5 起它也有 PID 文件）
rdf _cgpid $XBT/state/cg.pid
case "$_cgpid" in ''|*[!0-9]*) _cgalive=0 ;; *)
  if kill -0 "$_cgpid" 2>/dev/null; then _cgalive=1; else _cgalive=0; fi ;;
esac
echo "charge_guard_alive=$_cgalive"
echo "charge_guard_ok=$_cgalive"
echo "watchdog_alive=$(timeout 5 pgrep -f 'HyperOS_XJ/battery/scripts/[g]uard_watchdog\.sh' 2>/dev/null | head -n1)"
# ===== v3.11.0 自适应功率爬坡器状态 =====
rdf _apl_pid $XBT/state/apl.pid
case "$_apl_pid" in ''|*[!0-9]*) _apl_live=0 ;; *)
  if kill -0 "$_apl_pid" 2>/dev/null; then _apl_live=1; else _apl_live=0; fi ;;
esac
echo "apl_alive=$_apl_live"
echo "apl_pid=$_apl_pid"
rdf _apl_target $XBT/state/apl_target_ma
echo "apl_target_ma=$_apl_target"
echo "apl_cap_ma=$(dt_curr_cap_ma 2>/dev/null)"
echo "apl_locked=$( [ -f $XBT/state/apl_lock_until ] && echo 1 || echo 0 )"
_apl_prof=$XBT/state/apl_profile.$(cfg_get dev_code unknown).kv
echo "apl_profile=$( [ -f "$_apl_prof" ] && echo 1 || echo 0 )"
echo "apl_best_ma=$(awk -F= '/^b[0-9]=/ { if ($2+0 > m) m=$2+0 } END { if (m>0) print m }' "$_apl_prof" 2>/dev/null)"
echo "apl_reset_reason=$(awk -F= '/^_reset_/ { v=$0; sub(/^_reset_[^=]*=/, "", v) } END { print v }' "$_apl_prof" 2>/dev/null)"

echo "freepps=$(cfg_get freepps 0)"
rdf _fpr /data/adb/modules/freepps/free
echo "freepps_runtime=$_fpr"
echo "fast_w=$FAST_W"
echo "mid_w=$MID_W"
echo "slow_w=$SLOW_W"
echo "dev_code=$DEV_CODE"
echo "dev_name=$DEV_NAME"
# v2.6.23：下发机型最大功率，消除前端硬编码机型表（新增机型时两处必漂移）
echo "dev_maxw=$DEV_MAXW"
echo "version=$(awk -F= '/^version=/ { print $2; exit }' "$XBT/module.prop" 2>/dev/null)"

# ---- 附加项：供主页/场景页一次取齐，减少前端 su 请求次数 ----
echo "power_limit=$(cfg_get power_limit inf)"
echo "apl_enable=$(cfg_get apl_enable 0)"
echo "cycle_fake=$(cfg_get cycle_fake '')"
echo "cycle_real=$_cycle_real"
_di=$(dtbo_local_image)
if [ -n "$_di" ]; then echo "dtbo_local=1"; else echo "dtbo_local=0"; fi
echo "dtbo_image=${_di##*/}"
if dtbo_os_supported; then echo "dtbo_os4=1"; else echo "dtbo_os4=0"; fi
# DTBO 刷入结果：安装脚本写 install_flash_*，界面刷入写 flash_OK / auto_before_flash，两种都要认
_dm="$(cfg_get backup_dir /sdcard/Download/dtbo_backup)/manifest.txt"
_dl=$(awk '/install_flash_OK|install_flash_SKIP|install_flash_.*FAIL|install_flash_ABORT|flash_OK|flash_VERIFY_FAIL/ { l=$0 } END { print l }' "$_dm" 2>/dev/null)
case "$_dl" in
    *flash_OK*) echo "dtbo_flash=OK" ;;
    *SKIP*)     echo "dtbo_flash=SKIP" ;;
    *_FAIL*|*ABORT*) echo "dtbo_flash=FAIL" ;;
    *)          echo "dtbo_flash=" ;;
esac
case "$_dl" in
    *' '*) _dl2=${_dl#*' '}; echo "dtbo_flash_time=${_dl%%' '*} ${_dl2%%' '*}" ;;
    '')    echo "dtbo_flash_time=" ;;
    *)     echo "dtbo_flash_time=$_dl" ;;
esac
# 满电电压生效状态：载荷改写标记 + 当前加载的 vterm 上限
echo "fv_force=$(cfg_get fv_force 0)"
echo "fv_set=$(cfg_get fv_v '')"
rdf _fv_ap $XBT/state/fv_force_applied
echo "fv_applied=$_fv_ap"
_vtm=$(get_vterm_max 2>/dev/null)
echo "fv_vterm=$_vtm"
rdf _fv_orig $XBT/state/fv_vterm_orig
echo "fv_vterm_orig=$_fv_orig"
# 电压节点实际当前值：界面判断「是否真写进去」只能靠它，不能只看设定值与上限比较
rdf _vfn $XBT/state/volt_fv_node
_vfn=${_vfn%%|*}
if [ -n "$_vfn" ] && [ -r "$_vfn" ]; then
  rdf _vnv "$_vfn"
  _vnv=$(printf '%s' "$_vnv" | tr -cd '0-9')
  case "$_vnv" in ''|0) ;; *)
    echo "fv_node_now=$_vnv"
    echo "fv_node_path=$_vfn" ;;
  esac
fi

_proto=""
for _p in /sys/class/power_supply/usb/real_type \
          /sys/class/xm_power/charger/charger_common/real_type \
          /sys/class/qcom-battery/real_type \
          /sys/class/power_supply/usb/typec_mode; do
  rdf _pv "$_p"
  [ -n "$_pv" ] && { _proto=$_pv; break; }
done
echo "charge_proto=$_proto"
rdf _pmax /sys/class/xm_power/charger/charger_common/power_max
case "$_pmax" in ''|*[!0-9]*) ;; *) echo "power_max_w=$((_pmax / 1000000))" ;; esac
echo "fv_v=$(cfg_get fv_v '')"
echo "term_v=$(cfg_get term_v '')"
echo "vterm_max=$_vtm"
