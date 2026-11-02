#!/system/bin/sh
# diagnose.sh —— 整个模块（温控 + 解容）的一键诊断与日志打包
#
# 目的：一次采集就能定位「温控 / 充电功率 / 解容 / 系统」四层的问题，
#       而不是只抓一堆原始节点让排查者自己拼。
#
# 产出：/sdcard/Download/诊断包_<月-日-时-分>.tar.gz
# 包内结构：
#   README.txt        包内导航（每个文件是什么、先看哪个）
#   00-总览.txt        一页速览：设备 / 模块 / 温控链路 / 解容状态 / 守护进程
#   10-温控/           自检、温控核心日志、关键事件、配置与运行标记、当前温控目录
#   20-解容/           解容配置与状态、解容侧文本诊断、解容日志
#   30-节点/           电池 / 充电 / 无线 / BAA / DT 快充 现场节点
#   40-系统/           机型信息、模块文件与校验、进程、dmesg、logcat、模块外备份
#   50-停充.txt        停充现场记录（stop_charge.log）
#
# 只读采集，不写任何系统节点；文本按白名单脱敏（序列号 / IMEI / MAC / 手机号）。

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/HyperOS_XJ
CONFDIR="$MODDIR/config"
XBT="$MODDIR/battery"
OUTDIR=/sdcard/Download
TS=$(date +%Y%m%d_%H%M%S)
TSF=$(date +%m-%d-%H-%M)
WORK=/data/local/tmp/xj_diag_$TS
OUT="$OUTDIR/诊断包_$TSF.tar.gz"
TL="$CONFDIR/rt_thermal_path"
STEP=0
FAIL=0

hr()   { echo "------------------------------------------"; }
step() { STEP=$((STEP + 1)); hr; echo " [$STEP/9] $2"; }

nread() { timeout 1 cat "$1" 2>/dev/null; }

