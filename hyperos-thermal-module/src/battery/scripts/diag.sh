#!/system/bin/sh
# diag.sh — 电池解容工具箱 一键诊断（把整段输出复制给作者）
# v2.6.8：新增『DTBO 现场信息』『BAA 现场信息』（分区指纹 / 模块一致性 / 来源识别）
# v2.6.15：新增『系统/ROM信息（官方包判断参考）』『已装模块』『循环计数』；电源块增强；BAA增加common说明
# v2.6.22n：DTBO生效检查机型化（vcutoff 通用主判 / drop_fv 多路径 / ffc 仅展示）
XBT=/data/adb/modules/HyperOS_XJ/battery
[ -f "$XBT/scripts/common.sh" ] && . "$XBT/scripts/common.sh" 2>/dev/null

# 兜底函数（common.sh 缺失时）
command -v hash_of >/dev/null 2>&1 || hash_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
command -v cfg_get >/dev/null 2>&1 || cfg_get() { echo "$2"; }

echo "===== 电池解容工具箱 诊断 $(date '+%F %T') ====="
echo "--- 机型 / 环境 ---"
echo "model      : $(getprop ro.product.model) / $(getprop ro.product.device)"
echo "dev_code   : $(cfg_get dev_code '')"
echo "slot       : $(getprop ro.boot.slot_suffix)"
echo "android    : $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
echo "rom        : $(getprop ro.mi.os.version.name) $(getprop ro.mi.os.version.incremental)"
echo "kernel     : $(uname -r)"
echo "--- 模块版本 / 开关 ---"
echo "module     : $(grep '^version=' $XBT/module.prop 2>/dev/null | cut -d= -f2)"
echo "unlock=$(cfg_get unlock 1)  cloud_guard=$(cfg_get cloud_guard 1)  fv_guard=$(cfg_get fv_guard 1)"
echo "freepps=$(cfg_get freepps 0)  thermal_guard=$(cfg_get thermal_guard 0)"
echo "power_limit=$(cfg_get power_limit inf)  cycle_fake=$(cfg_get cycle_fake '')  baa_fmt=$(cfg_get baa_fmt auto)  power_mech=${POWER_MECH:-?}  max_ma=${MAX_MA:-?}"
# v3.0.4：补上「强制PPS」的实际节点状态。
#   以前只打印 unlock/cloud_guard/fv_guard，作者排查「到底开没开强制PPS」时
#   只能去翻 freepps 日志（日志只记 "boot -> paused/locked"），非常费劲。
#   这里直接读两个验证节点：pd_verifed 被伪造成 1 就说明 freepps 正在生效。
echo "强制PPS节点: pd_verifed=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null || echo '—')  usbpd_verifed=$(cat /sys/class/Charging_Adapter/pd_adapter/usbpd_verifed 2>/dev/null || echo '—')"

# ============ 系统 / ROM信息（官方包判断参考）============
echo "--- 系统 / ROM信息 ---"
echo "显示版本   : $(getprop ro.build.display.id)"
echo "mod_device : $(getprop ro.product.mod_device)"
echo "增量/补丁  : $(getprop ro.build.version.incremental) / $(getprop ro.build.version.security_patch)"
echo "构建/日期  : $(getprop ro.build.type) / $(getprop ro.build.date)"
echo "签名tags   : $(getprop ro.build.tags) (sys=$(getprop ro.system.build.tags) ven=$(getprop ro.vendor.build.tags))"
echo "debg/secure: $(getprop ro.debuggable) / $(getprop ro.secure)  vb=$(getprop ro.boot.verifiedbootstate) locked=$(getprop ro.boot.flash.locked)"
echo "指纹sys    : $(getprop ro.system.build.fingerprint)"
echo "指纹ven    : $(getprop ro.vendor.build.fingerprint)"
echo "指纹prd    : $(getprop ro.product.build.fingerprint)"
_sus=""
case "$(getprop ro.build.tags)$(getprop ro.system.build.tags)$(getprop ro.vendor.build.tags)" in *test-keys*) _sus="${_sus}含test-keys; " ;; esac
[ "$(getprop ro.debuggable)" = "1" ] && _sus="${_sus}debuggable=1; "
# 注：各分区指纹命名因平台差异可能不同（本机实测 sys=missi / ven=xuanyuan），仅展示供人工参考，不做自动判定
if [ -n "$_sus" ]; then echo "粗判       : ⚠ 疑似非官方/改包（${_sus}仅供参考）"
else echo "粗判       : ✔ 未发现常见改包特征（仅供参考）"; fi

