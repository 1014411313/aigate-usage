#!/system/bin/sh
# detail_kv.sh —— 电池详情 / 充电协议 / 温区扩展采样（供 WebUI 低频读取）
# 手法与充电监视器 detect.sh/read.sh 对齐：运行期只做内建 read，不 fork；
# 节点路径探测结果缓存 state/detail.cache（带 CV 版本键，字段集变更强制重扫；
# 关键节点不可读也触发重扫）。探测要求 cat 读出非空才收录（空值节点不占位）。
XBT=/data/adb/modules/HyperOS_XJ/battery
CACHE=$XBT/state/detail.cache
CVN=62

rdf() {
  eval "$1="
  [ -r "$2" ] && IFS= read -r "$1" < "$2" 2>/dev/null
  return 0
}

# 清洗：只留数字（含负号），其余置空
num() {
  eval "case \"\$$1\" in *[!0-9-]*|'') $1= ;; esac"
  return 0
}

# ---- 路径缓存 ----
if [ -r "$CACHE" ]; then . "$CACHE" 2>/dev/null; fi
_need_probe=0
[ "$_Cv" = "$CVN" ] || _need_probe=1
[ -n "$P_RM" ] && [ -r "$P_RM" ] || _need_probe=1
[ -n "$P_QCT" ] && [ -r "$P_QCT" ] || _need_probe=1
# 温区：缓存里的 TZ 路径全部不可读时也重扫（thermal_zone 编号跨重启会变，
# 不重扫会导致 tzlist 长期为空、电池温度消失）
if [ "$_need_probe" = "0" ]; then
  _tz_ok=0
  _tz_i=1
  while [ "$_tz_i" -le 8 ]; do
    eval "_tzp=\${TZ$_tz_i-}"
    if [ -n "$_tzp" ] && [ -r "$_tzp" ]; then _tz_ok=1; break; fi
    _tz_i=$((_tz_i + 1))
  done
  [ "$_tz_ok" = "1" ] || _need_probe=1