# 从温控 settings.json 取一个键的值（够用即可，不引 JSON 解析器）
jget() {
    _k="$1"; _d="$2"
    if [ ! -f "$CONFDIR/settings.json" ]; then printf '%s' "$_d"; return 0; fi
    _v=$(grep -o "\"$_k\"[[:space:]]*:[[:space:]]*[^,}]*" "$CONFDIR/settings.json" 2>/dev/null \
        | head -n 1 | sed 's/.*:[[:space:]]*//' | tr -d '"' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$_d"
}

sanitize() {
    sed -E \
        -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/**:**:**:**:**:**/g' \
        -e 's/(1[3-9][0-9])[0-9]{4}([0-9]{4})/\1****\2/g' \
        -e 's/(sn|serial|Serial|imei|IMEI|meid|MEID)([=: ]+)([0-9A-Za-z]{4})[0-9A-Za-z]{4,}/\1\2\3****/g'
}

# 对一个文本文件就地脱敏
scrub() { [ -f "$1" ] || return 0; sanitize < "$1" > "$1.scrub" 2>/dev/null && mv -f "$1.scrub" "$1" 2>/dev/null; }

hr
echo " - HyperOS - 动态温控·解容"
echo " - 诊断与日志打包（整个模块：温控 + 解容）"
echo " - 时间: $(date '+%F %T')"
hr

if [ ! -x "$MODDIR/thermal_core.sh" ]; then
    chmod 0755 "$MODDIR/thermal_core.sh" 2>/dev/null
fi

D_T="$WORK/10-温控"
D_B="$WORK/20-解容"
D_N="$WORK/30-节点"
D_S="$WORK/40-系统"
mkdir -p "$OUTDIR" "$D_T/配置" "$D_T/thermal" "$D_B/state" "$D_N" "$D_S" 2>/dev/null
if [ ! -d "$WORK" ]; then
    hr
    echo " !! 无法创建临时目录 $WORK"
    echo " !! 请确认已授予 root 权限后重试"
    hr
    exit 1
fi

# ---------- 1 模块自检 ----------
step 1 "温控核心自检"
"$MODDIR/thermal_core.sh" "$MODDIR" selfcheck > "$D_T/自检.txt" 2>&1
SC=$?
echo " - 自检退出码: $SC（详见 10-温控/自检.txt）"
[ "$SC" = "0" ] || FAIL=$((FAIL + 1))

# ---------- 2 总览 ----------
step 2 "汇总总览"
TP="$(cat "$TL" 2>/dev/null)"
[ -n "$TP" ] || TP=/data/vendor/thermal/config
{
    echo "# 模块总览（$(date '+%F %T')）"
    echo
    echo "== 设备 =="
    echo "机型     : $(getprop ro.product.marketname) / $(getprop ro.product.model)"
    echo "代号     : $(getprop ro.product.device)"
    echo "平台     : $(getprop ro.board.platform)   芯片: $(getprop ro.soc.model)"
    echo "系统     : $(getprop ro.mi.os.version.incremental) / Android $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
    echo "内核     : $(uname -r)   槽位: $(getprop ro.boot.slot_suffix)"
    echo "Root     : $([ -d /data/adb/ksu ] && echo KernelSU || ([ -d /data/adb/ap ] && echo APatch || echo Magisk))"
    echo "安装模式 : $([ -f "$CONFDIR/mtk_fix" ] && echo 天玑修复版 || echo 标准版)"
    echo
    echo "== 模块 =="
    echo "版本     : $(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | sed 's/^version=//')  (code $(grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | sed 's/^versionCode=//'))"
    echo "描述     : $(grep '^description=' "$MODDIR/module.prop" 2>/dev/null | sed 's/^description=//')"
    echo "自检     : 退出码 $SC"
    echo "温控目录 : $TP"
    echo
    echo "== 温控（档位与场景）=="
    echo "模块开关 : $(jget enabled true)"
    echo "当前档位 : $(cat "$CONFDIR/current_mode" 2>/dev/null)"
    echo "默认场景 : $(jget default_mode default)"
    echo "充电场景 : $(jget charge_mode true)  亮屏 $(jget charge_level unlimited) / 息屏 $(jget sleep_level '-')"
    echo "游戏场景 : $(jget game_mode true)  $(jget game_level unlimited)  锁帧 $(jget game_fps 0)"
    echo "旁路供电 : $(jget bypass_temp_on 0)℃/$(jget bypass_temp_off 0)℃  $(jget bypass_current 500000)µA"
    echo "三倍速   : $(jget hyperos4 false)    解除高温停充: $(jget no_hitemp_stop false)"
    echo "定时充电计划: $(jget power_plan_on false)  $(jget power_plan_start 23)点-$(jget power_plan_end 7)点 $(jget power_plan_mode slow)"
    echo
    echo "== 温控链路自检（降充电功率是否生效）=="
    timeout 20 "$MODDIR/thermal_core.sh" "$MODDIR" linkstatus 2>&1
    echo
    echo "== 解容状态（status_kv.sh）=="
    sh "$XBT/scripts/status_kv.sh" 2>/dev/null
} > "$WORK/00-总览.txt" 2>&1
echo " - 已生成 00-总览.txt"

# ---------- 3 温控配置与运行标记 ----------
step 3 "温控配置与运行标记"
_c=0; _skip=0
for f in "$CONFDIR"/* "$CONFDIR"/.*; do
    [ -f "$f" ] || continue
    b=${f##*/}
    case "$b" in .|..|stop_charge.log) continue ;; esac
    sz=$(wc -c < "$f" 2>/dev/null)
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    if [ "$sz" -gt 65536 ]; then _skip=$((_skip + 1)); continue; fi
    cp -f "$f" "$D_T/配置/$b" 2>/dev/null && _c=$((_c + 1))