# ============ 已装模块（环境快照）============
echo "--- 已装模块 (/data/adb/modules) ---"
_modn=0
for _m in /data/adb/modules/*/; do
  [ -d "$_m" ] || continue
  _mn=$(basename "$_m"); _modn=1
  if [ "$_mn" = "freepps" ]; then echo "  [集成] $_mn (HyperOS_XJ/battery 数据目录，非独立模块)"
  elif [ -f "$_m/remove" ]; then echo "  [移除中] $_mn"
  elif [ -f "$_m/disable" ]; then echo "  [禁用] $_mn"
  else echo "  [启用] $_mn"; fi
done
[ "$_modn" = "0" ] && echo "  <无>"

# ============ DTBO 现场信息 ============
echo "--- DTBO 现场信息 ---"
_dslot=$(getprop ro.boot.slot_suffix); [ -n "$_dslot" ] || _dslot=_a
echo "当前槽     : $_dslot"
_ddev="/dev/block/by-name/dtbo_${_dslot#_}"
_dlimg="$XBT/dtbo/local.img"
_dsha=""; _dtsz=""
if [ -e "$_ddev" ]; then
  _hdr64=$(dd if="$_ddev" bs=64 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
  _tsz_hex=$(echo "$_hdr64" | cut -c9-16)
  if [ "${#_tsz_hex}" = "8" ]; then
    _dtsz=$((0x$_tsz_hex)) || _dtsz=""
  fi
  if [ -n "$_dtsz" ] && [ "$_dtsz" -ge 64 ] 2>/dev/null && [ "$_dtsz" -le 100000000 ] 2>/dev/null; then
    _dsha=$(head -c "$_dtsz" "$_ddev" 2>/dev/null | sha256sum | awk '{print $1}')
    echo "数据区     : ${_dtsz} B"
    echo "数据区sha  : $_dsha"
    # v2.6.23：供「DTBO 生效检查」使用 —— 哈希一致是最强证据
    _dt_ok=1
    _idv=$(dd if="$_ddev" bs=4 skip=10 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
    if [ -n "$_idv" ] && [ "$_idv" != "00000000" ]; then
      echo "镜像标记   : 0x$_idv (解容镜像✔)"
    else
      echo "镜像标记   : 无标记 (标准镜像无标记属正常；以「结论」行为准)"
    fi
  else
    echo "头部解析   : 异常 (hdr64=$_hdr64)"
  fi
else
  echo "分区设备   : $_ddev <不存在>"
fi
if [ -f "$_dlimg" ]; then
  _lsha=$(hash_of "$_dlimg"); _lsz=$(stat -c %s "$_dlimg")
  echo "模块内置   : ${_lsz} B / $_lsha"
  _pcmp=$(head -c "$_lsz" "$_ddev" 2>/dev/null | sha256sum | awk '{print $1}')
  if [ -n "$_pcmp" ] && [ "$_pcmp" = "$_lsha" ]; then
    echo "结论       : ✔ 当前 dtbo 与模块内置镜像【一致】(解容镜像已就位)"
    _dt_ok=1
  else
    echo "结论       : ✘ 当前 dtbo 与模块内置【不一致】"
    echo "             可能: (1)模块已更新而 dtbo 未重刷 (2)被其它版本覆盖"
    echo "                   (3)系统 OTA 刷回原版 (4)尚未刷入"
    echo "             修复: 通过模块『DTBO 工具』重刷对应版本镜像"
    _dt_ok=0
  fi
else
  echo "模块内置   : $_dlimg <不存在>"
fi
_dmf="$(cfg_get backup_dir '/sdcard/Download/dtbo_backup')/manifest.txt"
[ -f "$_dmf" ] && { echo "最近刷入记录:"; tail -n 2 "$_dmf"; }

# ============ DTBO 生效检查（内核设备树读回）============
echo "--- DTBO 生效检查（/proc/device-tree 读回）---"
_dtbase=""
for b in /proc/device-tree/soc /proc/device-tree/soc@0; do
  [ -d "$b/mca_strategy_quick_charge" ] && { _dtbase="$b"; break; }
done
_rdx() { od -A n -t x1 "$1" 2>/dev/null | tr -d ' \n'; }
_rdx_any() {
  # 多路径尝试读取属性（各机型节点布局不同）
  for _p in strategy-fg mca_strategy_buckchg_class mca_strategy_quick_charge; do
    _v=$(_rdx "$_dtbase/$_p/$1")
    [ -n "$_v" ] && { echo "$_v"; return; }
  done
  echo ""
}
if [ -n "$_dtbase" ]; then
  echo "节点根     : $_dtbase"
  _vc=$(_rdx "$_dtbase/strategy-fg/vcutoff_sw")
  case "$_vc" in
    00000a5a) _c="✔ 解容值(2650)" ;;
    "")       _c="<无该属性>" ;;
    *)        _c="≠ 解容值(疑似原版值)" ;;
  esac
  echo "vcutoff_sw : 0x${_vc:-?}   $_c"
  _df=$(_rdx_any drop_fv_cycle)
  case "$_df" in
    0000ffff|ffffffff) _c="✔ 解容值" ;;
    "")       _c="<该机型无此节点/机制>" ;;
    *)        _c="≠ 解容值(疑似原版值)" ;;
  esac
  echo "drop_fv_cycle : 0x${_df:-?}   $_c"
  _ff=$(_rdx_any ffc_temp_high)
  echo "ffc_temp_high : 0x${_ff:-?}   (各机型设定值不同，仅展示)"
  _v=$(_rdx "$_dtbase/mca_strategy_quick_charge/max_vbat")
  echo "max_vbat   : 0x${_v:-?}   (各机型数值不同,对照模块记录)"
  # ===== v2.6.23 判定重构 =====
  # 旧版（v2.6.8/2.6.9）要求 vcutoff_sw 与 drop_fv_cycle **同时**命中，
  #   而 popsicle / nezha 等机型设备树里**根本没有 drop_fv_cycle 属性**（显示"<无该属性>"），
  #   于是必然误报"DTBO 未生效"，误导用户重复刷写。
  # 新判据（按证据强度排序）：
  #   ① 镜像哈希一致（最强，来自上方『DTBO 现场信息』）→ 直接判生效；
  #   ② vcutoff_sw == 0x00000a5a（解容核心，全机型通用）→ 判生效；
  #   ③ 两者都不满足 → 才提示重刷。
  # 注：drop_fv_cycle / ffc_temp_high 机型差异大，仅作展示，**不参与判定**。
  case "$_dt_ok" in
    1)
      echo "秒判       : ✔ DTBO 已生效（镜像哈希与模块内置完全一致）→ 若仍无感请查 BAA/系统层"
      ;;
    *)
      if [ "$_vc" = "00000a5a" ]; then
        echo "秒判       : ✔ DTBO 已生效（解容特征在设备树中）→ 若仍无感请查 BAA/系统层"
      else
        echo "秒判       : ✘ DTBO 未生效（vcutoff_sw≠2650 且镜像哈希不一致）→ 请重刷模块内镜像"
        echo "             提示: drop_fv_cycle / ffc_temp_high 属机型差异项，缺失不代表未生效"
      fi
      ;;
  esac
else
  echo "节点根     : <未找到 mca_strategy_quick_charge>（节点布局不同或设备树异常）"
fi

# ============ BAA 现场信息 ============
echo "--- BAA 现场信息 ---"
_bd="${BAA_TGT:-/odm/etc/charger/BAA_config_$(cfg_get dev_code xuanyuan).json}"
echo "目标文件   : $_bd"
if [ -f "$_bd" ]; then
  _bsz=$(stat -c %s "$_bd" 2>/dev/null)
  case "$_bsz" in ''|*[!0-9]*) _bsz=0 ;; esac
  _bsha=$(hash_of "$_bd")
  echo "大小       : ${_bsz} B"
  if [ "$_bsz" -le 8 ]; then
    echo "内容       : 空文件 ⚠ 系统BAA为空（魔改包特征）"
    # v3.9.9：空 BAA 不再「跳过挂载」—— 空文件 = 系统没有 BAA 约束，
    #   模块现在照常挂载自己的解容配置（旧行为会让驱动用兜底阶梯把电流锁在 4.5A）。
    echo "适配       : v3.9.9 起【照常挂载】模块 BAA（空文件=系统无约束，写入是纯增益）"
    echo "挂载状态   : $(baa_state 2>/dev/null)（旧版此处为 skipped，会导致 60% 后锁 20W）"
  else
    echo "sha256     : $_bsha"
    _bh8=$(head -c 8 "$_bd" 2>/dev/null)
    case "$_bh8" in
      BAA_ENC:*) echo "格式       : BAA_ENC 加密格式 ✔" ;;
      '{'*)      echo "格式       : 明文 JSON (⚠ 异常,正常应为 BAA_ENC)" ;;
      *)         echo "格式       : 未知 (头8字节=$_bh8)" ;;
    esac
    _psha=$(hash_of "${BAA_SRC:-$XBT/baa/payload_BAA_config_$(cfg_get dev_code xuanyuan).json}")
    _stsha=$(hash_of "${BAA_STOCK:-$XBT/baa/stock_BAA_config_$(cfg_get dev_code xuanyuan).json}")
    if [ -n "$_bsha" ] && [ "$_bsha" = "$_psha" ]; then
      echo "来源识别   : ✔ 与模块改版载荷一致 (cloud-off 已就位)"
    elif [ -n "$_bsha" ] && [ "$_bsha" = "$_stsha" ]; then
      echo "来源识别   : ⚠ 与原版 stock 一致 (改版未生效/被刷回)"
    else
      echo "来源识别   : ? 与模块两侧均不一致 (未知版本)"
    fi
    _mst=$(sh $XBT/scripts/baa_ops.sh check 2>/dev/null)
    case "$_mst" in skipped) _mst="skipped (系统BAA为空,已跳过)" ;; esac
    echo "挂载状态   : $_mst"
  fi
else
  echo "目标文件   : <不存在> (odm 未挂载或文件缺失)"
fi
ls -l /odm/etc/charger/BAA_config_*.json 2>/dev/null
echo "说明       : common为范例文件；系统实际读取 = BAA_config_<设备代号>.json"

echo "--- xm_power 节点（模块使用的固定路径）---"
for p in \
  /sys/class/xm_power/charger/charger_thermal/wired_chg_curr \
  /sys/class/xm_power/charger/charger_thermal/wired_chg_curr2 \
  /sys/class/xm_power/charger/charger_thermal/wireless_chg_curr \
  /sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit \
  /sys/class/xm_power/charger/charger_thermal/wireless_ctrl_limit \
  /sys/class/xm_power/charger/charger_thermal/wired_thermal_remove \
  /sys/class/xm_power/charger/charger_thermal/wireless_thermal_remove; do
  if [ -e "$p" ]; then
    if [ -w "$p" ]; then w=yes; else w=no; fi
    echo "$p = $(cat "$p" 2>/dev/null)  [writable=$w]"
  else
    echo "$p = <不存在>"
  fi
done
scan_nodes() {
  _d="$1"; _n="$2"
  [ "$_n" -le 0 ] && return
  for _p in "$_d"/*; do
    [ -e "$_p" ] || continue
    if [ -d "$_p" ]; then
      scan_nodes "$_p" $((_n - 1))
    else
      case "$_p" in
        *curr*|*current*|*limit*|*thermal*|*chg*|*constant_charge*)
          if [ -w "$_p" ]; then w=yes; else w=no; fi
          echo "$_p = $(cat "$_p" 2>/dev/null)  [writable=$w]" ;;
      esac
    fi
  done
}
echo "--- xm_power 全量扫描（*curr* / *limit* / *thermal* / *chg*）---"
scan_nodes /sys/class/xm_power 4
echo "--- power_supply 设备列表 ---"
ls /sys/class/power_supply/ 2>/dev/null | tr '\n' ' '; echo
echo "--- power_supply 全量 *current* / *curr* / constant_charge* 节点 ---"
scan_nodes /sys/class/power_supply 2

# ============================================================
# v3.9.0 新增：充电路由 / 充电泵 / PD 功率上限 现场
# ------------------------------------------------------------
# 【为什么加这一段】
#   scan_nodes 只能按名字过滤（*curr*|*limit*|*thermal*|*chg*），
#   抓不到真正决定功率的那一层：
#     · cp_master/{vbus,ibus,vpack,tdie}  —— 充电泵实际电气工况
#     · chargerpump/{cp_mode,...}         —— 当前走在 div1/div2/div4 哪一档
#     · charger_common/{real_type,quick_charge_type,power_max}
#     · quick_charge/{cp_path_enable,current_limit,mode_enable,fake_pps_ptf}
#     · 设备树 mca_protocol_pd_class/max_power  —— PD 协议层功率上限
#     · 设备树 support_pps_100w —— 第三方 100W PPS 总开关
#   实测：15 系列 support_pps_100w=0、17 系列=3；PD max_power=90 / 策略 max_power=90000。
#   没有这一段，排查"功率上不去"只能靠临时探针，每次从头来过。
# ============================================================
echo "--- ★★ 充电路由层（v3.9.0 新增，定位功率瓶颈）---"

echo "【A】charge_interface 限制聚合器（格式 <client>:<source> <值> —— 直接告诉你谁在限）"
for _n in charge_enable ichg_limit iin_limit power_limit input_suspend suspend_status; do
  _f=/sys/class/xm_power/charger/charge_interface/$_n
  if [ -e "$_f" ]; then
    if [ -w "$_f" ]; then _w=yes; else _w=no; fi
    echo "  --- $_n  [writable=$_w] ---"
    cat "$_f" 2>/dev/null | sed 's/^/      /'
  else
    echo "  $_n = <不存在>"
  fi
done

echo "【B】charger_common（充电器类型 / 功率上限）"
for _n in real_type quick_charge_type power_max handle_state stop_handle_charge; do
  _f=/sys/class/xm_power/charger/charger_common/$_n
  if [ -e "$_f" ]; then echo "  $_n = $(cat "$_f" 2>/dev/null)"; fi
done

echo "【C】chargerpump（充电泵模式 / 母线电流）"
for _n in cp_mode ibus_delta ibus_total; do
  _f=/sys/class/xm_power/charger/chargerpump/$_n
  if [ -e "$_f" ]; then echo "  $_n = $(cat "$_f" 2>/dev/null)"; fi
done

echo "【D】cp_master（泵实际电气参数 —— vbus/ibus/vpack/tdie 判断走的是哪档）"
for _n in vbus vusb ibus vpack tdie batt_temp fsw ovpgate chip_ok batt_present; do
  _f=/sys/class/xm_power/cp_master/$_n
  if [ -e "$_f" ]; then echo "  $_n = $(cat "$_f" 2>/dev/null)"; fi
done

echo "【E】quick_charge（快充控制 / 泵路径 / PPS）"
for _n in charging_stage cp_path_enable current_limit mode_enable current_ration \
          fake_pps_ptf volt_dec power_max quick_charge_type vfc_iout; do
  _f=/sys/class/xm_power/charger/quick_charge/$_n
  if [ -e "$_f" ]; then
    echo "  --- $_n ---"
    cat "$_f" 2>/dev/null | sed 's/^/      /'
  fi
done

echo "【F】设备树功率上限 / PPS 开关（大端 u32，用字节还原）"
# 注意：设备树属性用 stat -c %s 拿不到大小（返回空），必须用 od 数字节
_dtbe()    { od -An -tu1 -N4 "$1" 2>/dev/null | awk '{printf "%d", $1*16777216+$2*65536+$3*256+$4}'; }
_dtbytes() { od -An -tu1 "$1" 2>/dev/null | tr -s ' \n' ' ' | sed 's/^ *//;s/ *$//'; }
_dtcnt()   { od -An -tu1 "$1" 2>/dev/null | wc -w; }
for _spec in \
  "/proc/device-tree/soc/mca_protocol_pd_class/max_power|PD协议功率上限(W)" \
  "/proc/device-tree/soc/mca_protocol_pd_class/support_mode|PD support_mode" \
  "/proc/device-tree/soc/mca_strategy_quick_charge/max_power|快充策略功率上限(mW)" \
  "/proc/device-tree/soc/mca_strategy_basic_wireless_class/max_power|无线功率上限(W)" \
  "/proc/device-tree/soc/mca_strategy_buckchg_class/support_pps_100w|第三方100W-PPS开关(0=关)" \
  "/proc/device-tree/soc/mca_strategy_quick_charge/max_vbat|电池电压上限(mV)" \
  "/proc/device-tree/soc/mca_vbat_ovp_mon/vbat_ovp_threshold_ffc|过压保护FFC(mV)" \
  "/proc/device-tree/soc/mca_strategy_buckchg_class/ffc_temp_high|快充温区上界(℃)" \
  "/proc/device-tree/soc/mca_strategy_buckchg_class/ffc_temp_low|快充温区下界(℃)" \
  "/proc/device-tree/soc/mca_strategy_buckchg_class/drop_fv_cycle|降容循环阈值" \
  "/proc/device-tree/soc/mca_strategy_quick_charge/die_temp_max|泵芯片温上限" \
  "/proc/device-tree/soc/mca_strategy_quick_charge/adp_temp_max|适配器温上限" \
  "/proc/device-tree/soc/mca_strategy_quick_charge/cp_switch_pmic_th|切PMIC阈值" \
  "/proc/device-tree/soc/mca_strategy_quick_charge/non_mi_pps_max_curr|非小米PPS电流顶[3]" \
  "/proc/device-tree/soc/mca_strategy_quick_charge/div_max_curr|泵最大电流[3]" \
  "/proc/device-tree/soc/mca_strategy_quick_charge/pps_taper_fcc_thr|PPS taper FCC阈值" \
  "/proc/device-tree/soc/mca_strategy_quick_charge/pps_high_taper_fcc_thr|PPS高位taper阈值" \
  ; do
  # ★ 拆分时 | 必须加引号：Android mksh 里 ${var%%|*} 的裸 | 被当模式运算符，
  #   实测返回空串（${var%%"|"*} 才正常）。同样的坑 charge_guard.sh 闭环缓存也踩了，已一并修。
  _p="${_spec%%"|"*}"; _lbl="${_spec##*"|"}"
  if [ -e "$_p" ]; then
    _nb=$(_dtcnt "$_p")
    case "$_nb" in
      4)   echo "  $_lbl = $(_dtbe "$_p")" ;;
      0)   echo "  $_lbl = <空/不可读>" ;;
      *)   echo "  $_lbl = [$(_dtbytes "$_p")]  (${_nb}字节)" ;;
    esac
  else
    echo "  $_lbl = <该机型无此节点>"
  fi