fi
if [ "$_need_probe" = "1" ]; then
  Q=/sys/class/qcom-battery
  T=/sys/class/typec/port0
  PT=/sys/class/power_supply/typec
  _dirs="/sys/class/power_supply/battery /sys/class/power_supply/bms /sys/class/qcom-battery /sys/class/xm_power /sys/class/power_supply/batt_verify /sys/class/power_supply/fuelgauge"
  # find_file：按「目录×候选」序找第一个 cat 读出非空的文件（空值节点不收录）
  find_file() {
    for _n in "$@"; do
      for _d in $_dirs; do
        _p="$_d/$_n"
        if [ -f "$_p" ]; then
          _vv=
          if IFS= read -r _vv < "$_p" 2>/dev/null; then :; fi
          [ -n "$_vv" ] && { echo "$_p"; return 0; }
        fi
      done
    done
    return 1
  }
  if_file() { [ -f "$1" ] && { _vv=; IFS= read -r _vv < "$1" 2>/dev/null; [ -n "$_vv" ] && return 0; }; return 1; }

  P_SOH=$(find_file soh battery_soh state_of_health)
  P_QMAX=$(find_file qmax qmax0 batt_qmax fg_qmax)
  P_RM=$(find_file rm remaining_capacity fg_rm charge_counter)
  P_CELL=$(find_file cell_voltage cell1_voltage cell1_volt batt_cell1_vol vcell fg_vcell)
  P_MODEL=$(find_file battery_type model_name batt_type battery_id_name)
  P_VENDOR=$(find_file manufacturer battery_vendor batt_manufacturer)
  P_DATE=$(find_file manufacturing_date battery_date mfg_date manufacture_date)
  P_TLEVEL=$(find_file system_temp_level thermal_level)
  P_CCC=$(find_file constant_charge_current_max fcc)
  P_TTF=$(find_file time_to_full_now)

  # 充电协议（P: 前缀语义照抄）
  P_QCT=""
  if [ -f "$Q/quick_charge_type" ]; then _vv=; IFS= read -r _vv < "$Q/quick_charge_type" 2>/dev/null; [ -n "$_vv" ] && P_QCT="$Q/quick_charge_type"; fi
  [ -z "$P_QCT" ] && [ -r /sys/class/xm_power/charger/quick_charge_type ] && P_QCT=/sys/class/xm_power/charger/quick_charge_type
  if if_file "$Q/real_type"; then P_REAL="$Q/real_type"; elif if_file /sys/class/power_supply/usb/real_type; then P_REAL=/sys/class/power_supply/usb/real_type; else P_REAL=; fi
  P_UREAL=""; [ -f "$Q/usb_real_type" ] && { _vv=; IFS= read -r _vv < "$Q/usb_real_type" 2>/dev/null; [ -n "$_vv" ] && P_UREAL="$Q/usb_real_type"; }
  P_PD=""
  if [ -f "$Q/pd_verified" ]; then _vv=; IFS= read -r _vv < "$Q/pd_verified" 2>/dev/null; [ -n "$_vv" ] && P_PD="$Q/pd_verified"; fi
  P_PMX=""
  if [ -f "$Q/power_max" ]; then _vv=; IFS= read -r _vv < "$Q/power_max" 2>/dev/null; [ -n "$_vv" ] && P_PMX="$Q/power_max"; fi
  [ -z "$P_PMX" ] && [ -r /sys/class/xm_power/charger/charger_common/power_max ] && P_PMX=/sys/class/xm_power/charger/charger_common/power_max
  P_TCM=""; [ -f "$T/power_operation_mode" ] && P_TCM="$T/power_operation_mode"
  P_TCR=""; [ -f "$T/power_role" ] && P_TCR="$T/power_role"
  P_PDR=""; [ -f "$T/usb_power_delivery_revision" ] && P_PDR="$T/usb_power_delivery_revision"
  P_APDO=""; [ -f "$PT/apdo_max" ] && P_APDO="$PT/apdo_max"
  P_PPS=""; [ -f "$PT/typec_pps_ptf" ] && P_PPS="$PT/typec_pps_ptf"
  P_UV=""; [ -r /sys/class/power_supply/usb/voltage_now ] && P_UV=/sys/class/power_supply/usb/voltage_now
  P_UI=""
  if [ -r /sys/class/power_supply/usb/input_current_now ]; then P_UI=/sys/class/power_supply/usb/input_current_now
  elif [ -f "$Q/ibus_total" ]; then P_UI="$Q/ibus_total"; P_IS_TOTAL=1; else P_IS_TOTAL=; fi
  # USB 类型：usb/real_type 或 usb/usb_type，qcom usb_real_type 存在则覆盖（照抄）
  UT=""
  [ -r /sys/class/power_supply/usb/real_type ] && UT=/sys/class/power_supply/usb/real_type
  [ -z "$UT" ] && [ -r /sys/class/power_supply/usb/usb_type ] && UT=/sys/class/power_supply/usb/usb_type
  [ -f "$Q/usb_real_type" ] && UT="$Q/usb_real_type"
  P_UT="$UT"
  # 在线检测：power_supply/*/online（type 非 Battery/BMS/Unknown）
  ONL=""
  for _p in /sys/class/power_supply/*; do
    [ -f "$_p/online" ] || continue
    _ty=
    [ -r "$_p/type" ] && IFS= read -r _ty < "$_p/type" 2>/dev/null
    case "$_ty" in Battery|BMS|Unknown|"") ;; *) ONL="$ONL $_p/online" ;; esac
  done
  # 双电芯：qcom fg1/fg2 优先（电压 µV、电流 mA），否则 xm_power fg_master/fg_slave
  DC_MODE=0
  if [ -f "$Q/fg1_voltage" ] && [ -f "$Q/fg2_voltage" ]; then
    DC_MODE=1
    DC1_V="$Q/fg1_voltage"; DC2_V="$Q/fg2_voltage"
    DC1_I=""; [ -f "$Q/fg1_current" ] && DC1_I="$Q/fg1_current"
    DC2_I=""; [ -f "$Q/fg2_current" ] && DC2_I="$Q/fg2_current"
    DC1_Q=""; [ -f "$Q/fg1_qmax" ] && DC1_Q="$Q/fg1_qmax"
    DC2_Q=""; [ -f "$Q/fg2_qmax" ] && DC2_Q="$Q/fg2_qmax"
  elif [ -d /sys/class/xm_power/fg_master ] && [ -d /sys/class/xm_power/fg_slave ]; then
    DC_MODE=2
    FM=/sys/class/xm_power/fg_master
    FS=/sys/class/xm_power/fg_slave
    _VN="voltage_now vbat fg_vbat batt_vol vol voltage vcell cell_voltage"
    _IN="current_now ibat fg_ibat batt_curr curr current"
    _QN="qmax fg_qmax qmax0 batt_qmax"
    fg_get() { # $1=目录 $2=候选名列表
      for _n in $2; do
        if [ -f "$1/$_n" ] && IFS= read -r _vv < "$1/$_n" 2>/dev/null; then [ -n "$_vv" ] && { echo "$1/$_n"; return 0; }; fi
      done
      return 1
    }
    DC1_V=$(fg_get $FM "$_VN"); DC2_V=$(fg_get $FS "$_VN")
    DC1_I=$(fg_get $FM "$_IN"); DC2_I=$(fg_get $FS "$_IN")
    DC1_Q=$(fg_get $FM "$_QN"); DC2_Q=$(fg_get $FS "$_QN")
  fi
  # 温区：电池温区优先收录（最多 2 个），其余 usb/conn/chg/skin 补足到 8 个，
  # 避免名额被充电接口类占满后电池温度被挤掉
  TZ1=""; TZ2=""; TZ3=""; TZ4=""; TZ5=""; TZ6=""; TZ7=""; TZ8=""
  TZ1T=""; TZ2T=""; TZ3T=""; TZ4T=""; TZ5T=""; TZ6T=""; TZ7T=""; TZ8T=""
  _tz_n=0
  for _tzd in /sys/class/thermal/thermal_zone*; do
    [ "$_tz_n" -ge 2 ] && break
    [ -r "$_tzd/type" ] && [ -r "$_tzd/temp" ] || continue
    rdf _tzt "$_tzd/type"
    case "$_tzt" in *batt*) ;; *) continue ;; esac
    _tz_n=$((_tz_n + 1))
    eval "TZ$_tz_n=\$_tzd/temp; TZ${_tz_n}T=\$_tzt"
  done
  for _tzd in /sys/class/thermal/thermal_zone*; do
    [ "$_tz_n" -ge 8 ] && break
    [ -r "$_tzd/type" ] && [ -r "$_tzd/temp" ] || continue
    rdf _tzt "$_tzd/type"
    case "$_tzt" in *usb*|*conn*|*chg*|*charg*|*skin*) ;; *) continue ;; esac
    _tz_n=$((_tz_n + 1))
    eval "TZ$_tz_n=\$_tzd/temp; TZ${_tz_n}T=\$_tzt"
  done
  # xm_power 模糊附加项：每个关键词最多 2 个文件，合计最多 6 个
  XE1=""; XE2=""; XE3=""; XE4=""; XE5=""; XE6=""
  _xe_n=0
  for _kw in fast_charge apdo adapter_id strategy charger_type pd_auth; do
    [ "$_xe_n" -ge 6 ] && break
    for _xf in $(find -L /sys/class/xm_power -maxdepth 4 -type f -name "*$_kw*" 2>/dev/null | head -n 2); do
      [ "$_xe_n" -ge 6 ] && break
      [ -r "$_xf" ] || continue
      _xe_n=$((_xe_n + 1))
      eval "XE$_xe_n=\$_xf"
    done
  done

  _tmp_cache=$CACHE.tmp
  {
    echo "_Cv=$CVN"
    echo "P_SOH=$P_SOH"; echo "P_QMAX=$P_QMAX"; echo "P_RM=$P_RM"; echo "P_CELL=$P_CELL"
    echo "P_MODEL=$P_MODEL"; echo "P_VENDOR=$P_VENDOR"; echo "P_DATE=$P_DATE"
    echo "P_TLEVEL=$P_TLEVEL"; echo "P_CCC=$P_CCC"; echo "P_TTF=$P_TTF"
    echo "P_QCT=$P_QCT"; echo "P_REAL=$P_REAL"; echo "P_UREAL=$P_UREAL"; echo "P_PD=$P_PD"
    echo "P_PMX=$P_PMX"; echo "P_TCM=$P_TCM"; echo "P_TCR=$P_TCR"; echo "P_PDR=$P_PDR"
    echo "P_APDO=$P_APDO"; echo "P_PPS=$P_PPS"; echo "P_UV=$P_UV"; echo "P_UI=$P_UI"; echo "P_IS_TOTAL=$P_IS_TOTAL"
    echo "P_UT=$P_UT"
    echo "ONL='$ONL'"
    echo "DC_MODE=$DC_MODE"
    echo "DC1_V=$DC1_V"; echo "DC1_I=$DC1_I"; echo "DC1_Q=$DC1_Q"
    echo "DC2_V=$DC2_V"; echo "DC2_I=$DC2_I"; echo "DC2_Q=$DC2_Q"
    echo "TZ1=$TZ1"; echo "TZ1T=$TZ1T"; echo "TZ2=$TZ2"; echo "TZ2T=$TZ2T"
    echo "TZ3=$TZ3"; echo "TZ3T=$TZ3T"; echo "TZ4=$TZ4"; echo "TZ4T=$TZ4T"
    echo "TZ5=$TZ5"; echo "TZ5T=$TZ5T"; echo "TZ6=$TZ6"; echo "TZ6T=$TZ6T"
    echo "TZ7=$TZ7"; echo "TZ7T=$TZ7T"; echo "TZ8=$TZ8"; echo "TZ8T=$TZ8T"
    echo "XE1=$XE1"; echo "XE2=$XE2"; echo "XE3=$XE3"
    echo "XE4=$XE4"; echo "XE5=$XE5"; echo "XE6=$XE6"
  } > "$_tmp_cache" 2>/dev/null && mv -f "$_tmp_cache" "$CACHE" 2>/dev/null
  . "$CACHE" 2>/dev/null
fi

# ---- 运行期：纯内建 read 输出 ----
rdf _v "$P_SOH";    echo "soh=$_v"
rdf _v "$P_QMAX";   num _v;  echo "qmax_uah=$_v"
rdf _v "$P_RM";     num _v;  echo "rm_uah=$_v"
rdf _v "$P_CELL";   num _v;  echo "cell_uv=$_v"
rdf _v "$P_MODEL";  echo "batt_model=$_v"
rdf _v "$P_VENDOR"; echo "batt_vendor=$_v"
rdf _v "$P_DATE";   echo "batt_date=$_v"
rdf _v "$P_TLEVEL"; num _v;  echo "thermal_level=$_v"
rdf _v "$P_CCC";    num _v;  echo "ccc_max_ua=$_v"
rdf _v "$P_TTF";    num _v;  echo "ttf_sec=$_v"
# 充电协议
rdf _v "$P_QCT";    echo "proto_quick=$_v"
rdf _v "$P_REAL";   echo "proto_real=$_v"
rdf _v "$P_UT";     echo "proto_usb_real=$_v"
rdf _v "$P_PD";     echo "pd_verified=$_v"
rdf _v "$P_PMX";    num _v;  echo "power_max_uw=$_v"
rdf _v "$P_TCM";    echo "typec_mode=$_v"
rdf _v "$P_TCR";    echo "typec_role=$_v"
rdf _v "$P_PDR";    num _v;  echo "pd_rev=$_v"
rdf _v "$P_APDO";   num _v;  echo "apdo_max_ua=$_v"
rdf _v "$P_PPS";    num _v;  echo "pps_ptf=$_v"
# USB
rdf _v "$P_UV";     num _v;  echo "usb_uv=$_v"
rdf _v "$P_UI";     num _v;  [ "$P_IS_TOTAL" = "1" ] && [ -n "$_v" ] && _v=$((_v * 1000)); echo "usb_ua=$_v"
# 在线检测（任一非电池/非BMS 电源 online=1）
_on=0
for _f in $ONL; do
  [ -r "$_f" ] || continue
  IFS= read -r _v < "$_f" 2>/dev/null
  [ "$_v" = "1" ] && { _on=1; break; }
done
echo "online=$_on"
# 双电芯；qcom fg1/fg2 的电流是 mA，统一 ×1000 成 µA（xm fg_master/fg_slave 就是 µA）
echo "dc_mode=$DC_MODE"
if [ "$DC_MODE" != "0" ]; then
  rdf _v "$DC1_V"; num _v; echo "dc1_uv=$_v"
  rdf _v "$DC1_I"; num _v; [ "$DC_MODE" = "1" ] && [ -n "$_v" ] && _v=$((_v * 1000)); echo "dc1_ua=$_v"
  rdf _v "$DC1_Q"; num _v; echo "dc1_qmax_uah=$_v"
  rdf _v "$DC2_V"; num _v; echo "dc2_uv=$_v"
  rdf _v "$DC2_I"; num _v; [ "$DC_MODE" = "1" ] && [ -n "$_v" ] && _v=$((_v * 1000)); echo "dc2_ua=$_v"
  rdf _v "$DC2_Q"; num _v; echo "dc2_qmax_uah=$_v"
fi
# 温区：type:temp_raw（毫氏度，前端 ÷1000）
_tz_out=""
_i=1
while [ "$_i" -le 8 ]; do
  eval "_tzp=\${TZ$_i-}"
  [ -n "$_tzp" ] && [ -r "$_tzp" ] || { _i=$((_i + 1)); continue; }
  rdf _tztemp "$_tzp"
  case "$_tztemp" in *[!0-9]*) _i=$((_i + 1)); continue ;; esac
  eval "_tztype=\${TZ${_i}T}"
  if [ -n "$_tz_out" ]; then _tz_out="$_tz_out,$_tztype:$_tztemp"
  else _tz_out="$_tztype:$_tztemp"; fi
  _i=$((_i + 1))
done
echo "tzlist=$_tz_out"
# xm_power 模糊附加项：文件名清洗键，值单行原样
_i=1
while [ "$_i" -le 6 ]; do
  eval "_xf=\${XE$_i-}"
  if [ -n "$_xf" ] && [ -r "$_xf" ]; then
    rdf _xv "$_xf"
    _xk=${_xf##*/}
    case "$_xk" in *[!A-Za-z0-9_]*) _xk=$(printf '%s' "$_xk" | tr -cd 'A-Za-z0-9_') ;; esac
    if [ -n "$_xk" ]; then
      echo "xm_${_xk}=$_xv"
    fi
  fi
  _i=$((_i + 1))
done