done
for f in "$D_T"/配置/*.json "$D_T"/配置/*.txt; do scrub "$f"; done
echo " - 已采集配置与运行标记: $_c 个（含 charge_gov.state / power_plan.state / 各失败标记）"
[ "$_skip" -gt 0 ] && echo " - 超过 64KB 未采集: $_skip 个"
:

# ---------- 4 当前温控目录 ----------
step 4 "当前生效的温控目录"
if [ -n "$TP" ] && [ -d "$TP" ]; then
    cp -a "$TP/." "$D_T/thermal/" 2>/dev/null
    (
        cd "$TP" 2>/dev/null || exit 0
        for f in *; do
            [ -f "$f" ] || continue
            echo "--- $f（$(wc -c < "$f" 2>/dev/null)B sha256=$(sha256sum "$f" 2>/dev/null | cut -c1-16)）---"
            if LC_ALL=C grep -q '[^[:print:][:space:]]' "$f" 2>/dev/null; then
                echo "    [二进制/加密内容，不展开；完整文件见 thermal/$f]"
            else
                head -c 500 "$f" 2>/dev/null | sed 's/^/    /'
            fi
        done
    ) > "$D_T/thermal/节点数值.txt" 2>/dev/null
    echo " - $TP（$(ls -A "$D_T/thermal" 2>/dev/null | wc -l) 项）"
else
    echo " - 温控目录未探测到，跳过"
    FAIL=$((FAIL + 1))
fi

# ---------- 5 温控日志与关键事件 ----------
step 5 "温控日志与关键事件"
tail -n 2000 "$MODDIR/log/core.log" > "$D_T/core.log" 2>/dev/null
[ -s "$MODDIR/log/service.log" ] && cp -f "$MODDIR/log/service.log" "$D_T/service.log" 2>/dev/null
grep -aE '切换 →|温控联动|充电计划|检测到停充|自愈|错误|异常|selfcheck|模块被禁用|模块开关已关闭|启动' \
    "$MODDIR/log/core.log" 2>/dev/null | tail -n 500 > "$D_T/关键事件.log" 2>/dev/null
scrub "$D_T/关键事件.log"
echo " - core.log $(wc -l < "$D_T/core.log" 2>/dev/null) 行 / 关键事件 $(wc -l < "$D_T/关键事件.log" 2>/dev/null) 行"

# ---------- 6 解容：配置 / 状态 / 文本诊断 / 日志 ----------
step 6 "解容现场（配置 / 状态 / 文本诊断 / 日志）"
cp -f "$XBT/config/settings.conf" "$D_B/" 2>/dev/null
_s=0
for f in "$XBT/state"/*; do
    [ -f "$f" ] || continue
    b=${f##*/}
    case "$b" in
        apl.csv) tail -n 200 "$f" > "$D_B/state/apl.tail.csv" 2>/dev/null ;;
        *.log)   tail -n 500 "$f" > "$D_B/state/$b" 2>/dev/null ;;
        *)       cp -f "$f" "$D_B/state/$b" 2>/dev/null ;;
    esac
    _s=$((_s + 1))
done
if [ -f "$XBT/scripts/diag.sh" ]; then
    sh "$XBT/scripts/diag.sh" > "$D_B/diag.txt" 2>&1
    echo " - 解容文本诊断: $(wc -l < "$D_B/diag.txt" 2>/dev/null) 行"
else
    echo " - 未找到 battery/scripts/diag.sh"
    FAIL=$((FAIL + 1))
fi
if [ -s /data/local/tmp/xt_toolbox.log ]; then
    tail -n 2000 /data/local/tmp/xt_toolbox.log > "$D_B/日志.log" 2>/dev/null
else
    echo "解容日志不存在（模块可能刚启动）" > "$D_B/日志.log"
fi
echo " - 解容配置 + 状态 $_s 项 + 日志"

# ---------- 7 节点现场 ----------
step 7 "充电与电池节点"
{
    echo "== battery =="
    for n in status capacity health temp voltage_now current_now current_avg \
             charge_full charge_full_design charge_counter cycle_count \
             constant_charge_voltage constant_charge_current constant_charge_current_max; do
        [ -f "/sys/class/power_supply/battery/$n" ] && echo "$n=$(nread "/sys/class/power_supply/battery/$n")"
    done
    echo
    echo "== usb =="
    for n in online type real_type voltage_now voltage_max current_now current_max input_current_limit; do
        [ -f "/sys/class/power_supply/usb/$n" ] && echo "$n=$(nread "/sys/class/power_supply/usb/$n")"
    done
    echo
    echo "== main / wireless =="
    for n in online status current_now voltage_now; do
        for d in main wireless; do
            [ -f "/sys/class/power_supply/$d/$n" ] && echo "$d/$n=$(nread "/sys/class/power_supply/$d/$n")"
        done
    done
} > "$D_N/电池.txt" 2>/dev/null