done

echo "【G】USB / PD 端口（判断协商到哪一档）"
for _f in /sys/class/power_supply/usb/voltage_now /sys/class/power_supply/usb/voltage_max \
          /sys/class/power_supply/usb/current_now /sys/class/power_supply/usb/current_max \
          /sys/class/power_supply/usb/online /sys/class/power_supply/usb/type; do
  [ -e "$_f" ] && echo "  ${_f#/sys/class/power_supply/} = $(cat "$_f" 2>/dev/null)"
done
for _d in /sys/class/typec/port*; do
  [ -d "$_d" ] || continue
  for _n in power_operation_mode usb_power_delivery_revision; do
    [ -e "$_d/$_n" ] && echo "  $(basename "$_d")/$_n = $(cat "$_d/$_n" 2>/dev/null)"
  done
done

# 限制聚合器 3 秒采样（看是否跳变 —— 功率震荡的直接证据）
echo "【H】限制聚合器 3 秒采样 × 6（看谁在限、是否跳变）"
echo "     时刻,充电电流限制,输入电流限制,电池mA,VBUSmV"
_i=0
while [ $_i -lt 6 ]; do
  _t=$(date '+%H:%M:%S')
  _ic=$(cat /sys/class/xm_power/charger/charge_interface/ichg_limit 2>/dev/null | tr '\n' ';')
  _in=$(cat /sys/class/xm_power/charger/charge_interface/iin_limit 2>/dev/null | tr '\n' ';')
  _ib=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  _ib=$(( ${_ib:-0} / 1000 )); [ $_ib -lt 0 ] && _ib=$((-_ib))
  _vb=$(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null)
  _vb=$(( ${_vb:-0} / 1000 ))
  echo "     $_t,$_ic,$_in,${_ib},${_vb}"
  _i=$((_i + 1))
  [ $_i -lt 6 ] && sleep 3
done

echo "--- 电池实时 ---"
for f in status capacity health voltage_now current_now current_avg temp charge_full charge_full_design; do
  echo "$f = $(cat /sys/class/power_supply/battery/$f 2>/dev/null)"
done
echo "--- 循环计数 ---"
_cyc=$(cat /sys/class/xm_power/fg_master/cyclecount 2>/dev/null)
_bcyc=$(cat /sys/class/power_supply/battery/cycle_count 2>/dev/null)
_rec=$(cat $XBT/state/last_real_cycle.txt 2>/dev/null)
_cfk=$(cfg_get cycle_fake "")
echo "当前/记录 : ${_cyc:-<无>} / ${_rec:-<无>}   伪装: ${_cfk:-(空=不干预)}"
[ -n "$_bcyc" ] && echo "battery节点: $_bcyc"
echo "守护       : $(sh $XBT/scripts/cycle_guard.sh status 2>/dev/null | head -n 1)"
if [ "$_cyc" = "1" ] && [ -z "$_cfk" ]; then
  echo "提示       : 当前=1且未伪装——常见于'锁循环'魔改系统（系统特征，非模块写入）"
fi
echo "--- 电源 ---"
for f in online type real_type voltage_now voltage_max current_now current_max; do _v=$(cat /sys/class/power_supply/usb/$f 2>/dev/null); [ -n "$_v" ] && echo "usb/$f = $_v"; done

# ============ 充电链路线（v3.0.4 新增）============
# 【为什么加】排「功率上不去 / 方波」时最费时间的就是逐层排除：
#   头有没有给高电压 → PD 鉴权过没过 → 快充类型切没切 → 泵有没有异常 → 解容总闸什么状态。
#   以前这些信息散在 dmesg / 各种 sysfs 里，得来回翻。这里一次全打出来。
echo "--- ★ 充电链路线（逐层定位）---"
_uv=$(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null)
_uvm=$(cat /sys/class/power_supply/usb/voltage_max 2>/dev/null)
_uim=$(cat /sys/class/power_supply/usb/current_max 2>/dev/null)
_uon=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
_uty=$(cat /sys/class/power_supply/usb/type 2>/dev/null)
pv=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)
uv2=$(cat /sys/class/Charging_Adapter/pd_adapter/usbpd_verifed 2>/dev/null)
rt=$(cat /sys/class/qcom-battery/real_type 2>/dev/null)
qt=$(cat /sys/class/qcom-battery/quick_charge_type 2>/dev/null)
urt=$(cat /sys/class/qcom-battery/usb_real_type 2>/dev/null)
_tn=/sys/class/xm_power/charger/charger_thermal/wired_thermal_remove
_cn=/sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit
_kn=/sys/class/xm_power/charger/charger_thermal/wired_chg_curr
_th=$(cat "$_tn" 2>/dev/null); _cl=$(cat "$_cn" 2>/dev/null); _kc=$(cat "$_kn" 2>/dev/null)
_bf=$(cat /sys/class/power_supply/battery/charge_full 2>/dev/null)
_bd=$(cat /sys/class/power_supply/battery/charge_full_design 2>/dev/null)
_cyc=$(cat /sys/class/power_supply/battery/cycle_count 2>/dev/null)

# ① 适配器
echo "① 适配器    : online=${_uon:-?}  type=${_uty:-?}  vbus=$(( ${_uv:-0} / 1000 ))mV  vmax=$(( ${_uvm:-0} / 1000 ))mV  imax=$(( ${_uim:-0} / 1000 ))mA"
# ② PD 鉴权
case "$pv" in
  1) _pdt="✔ 已激活(pd_verifed=1)";;
  0) _pdt="✘ 未激活(pd_verifed=0)";;
  *) _pdt="? 读不到";;