{
    echo "== charger_thermal（模块直接控制的节点）=="
    for n in wired_chg_curr wired_chg_curr2 wired_ctrl_limit wired_thermal_remove \
             wireless_chg_curr wireless_ctrl_limit wireless_mag_ctrl_limit wireless_thermal_remove; do
        f="/sys/class/xm_power/charger/charger_thermal/$n"
        if [ -f "$f" ]; then
            if [ -w "$f" ]; then w=yes; else w=no; fi
            echo "$n=$(nread "$f")  [writable=$w]"
        else
            echo "$n=<不存在>"
        fi
    done
    echo
    echo "== charger_common =="
    for n in real_type quick_charge_type power_max handle_state stop_handle_charge; do
        f="/sys/class/xm_power/charger/charger_common/$n"
        [ -f "$f" ] && echo "$n=$(nread "$f")"
    done
    echo
    echo "== charge_interface（谁在限流）=="
    for n in charge_enable ichg_limit iin_limit power_limit input_suspend suspend_status; do
        f="/sys/class/xm_power/charger/charge_interface/$n"
        if [ -f "$f" ]; then
            echo "--- $n ---"
            timeout 1 cat "$f" 2>/dev/null | sed 's/^/    /'
        fi
    done
    echo
    echo "== quick_charge / chargerpump / cp_master =="
    for p in "charger/quick_charge:charging_stage cp_path_enable current_limit mode_enable power_max quick_charge_type" \
             "charger/chargerpump:cp_mode ibus_delta ibus_total" \
             "cp_master:vbus ibus vpack tdie batt_temp chip_ok batt_present"; do
        d=${p%%:*}; ns=${p#*:}
        for n in $ns; do
            f="/sys/class/xm_power/$d/$n"
            [ -f "$f" ] && echo "$d/$n=$(nread "$f")"
        done
    done
} > "$D_N/充电.txt" 2>/dev/null

{
    echo "== 无线充电 DT 参数（大端 4 字节）=="
    for n in adp_temp_max die_temp_max max_vbat min_vbat; do
        f="/proc/device-tree/soc/mca_strategy_quick_wireless_class/$n"
        if [ -f "$f" ]; then
            echo "$n=0x$(od -An -tx1 "$f" 2>/dev/null | tr -d '[:space:]')"
        else
            echo "$n=<不存在>"
        fi
    done
    echo
    echo "== 无线节点 =="
    for f in /sys/class/power_supply/wireless/online /sys/class/power_supply/wireless/current_now \
             /sys/class/power_supply/wireless/voltage_now /sys/class/xm_power/wireless_master/wls_die_temp \
             /sys/class/xm_power/wireless_master/rx_iout /sys/class/xm_power/wireless_master/rx_vout; do
        [ -f "$f" ] && echo "$f=$(nread "$f")"
    done
    echo
    echo "== 高温停充相关属性 =="
    getprop 2>/dev/null | grep -iE 'high_temp|stop_charge|wireless|wls'
} > "$D_N/无线.txt" 2>/dev/null

{
    echo "== BAA 载荷 =="
    _found=0
    for f in /odm/etc/charger/BAA_config_*.json; do
        [ -f "$f" ] || continue
        _found=1
        echo "$f"
        echo "  大小=$(stat -c '%s' "$f" 2>/dev/null)B  sha256=$(sha256sum "$f" 2>/dev/null | cut -c1-16)"
        case "$(head -c 8 "$f" 2>/dev/null)" in
            BAA_ENC:*) echo "  格式=BAA_ENC 加密载荷（无明文 JSON 字段可摘要，属正常）" ;;
            *) grep -oE '"(vterm|max_vbat|min_vbat|ffc_[a-z_]*)"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null | head -n 12 | sed 's/^/  /' ;;
        esac
    done
    [ "$_found" = "0" ] && echo "（/odm/etc/charger/ 下无 BAA_config_*.json）"
    echo
    echo "== BAA 挂载 =="
    echo "mount 含 BAA_config 的行数: $(mount 2>/dev/null | grep -c BAA_config)"
} > "$D_N/BAA.txt" 2>/dev/null

{
    echo "== DT 有线快充 / JEITA（大端 4 字节原始值）=="
    for d in /proc/device-tree/soc/mca_strategy_quick_charge \
             /proc/device-tree/soc/mca_buckchg_jeita; do
        if [ -d "$d" ]; then
            echo "[$d]"
            for f in "$d"/*; do
                [ -f "$f" ] || continue
                echo "  ${f##*/}=$(od -An -tx1 "$f" 2>/dev/null | tr -d '[:space:]')"
            done
        else
            echo "[$d] <不存在>"
        fi
    done
} > "$D_N/DT快充.txt" 2>/dev/null
echo " - 电池 / 充电 / 无线 / BAA / DT 五份节点文件"