esac
echo "② PD 鉴权   : $_pdt  usbpd_verifed=${uv2:-—}"
# ③ PD 电压档 —— 这是 90W 能不能用上的分水岭
case "$_uon" in
  1)
    if [ "${_uv:-0}" -ge 15000000 ] 2>/dev/null; then
      echo "③ 电压档    : ✔ 高压档（$(( ${_uv:-0} / 1000 ))mV ≥ 15V）—— 90W/120W 路径可用"
    elif [ "${_uv:-0}" -ge 8000000 ] 2>/dev/null; then
      echo "③ 电压档    : ⚠ 低压档（$(( ${_uv:-0} / 1000 ))mV，8~9V）—— 只有 ~20W，90W 用不上"
      echo "              常见原因：非原装/非 5A 线、头不是真 90W、或被系统主动降档"
    else
      echo "③ 电压档    : ⚠ 低电压（$(( ${_uv:-0} / 1000 ))mV，<8V）—— 还在慢充档或未协商完成"
    fi;;
  *) echo "③ 电压档    : ⏸ 未插充电器（usb/online=0），此层无意义";;
esac
# ④ 快充类型
echo "④ 快充类型  : real_type=${rt:-—}  quick_charge_type=${qt:-—}  usb_real_type=${urt:-—}"
# ⑤ 解容总闸
case "$_th" in
  1) _tt="1（DT 温控已绕过·全速档）";;
  0) _tt="0（DT 温控生效·限流档）";;
  *) _tt="${_th:-?}";;
esac
echo "⑤ 解容总闸  : thermal_remove=$_tt  ctrl_limit=${_cl:-?}  wired_chg_curr=${_kc:-?}µA（$(( ${_kc:-0} / 1000 ))mA）"
# ⑥ 充电泵异常 —— 从 dmesg 数，>0 就说明泵在反复报错（方波的典型根因）
_pcp=-1
if command -v dmesg >/dev/null 2>&1; then
  _pcp=$(dmesg 2>/dev/null | grep -c 'cp work abnormal' 2>/dev/null)
  case "$_pcp" in ''|*[!0-9]*) _pcp=-1 ;; esac
fi
if [ "$_pcp" -gt 0 ] 2>/dev/null; then
  echo "⑥ 充电泵    : ✘ cp work abnormal ×$_pcp —— 泵反复异常，会导致「充—停—充」方波"
  echo "              这是【驱动层】问题，与模块限流参数无关（模块只动热控/电流节点）"
elif [ "$_pcp" = "0" ]; then
  echo "⑥ 充电泵    : ✔ dmesg 未见 cp work abnormal"
else
  echo "⑥ 充电泵    : ? dmesg 受限，无法统计"
fi
# ⑦ 电池健康
if [ -n "$_bf" ] && [ -n "$_bd" ] && [ "$_bd" -gt 0 ] 2>/dev/null; then
  echo "⑦ 电池健康  : ${_bf}/${_bd} mAh = $(( _bf * 100 / _bd ))%   循环 ${_cyc:-?} 次"
  [ $(( _bf * 100 / _bd )) -lt 88 ] 2>/dev/null && \
    echo "              ⚠ 健康度偏低 → 老化电池更易在内阻压降下触发 OVP/泵异常"
fi
echo "判读要点 : ①→②→③→④ 任意一层断了，后面的「模块参数」都无从谈起；"
echo "           ⑤ 决定绕不绕 DT 温控；⑥ 是方波的直接证据。"

echo "--- charge_guard 状态 ---"
sh "$XBT/scripts/charge_guard.sh" status 2>/dev/null

echo "--- 功率控制自检 ---"
_pw=$(cfg_get power_limit inf)
_tn=/sys/class/xm_power/charger/charger_thermal/wired_thermal_remove
_cn=/sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit
_kn=/sys/class/xm_power/charger/charger_thermal/wired_chg_curr
_th=$(cat "$_tn" 2>/dev/null)
_cl=$(cat "$_cn" 2>/dev/null)
echo "power_limit = $_pw"
# v3.0.5：self-check 判据按【真实】行为重写（v3.0.2 那一版把 th 期望值写错了）。
#   ★ v3.0.2 的错误：把 fast/mid/slow 的期望也写成 thermal_remove=1。
#     但 common.sh 的 thermal_target() 是：
#         if [ "$1" = "inf" ]; then thermal_target; else echo 0; fi
#     ⇒ **只有 inf 档才把 thermal_remove 置 1**；fast/mid/slow 一律置 0（DT 温控表照常生效），
#       限流由 ctrl 阶梯施加：fast|mid → MID_CTRL(默认4)，slow → SLOW_CTRL(默认14)。
#     所以 v3.0.2 写的期望值会让「mid 档插着充电器诊断」时必然误报
#         「✘ mid 期望 th=1/ctrl=4，实测 th=0/ctrl=4 → 未生效」
#     —— 假警。本次靠"未充电"分支侥幸没暴露（用户诊断时是拔枪状态）。
#   真机反证（haotian v3.0.3 / 2026-10-17 23:24 诊断包）：
#       power_limit=mid 时实测 thermal_remove=0 ctrl_limit=4 curr=7200000 → 这才是正确的。
#   另外：拔枪后驱动会把 thermal_remove / ctrl_limit 重置，所以「未充电」时
#   不能用这些节点的值判断档位是否生效 —— 必须单独区分（这条 v3.0.2 是对的，保留）。
_mech=$(cfg_get power_mech curr)
case "$_pw" in
  inf)      _need_th=1; _need_cl=0 ;;
  fast|mid) _need_th=0; _need_cl=$(cfg_get mid_ctrl 4) ;;
  slow)     _need_th=0; _need_cl=$(cfg_get slow_ctrl 14) ;;
  *)        _need_th=0; _need_cl=0 ;;
esac
case "$_need_cl" in ''|*[!0-9]*) _need_cl=0 ;; esac
if [ "$_need_th" = "1" ]; then
  _exp="thermal_remove=1 + ctrl_limit=$_need_cl（全速档：绕过 DT 温控表，不限流）"
else
  _exp="thermal_remove=0 + ctrl_limit=$_need_cl（限流档：DT 温控表生效，限流走 ctrl 阶梯）"
fi
echo "期望       : $_exp"
echo "实测       : thermal_remove=$_th ctrl_limit=$_cl curr=$_kn -> $(cat "$_kn" 2>/dev/null)"
_chg_now=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
case "$_pw" in
  inf)
    if [ "$_th" = "1" ]; then echo "结论       : ✔ inf 解容总闸已开启（thermal_remove=1）"
    else echo "结论       : ✘ inf 但 thermal_remove=$_th（应为 1）→ 功率会被 DT 温控表压制"; fi ;;
  fast|mid|slow)
    case "$_chg_now" in
      *Charging*|Full)
        if [ "$_th" = "$_need_th" ] && [ "$_cl" = "$_need_cl" ]; then
          echo "结论       : ✔ $_pw 档已生效（th=$_th ctrl=$_cl，与期望一致；curr=$(cat "$_kn" 2>/dev/null)µA）"
        else
          echo "结论       : ✘ $_pw 期望 th=$_need_th/ctrl=$_need_cl，实测 th=$_th/ctrl=$_cl → 未生效"
        fi ;;
      *)
        echo "结论       : ⏸ 当前未充电（$_chg_now）—— 驱动会把 th/ctrl 重置，"
        echo "             此处读数不代表档位失效，插上充电器后再看本节" ;;
    esac ;;