# ---------- 8 系统现场 ----------
step 8 "系统与模块文件"
{
    echo "== 机型信息 =="
    for k in ro.product.brand ro.product.manufacturer ro.product.model ro.product.marketname \
             ro.product.device ro.board.platform ro.soc.model ro.build.version.release \
             ro.build.version.sdk ro.mi.os.version.name ro.miui.ui.version.name \
             ro.build.display.id ro.build.tags ro.boot.verifiedbootstate ro.boot.flash.locked; do
        echo "$k=$(getprop "$k")"
    done
    echo "kernel=$(uname -r)"
    echo "ABI=$(getprop ro.product.cpu.abi)"
    echo "SELinux=$(getenforce 2>/dev/null)"
    echo "指纹(前32位)=$(getprop ro.build.fingerprint | cut -c1-32)"
} > "$D_S/机型信息.txt" 2>/dev/null

{
    echo "== 模块目录 =="
    ls -l "$MODDIR" 2>/dev/null
    echo
    echo "== 关键文件校验（确认跑的是哪个版本、是否被改动）=="
    for f in thermal_core.sh diagnose.sh service.sh action.sh uninstall.sh customize.sh post-fs-data.sh config_backup.sh; do
        [ -f "$MODDIR/$f" ] && md5sum "$MODDIR/$f" 2>/dev/null
    done
    for f in "$XBT/scripts"/*.sh; do
        [ -f "$f" ] && md5sum "$f" 2>/dev/null
    done
    echo
    echo "== 模块目录外备份（升级恢复用）=="
    if [ -d /data/adb/HyperOS_XJ_data ]; then
        ls -lR /data/adb/HyperOS_XJ_data 2>/dev/null | head -n 120
    else
        echo "（无 /data/adb/HyperOS_XJ_data）"
    fi
} > "$D_S/模块文件.txt" 2>/dev/null

{
    echo "== 模块相关进程 =="
    ps -A 2>/dev/null | grep -E 'thermal|mi_thermald|HyperOS|xj|battery' | grep -v grep
    echo
    echo "== 各守护实例数（>1 会互相抢节点）=="
    for p in '[c]harge_guard\.sh' '[c]loud_guard\.sh' '[t]hermal_guard\.sh' \
             '[c]ycle_guard\.sh' '[f]v_guard\.sh' '[g]uard_watchdog\.sh' '[a]pl\.sh'; do
        echo "  ${p} = $(timeout 5 pgrep -cf "$p" 2>/dev/null)"
    done
    echo
    echo "== 负载 TOP10 =="
    top -b -n 1 -m 10 2>/dev/null
} > "$D_S/进程.txt" 2>/dev/null

dmesg 2>/dev/null | tail -n 400 > "$D_S/dmesg.txt" 2>/dev/null
{
    echo "== 充电 / 温控相关（已剔除 binder / wifi 等噪音）=="
    dmesg 2>/dev/null \
        | grep -aiE 'mca_|charger|chg_|thermal|high_temp|over.?temp|OVP|OCP|abnormal|vbus|vbat|battery' \
        | grep -aivE 'binder|peach_v2|wpa_su|_MLME|display|schedu' | tail -n 150
    echo
    echo "== 充电事件时间线 =="
    dmesg 2>/dev/null | grep -aiE 'charger|chg_|usb.*(insert|remove|connect)|vbus' | tail -n 60
} > "$D_S/dmesg关键.txt" 2>/dev/null

logcat -d -t 3000 2>/dev/null | grep -iE 'thermal|mi_thermald|hyperos|xj|charg|batt' | tail -n 400 > "$D_S/logcat.txt" 2>/dev/null
[ -s "$D_S/logcat.txt" ] || echo "（logcat 无匹配，或读取受限）" > "$D_S/logcat.txt"

for f in "$D_S/机型信息.txt" "$D_S/logcat.txt" "$D_S/dmesg.txt" "$D_S/dmesg关键.txt" "$D_S/模块文件.txt"; do scrub "$f"; done
echo " - 机型信息 / 模块文件 / 进程 / dmesg / logcat"

# ---------- 9 停充现场 + README + 打包 ----------
step 9 "停充现场与打包"
if [ -s "$CONFDIR/stop_charge.log" ]; then
    tail -n 400 "$CONFDIR/stop_charge.log" > "$WORK/50-停充.txt" 2>/dev/null
    scrub "$WORK/50-停充.txt"
    echo " - stop_charge.log $(wc -l < "$WORK/50-停充.txt" 2>/dev/null) 行"
else
    echo "（无停充记录）" > "$WORK/50-停充.txt"
fi

{
    echo "HyperOS - 动态温控·解容  诊断包"
    echo "采集时间 : $(date '+%F %T')   模块版本: $(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | sed 's/^version=//')"
    echo "自检退出码: $SC   （非 0 时优先看 10-温控/自检.txt）"
    echo
    echo "先看这三个："
    echo "  1) 00-总览.txt ......... 一页看清设备 / 模块 / 温控档位与联动判定 / 解容状态"
    echo "  2) 10-温控/关键事件.log .. 模块做过什么（切档 / 降功率 / 停充 / 自愈 / 报错）"
    echo "  3) 20-解容/diag.txt ..... 解容侧完整文本诊断（充电链路逐层定位）"
    echo
    echo "全部内容："
    echo "  00-总览.txt            设备与模块总览、温控链路自检、解容 status_kv 全量"
    echo "  10-温控/自检.txt         thermal_core.sh selfcheck 输出"
    echo "  10-温控/关键事件.log     从 core.log 抽出的状态变化与报错"
    echo "  10-温控/core.log         温控核心日志（尾部 2000 行）"
    echo "  10-温控/service.log      模块启动日志"
    echo "  10-温控/配置/            settings.json、current_mode 及全部运行标记"
    echo "                          （charge_gov.state=原档+当前档、power_plan.state、bypass_active、.heal、.lock_fail 等）"
    echo "  10-温控/thermal/         当前生效的温控配置整份 + 节点数值.txt"
    echo "  20-解容/settings.conf    解容配置（功率档 / 满电电压 / PPS / 循环 / APL）"
    echo "  20-解容/diag.txt         解容侧文本诊断（包含充电链路线、契约现场、波形现场）"
    echo "  20-解容/state/           解容运行状态（含 apl.tail.csv）"
    echo "  20-解容/日志.log         解容模块日志（尾部 2000 行）"
    echo "  30-节点/电池.txt         电池与 USB / 无线节点实时值"
    echo "  30-节点/充电.txt         charger_thermal / charge_interface / 充电泵节点"
    echo "  30-节点/无线.txt         无线充电节点与 DT 参数、高温停充属性"
    echo "  30-节点/BAA.txt          BAA 载荷大小 / 摘要 / 挂载状态"
    echo "  30-节点/DT快充.txt       设备树有线快充与 JEITA 参数（hex）"
    echo "  40-系统/机型信息.txt     机型 / 系统 / 内核 / Root 方案"
    echo "  40-系统/模块文件.txt     模块目录清单、关键脚本校验值、模块外备份清单"
    echo "  40-系统/进程.txt         模块进程、各守护实例数、负载"
    echo "  40-系统/dmesg*.txt       内核日志（含充电/温控错误与事件时间线）"
    echo "  40-系统/logcat.txt       logcat 中与模块相关的内容"
    echo "  50-停充.txt              每次停充的现场记录"
    echo
    echo "排查提示："
    echo "  · 充电不降功率：看 00-总览「温控链路自检」，再看 10-温控/关键事件.log 有无「温控联动」"
    echo "  · 功率上不去：看 20-解容/diag.txt 的「充电链路线」，逐层看到底断在适配器/PD/泵/解容总闸"
    echo "  · 交付：整个 tar.gz 直接发即可；已按白名单脱敏（序列号 / IMEI / MAC / 手机号）"
} > "$WORK/README.txt" 2>/dev/null

_OK=0
if command -v tar >/dev/null 2>&1; then
    tar -czf "$OUT" -C "$(dirname "$WORK")" "$(basename "$WORK")" 2>/dev/null && _OK=1
fi
if [ "$_OK" = "1" ]; then
    SIZE=$(ls -l "$OUT" 2>/dev/null | awk '{print $5}')
    rm -rf "$WORK" 2>/dev/null
    FINAL="$OUT"
else
    DEST="${OUT%.tar.gz}"
    rm -rf "$DEST" 2>/dev/null
    if mv "$WORK" "$DEST" 2>/dev/null; then
        FINAL="$DEST/"
    else
        FINAL="$WORK/"
    fi
fi

hr
echo " - 自检/采集异常项: $FAIL"
echo " - 已保存: $FINAL"
echo " - 可把该文件直接发给开发者"
echo "PATH=$FINAL"
hr
echo " - 如需强制还原原厂温控配置："
echo "   sh $MODDIR/thermal_core.sh $MODDIR restore"
hr
exit 0