esac
[ -w "$_tn" ] || echo "警告       : $_tn 不可写 → 运行时无法设置解容总闸"
[ -w "$_cn" ] || echo "警告       : $_cn 不可写 → ctrl 阶梯限流可能无法生效"
echo "限流机制   : power_mech=$_mech（curr=写电流节点+ctrl阶梯；ctrl=旧 ctrl 阶梯）"

echo "--- 限值核验（curr 机制）---"
_pm=$(cat "$XBT/state/power_mode_applied" 2>/dev/null)
_rs=$(cat "$XBT/state/rewrite_streak" 2>/dev/null)
echo "已应用/目标: ${_pm:-<无>} / $(power_now)   rewrite_streak=${_rs:-0}"
if [ "$(power_now)" = "inf" ]; then
  # v3.0.7【修复：这里以前写死 "20000 mA (固定，放行全速)"】
  #   v3.0.4 起 tier_target_ma inf 会按该机型 MAX_MA 钳制（xuanyuan/haotian 标准 8000），
  #   写死的 20000 会让作者误判「模块还在写 20A」，实际不是 —— 真机诊断包里已经出现过。
  #   现在直接调用函数取真实值，并把可覆盖方式一起写出来。
  _itma=$(tier_target_ma inf 2>/dev/null)
  case "$_itma" in ''|*[!0-9]*) _itma="?" ;; esac
  _imm=$(cfg_get max_ma 2>/dev/null)
  echo "目标电流   : ${_itma} mA（inf 目标 = 该机型 MAX_MA${_imm:+=$_imm}；可在 settings 用 max_ma 覆盖，上限 20000）"
else
  _tma=$(tier_target_ma "$(power_now)" 2>/dev/null)
  echo "目标电流   : ${_tma:-?} mA (按实时电压换算)"
fi
_bi=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
_ni=$(cat "$DIRECT_WIRED" 2>/dev/null)
echo "电池电流   : ${_bi:-?} µA / 节点: ${_ni:-?} µA"

echo "--- 节点稳定性探测（2 秒，判断系统是否在改写）---"
_s1="$(cat "$_tn" 2>/dev/null)|$(cat "$_cn" 2>/dev/null)|$(cat "$_kn" 2>/dev/null)"
sleep 2
_s2="$(cat "$_tn" 2>/dev/null)|$(cat "$_cn" 2>/dev/null)|$(cat "$_kn" 2>/dev/null)"
if [ "$_s1" = "$_s2" ]; then
  echo "稳定       : ✔ 2 秒内节点未变化 ($_s1)"
else
  echo "变动       : ⚠ 2 秒内节点变化 $_s1 -> $_s2"
  echo "             （ctrl/curr 变动=系统快充步进，正常；thermal_remove 变动=可能被抢控制位）"
fi

# ============ v2.7 新增：充电契约现场（定位"突然掉功率/需拔插"类问题）============
# 背景：17PM 用户反馈"突然掉 10W，需拔插才恢复"。这类问题根源在 mca_quick_charge
#       状态机与 PD/PPS 契约，外部只能看"驱动目标电流 vs 实际输出"的缺口来判断。
echo "--- 充电契约现场（v2.7 新增）---"
_usbv=/sys/class/power_supply/usb/voltage_now
_usbi=/sys/class/power_supply/usb/current_now
_usbvmax=/sys/class/power_supply/usb/voltage_max
_uscimax=/sys/class/power_supply/usb/current_max
_usicl=/sys/class/power_supply/usb/input_current_limit
_uonl=/sys/class/power_supply/usb/online
_biv=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
_bic=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
echo "适配器输出 : $(cat $_usbv 2>/dev/null) µV / $(cat $_usbi 2>/dev/null) µA   online=$(cat $_uonl 2>/dev/null)"
echo "适配器能力 : voltage_max=$(cat $_usbvmax 2>/dev/null) current_max=$(cat $_uscimax 2>/dev/null)"
echo "输入限流   : input_current_limit=$(cat $_usicl 2>/dev/null)"
echo "电池       : $(cat /sys/class/power_supply/battery/status 2>/dev/null) · voltage=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null) µV · current=$_bic µA"
echo "模块目标   : curr=$(cat "$_kn" 2>/dev/null) µA ($(power_label))  已应用=$(cat $XBT/state/power_mode_applied 2>/dev/null)"
# 目标 vs 实际缺口：判定"契约是否满足不了请求"
case "$_bic" in ''|*[!0-9-]*) _bic="" ;; esac
_knv=$(cat "$_kn" 2>/dev/null)
case "$_knv" in ''|*[!0-9]*) _knv="" ;; esac
_bst=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
if [ "$_bst" = "Discharging" ] || [ "$_bst" = "Not charging" ]; then
  # 未充电时算"达成率"无意义（会误报 0% 严重不达标）
  echo "达成率     : —（当前未充电：$_bst，需插上充电器后此项才有意义）"
  case "$_pw" in
    inf) echo "判定       : 当前为全速挡；插充电器后本行会给出契约达成率" ;;
    *)   echo "判定       : 当前选中 $(power_label)；插充电器后本行会给出契约达成率" ;;
  esac
elif [ -n "$_bic" ] && [ -n "$_knv" ] && [ "$_knv" -gt 0 ]; then
  _abs=${_bic#-}
  _pct=$(( _abs * 100 / _knv ))
  # v2.7.2：先把 SOC / 温度取出来，用于判断"低达成率"到底是故障还是物理必然
  _socv=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  case "$_socv" in ''|*[!0-9]*) _socv=0 ;; esac
  _tv=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
  case "$_tv" in ''|*[!0-9]*) _tv=0 ;; esac
  _ccl=$(cat /sys/class/power_supply/battery/constant_charge_current 2>/dev/null)
  case "$_ccl" in ''|*[!0-9]*) _ccl="" ;; esac
  echo "达成率     : ${_pct}%  (实际电池电流 $_abs ÷ 模块目标 $_knv)"
  # ---- v2.7.13 修正：运算符优先级 bug ----
  #   旧写法：if [ "$_socv" -ge 90 ] || [ -n "$_ccl" ] && [ "$_ccl" = "0" ]
  #     shell 里 && 优先级【高于】||  → 实际等价于 A || (B && C)
  #     → 只要 constant_charge_current == 0 就命中"充电末期"分支，
  #       于是 7% 电量的用户被告知"电池已进入充电末期"（实测反馈里的错误判定）
  #   新写法：显式加括号分组，并且【高电量】与【ccl=0】两种情况分开给结论文字。
  if [ "$_socv" -ge 90 ] || { [ -n "$_ccl" ] && [ "$_ccl" = "0" ] && [ "$_socv" -ge 70 ]; }; then
    echo "判定       : ✔ 属【正常现象】—— 电量 ${_socv}%，电池已进入充电末期"
    echo "             此时电池只能接受小电流（恒压段），电流会持续下降并在停充/补充间小幅跳动，"
    echo "             表现为\"功率忽高忽低、越来越小\"，属锂电正常特性，不是模块或充电器故障。"
    echo "             若要验证全速功率，请把电量放到 30~60% 再测（低温、关屏、原装头线）。"
  elif [ "$_tv" -ge 430 ]; then
    echo "判定       : ⚠ 温度偏高（$(( _tv / 10 )).$(( _tv % 10 ))℃）导致限流 —— 属保护行为，不是故障"
  elif [ "$_pct" -lt 30 ]; then
    if [ "$_socv" -lt 30 ]; then
      # 低电量本身就要大电流，此时达成率低【更可疑】：正常应该满速
      echo "判定       : ✘ 严重不达标 → 驱动/适配器未能满足请求（契约降档或适配器能力不足）"
      echo "             电量仅 ${_socv}%（本应满速段），温度不高却远低于所选档位 → 重点看下方内核评估"
      echo "             常见原因：充电头/线不支持高压 PPS（如只协商到 PD2.0 9V）、"
      echo "                       协议反复重协商、充电口接触不良"
    else
      echo "判定       : ✘ 严重不达标 → 驱动/适配器未能满足请求（契约降档或适配器能力不足）"
      echo "             电量 ${_socv}% 且温度正常却仍远低于所选档位 → 重点看下方内核评估"
    fi
  elif [ "$_pct" -lt 60 ]; then
    echo "判定       : ⚠ 偏低（适配器能力边界 / 快充步进中，结合上方适配器能力与 SOC 判断）"
  else
    echo "判定       : ✔ 接近目标，契约正常"
  fi
else
  echo "判定       : ? 无法计算（节点或电池电流不可读）"
fi

echo "--- 驱动内部评估（看契约为何受限）---"
# v2.7.2：机型驱动不同 —— xuanyuan/nezha 走 mca_quick_charge，
#   haotian 等走 mca_strategy_buckchg。两种都抓，避免某些机型此段空白。
_dm1=$(dmesg 2>/dev/null | grep -a 'mca_quick_charge_regulation' | tail -n 3)
_dm2=$(dmesg 2>/dev/null | grep -a 'mca_strategy_buckchg' | tail -n 3)
if [ -n "$_dm1" ]; then
  echo "  [mca_quick_charge] 格式: cur_stage[N]: adp_volt 请求/实际, ibat 请求/?/实际/?"
  echo "$_dm1" | sed 's/^/    /'
  echo "  解读: adp_volt 请求≠实际 → 适配器给不到该电压（PPS/PD 契约受限）"
fi
if [ -n "$_dm2" ]; then
  echo "  [mca_strategy_buckchg] 充电状态与限流来源"
  echo "$_dm2" | sed 's/^/    /'
  echo "  解读: ap_icl=适配器输入限流, ichg=充电电流限制（volt_thermal_limit=温控/电压联合限）"
fi
[ -z "$_dm1" ] && [ -z "$_dm2" ] && echo "  （无权限读 dmesg，或该机型两者都无）"

# ============ v2.7.8 新增：功率波形/锯齿 专用现场 ============
# 【为什么需要】"功率忽高忽低 / 有波形"这一类反馈，作者最需要三样东西：
#   ① 模块到底写了几次电流节点（写多了 = 反复 PD 重协商 = 波形主因）
#   ② 距上次写还有多久（判断"功率低"是被全局限流挡住，还是写了没用）
#   ③ 电池是否在 Charging↔Full 反复跳变（≥80% 电量的典型特征，旧版会误判为拔插）
echo "--- ★ 功率波形/锯齿 现场（v2.7.8 新增）---"
_lw=$(cat $XBT/state/cg_last_write_ts 2>/dev/null)
case "$_lw" in ''|*[!0-9]*) _lw="" ;; esac
_gap=$(cfg_get cg_min_write_gap 60)
case "$_gap" in ''|*[!0-9]*) _gap=60 ;; esac
if [ -n "$_lw" ]; then
  _now=$(date +%s)
  # v2.7.8：防未来时间戳 / Android shell 32 位溢出（实测 $(( )) 溢出会得出正数）
  if [ "$_lw" -gt "$_now" ] 2>/dev/null; then
    echo "  上次写电流节点 : 时间戳异常（在未来，可能系统时间被回拨或被改过）"
    echo "  当前状态       : ✔ 按无效处理，允许写"
  else
    _since=$((_now - _lw))
    case "$_since" in ''|*[!0-9]*) _since=0 ;; esac
    _left=$((_gap - _since))
    [ "$_left" -lt 0 ] && _left=0
    echo "  上次写电流节点 : ${_since} 秒前"
    echo "  全局限流间隔   : ${_gap} 秒（settings 的 cg_min_write_gap）"
    if [ "$_left" -gt 0 ]; then
      echo "  当前状态       : ⏸ 仍在限流窗口内（还需 ${_left} 秒才允许再写）"
      echo "                   → 若此刻功率低，属【模块主动不发重协商】，不是故障"
    else
      echo "  当前状态       : ✔ 已过限流窗口，允许写"
    fi
  fi
else
  echo "  上次写电流节点 : （本次开机尚未写过）"
fi
echo "  inf 安顿标志   : $([ -f $XBT/state/inf_settled ] && echo '已安顿(不再写)' || echo '未安顿')"
echo "  inf 节流时间戳 : $([ -f $XBT/state/inf_settle_ts ] && echo 存在 || echo 无)"
echo "  inf 失败计数   : $(cat $XBT/state/inf_settle_fail 2>/dev/null || echo 无)"
echo "  --- 模块写入次数统计（本次开机）---"
# v3.0.5【修复：以前其实是"全日志累计"，标签写"本次开机"会严重误导】
#   真机反证（haotian v3.0.3 / 2026-10-17 23:24 诊断包）：开机只有 1580 秒，
#   却报「inf 安顿成功 = 19」；而安顿有 60 秒节流，26 分钟内最多 26 次，
#   19 次说明这个数字是跨了几十个开机的累计 —— 作者按这个数字判断"系统在反复压低节点"
#   会被带偏（我这次就差点被带偏）。
#   修法：以日志里最后一条 "service: start"（每次开机都会写）为界，只数它之后的行。
_logf=${LOG:-/data/local/tmp/xt_toolbox.log}
_ln_total=$(wc -l < "$_logf" 2>/dev/null)
case "$_ln_total" in ''|*[!0-9]*) _ln_total=0 ;; esac
_ln_boot=$(grep -an 'service: start' "$_logf" 2>/dev/null | tail -1 | cut -d: -f1)
case "$_ln_boot" in ''|*[!0-9]*) _ln_boot=0 ;; esac
if [ "$_ln_boot" -gt 0 ] 2>/dev/null && [ "$_ln_total" -gt "$_ln_boot" ] 2>/dev/null; then
  _lncnt=$(( _ln_total - _ln_boot ))
  echo "    （统计范围：本次开机后的 $_lncnt 行 / 全日志 $_ln_total 行）"
else
  _lncnt=$_ln_total
  echo "    ⚠ 未找到本次开机标记，以下为【全日志累计】（跨多次开机，勿当作单次行为）"
fi
for _kw in "inf 安顿成功" "inf 安顿未生效" "inf 自纠正" "inf 该机型电流节点上限" "inf 补写被全局限流挡住" "charger event"; do
  if [ "$_lncnt" -gt 0 ] 2>/dev/null; then
    _n=$(tail -n "$_lncnt" "$_logf" 2>/dev/null | grep -ac "$_kw")
  else
    _n=0
  fi
  echo "  $(printf '%-28s' "$_kw") = ${_n:-0}"
done
echo "  --- 电池状态跳变（Charging↔Full 高频 = CV 段抖动，非拔插）---"
_bs=$(dmesg 2>/dev/null | grep -aoE 'chg_status: [0-9]+' | tail -20 | sort | uniq -c | sort -rn | head -4)
if [ -n "$_bs" ]; then echo "$_bs" | sed 's/^/    /'; else echo "    （无 dmesg 记录）"; fi
echo "  解读: 若「充电状态跳变」很频繁且电量 ≥80% → 属正常 CV 段充满-补充循环，"
echo "        模块已按 v2.7.8 逻辑【不再把它当拔插清旗】，不会因此反复重协商。"
echo "        若「inf 安顿成功」次数很多（>10 次/小时）→ 说明系统在反复压低节点，"
echo "        请把本诊断发给作者（需要看是不是有其它进程在抢节点）。"


echo "--- 充电相关内核异常（有则说明驱动层报错/降档）---"
_dm=$(dmesg 2>/dev/null | grep -aiE 'mca_quick_charge|mca_strategy_quick|mca_charger_thermal|pd_|pps|typec|tcpm|over.?temp|OVP|OCP|reverse|adapter' \
  | grep -aiE 'err|fail|error|abnormal|over|warn|timeout|reject|reset|retry|drop|degrade|protect' | tail -n 10)
if [ -n "$_dm" ]; then echo "$_dm" | sed 's/^/  /'; else echo "  ✔ 未发现充电相关内核错误/降档记录"; fi

echo "--- 充电事件时间线（内核 + 模块日志对齐）---"
echo "内核 charger 事件:"
dmesg 2>/dev/null | grep -aiE 'charger|chg_|usb.*(insert|remove|connect)|cc_orient|vbus' | tail -n 6 | sed 's/^/  /' \
  || echo "  （无）"
echo "模块充电日志（最近 6 条）:"
grep -aE 'charge_guard: (tier=|charger event)|thermal_guard: (ON|OFF|re-apply)|closed_loop' \
  "${LOG:-/data/local/tmp/xt_toolbox.log}" 2>/dev/null | tail -n 6 | sed 's/^/  /' \
  || echo "  （无）"

echo "--- typec / PD 端口状态（有则能看出连接与角色）---"
for f in /sys/class/typec/port0/data_role /sys/class/typec/port0/power_role \
         /sys/class/typec/port0/power_operation_mode /sys/class/typec/port0/vconn_source \
         /sys/class/typec/port0/usb_power_delivery_revision; do
  [ -e "$f" ] && echo "  $(basename $f) = $(cat "$f" 2>/dev/null)"
done
for f in /sys/class/typec/port0-partner/*; do
  [ -e "$f" ] || continue
  case "$(basename $f)" in
    supports_usb_power_delivery|usb_power_delivery_revision|number_of_alternate_modes)
      echo "  partner/$(basename $f) = $(cat "$f" 2>/dev/null)" ;;
  esac
done

echo "--- 温控守护状态（判断是否为温控介入所致）---"
echo "  thermal_guard=$(cfg_get thermal_guard 0) limit=$(cfg_get thermal_limit 45)C hyst=$(cfg_get thermal_hyst 4)C action=$(cfg_get thermal_action slow)"
echo "  保护快照  : $([ -f $XBT/state/thermal_prev ] && echo "存在(保护中) [$(cat $XBT/state/thermal_prev 2>/dev/null | tr '\n' ' ')]" || echo "无(未触发)")"
echo "  守护进程  : $(timeout 5 pgrep -cf 'HyperOS_XJ/battery/scripts/[t]hermal_guard\.sh' 2>/dev/null || echo 0) 个实例"
echo "  最近温控日志:"
grep -a 'thermal_guard' "${LOG:-/data/local/tmp/xt_toolbox.log}" 2>/dev/null | tail -n 4 | sed 's/^/    /' \
  || echo "    （无）"

echo "--- 各守护单实例核验（多实例会互相抢节点）---"
# 注意：模式用字符类 [x] 包住首字母，避免 pgrep 匹配到自己
for _pat in \
  'HyperOS_XJ/battery/scripts/[c]harge_guard\.sh' \
  'HyperOS_XJ/battery/scripts/[c]loud_guard\.sh' \
  'HyperOS_XJ/battery/scripts/[t]hermal_guard\.sh' \
  'HyperOS_XJ/battery/scripts/[c]ycle_guard\.sh' \
  'HyperOS_XJ/battery/scripts/[f]v_guard\.sh' \
  'HyperOS_XJ/battery/scripts/[f]v_handler\.sh'; do
  _lbl=$(echo "$_pat" | sed 's/.*\[\(.\)\]/\1/; s/\\\.sh//')
  _n=$(timeout 5 pgrep -cf "$_pat" 2>/dev/null)
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  echo "  $_lbl = $_n"
done

echo "--- 循环计数（真实值 vs 伪装值）---"
echo "  显示值(cyclecount)   : $(cat /sys/class/xm_power/fg_master/cyclecount 2>/dev/null)"
echo "  battery/cycle_count  : $(cat /sys/class/power_supply/battery/cycle_count 2>/dev/null)"
echo "  真实值(qmax_cyclecount): $(cat /sys/class/xm_power/fg_master/qmax_cyclecount 2>/dev/null)"
echo "  伪装设置(cycle_fake) : $(cfg_get cycle_fake '(空=不干预)')"
echo "  真实值记录文件       : $(cat $XBT/state/last_real_cycle.txt 2>/dev/null || echo '(未记录)')"

echo "--- 判读速览 ---"
echo "--- 自适应功率爬坡器（APL）现场 ---"
_ap="$XBT/state/apl.csv"
_pf="$XBT/state/apl_profile.$(cfg_get dev_code unknown).kv"
echo "进程 pid   : $(cat $XBT/state/apl.pid 2>/dev/null)"
echo "当前目标   : $(cat $XBT/state/apl_target_ma 2>/dev/null) mA"
echo "硬上限     : $(dt_curr_cap_ma 2>/dev/null) mA"
echo "锁定至     : $(cat $XBT/state/apl_lock_until 2>/dev/null)"
if [ -f "$_pf" ]; then
  echo "学习档案   :"
  sed 's/^/    /' "$_pf" 2>/dev/null
else
  echo "学习档案   : (无，尚未学习到任何 SOC 段)"
fi
if [ -f "$_ap" ]; then
  echo "采样日志   : $(wc -l < "$_ap" 2>/dev/null) 行（末 40 行）"
  tail -40 "$_ap" 2>/dev/null | sed 's/^/    /'
else
  echo "采样日志   : (无)"
fi
echo
echo "① DTBO：见上方『DTBO 现场信息』结论行（一致=解容镜像已就位）"
echo "② BAA ：active=改版已生效；skipped=系统BAA为空(魔改包→已跳过)；inactive=待重挂"
echo "③ 掉功率/需拔插类：重点看『充电契约现场』达成率 + 『驱动内部评估』adp_volt 请求/实际"
echo "④ 充电异常但两项均 OK → 附上本诊断 + 充电器型号/电量/温度 反馈作者"
echo "===== 诊断结束（请把以上整段复制给作者）====="