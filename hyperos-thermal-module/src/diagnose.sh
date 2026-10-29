#!/system/bin/sh

MODDIR=${0%/*}
CONFDIR="$MODDIR/config"
OUTDIR=/sdcard/Download

TS=$(date +%Y%m%d_%H%M%S)
WORK=/data/local/tmp/xj_diag_$TS
OUT="$OUTDIR/HyperOS_XJ_diag_$TS.tar.gz"

frame_mid() { echo "------------------------------------------"; }
step() { frame_mid; echo " [$1/8] $2"; }

sanitize() {
    sed -E \
        -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/**:**:**:**:**:**/g' \
        -e 's/(1[3-9][0-9])[0-9]{4}([0-9]{4})/\1****\2/g' \
        -e 's/(sn|serial|Serial|imei|IMEI|meid|MEID)([=: ]+)([0-9A-Za-z]{4})[0-9A-Za-z]{4,}/\1\2\3****/g'
}

frame_mid
echo " - HyperOS · 动态温控  K2"
echo " - 诊断与日志打包（2026-10-24）"
frame_mid

if [ ! -x "$MODDIR/thermal_core.sh" ]; then
    chmod 0755 "$MODDIR/thermal_core.sh" 2>/dev/null
fi

step 1 "模块自检"
"$MODDIR/thermal_core.sh" "$MODDIR" selfcheck
SC=$?
echo " - 自检退出码: $SC"

step 2 "现场快照"
echo " - 机型: $(getprop ro.product.model) / $(getprop ro.product.marketname)"
echo " - 平台: $(getprop ro.board.platform)"
echo " - 系统: $(getprop ro.mi.os.version.incremental)$(getprop ro.miui.ui.version.name)"
echo " - 内核: $(uname -r)"
echo " - 核心进程: $(cat "$CONFDIR/core.pid" 2>/dev/null || echo 无)"
TP=$(cat "$CONFDIR/rt_thermal_path" 2>/dev/null)
echo " - 温控目录: ${TP:-未探测}"
[ -n "$TP" ] && echo " - 目录文件数: $(ls -A "$TP" 2>/dev/null | wc -l)"
echo " - 当前档位: $(cat "$CONFDIR/current_mode" 2>/dev/null)"
echo " - 三倍速属性: support=$(getprop debug.game.video.support) speed=$(getprop debug.game.video.speed)"
echo " - 模块描述: $(grep '^description=' "$MODDIR/module.prop" 2>/dev/null | sed 's/^description=//')"
echo " - 日志文件: $MODDIR/log/core.log"

mkdir -p "$WORK/log" "$WORK/thermal" "$WORK/config" 2>/dev/null
if [ ! -d "$WORK" ]; then
    frame_mid
    echo " !! 无法创建临时目录 $WORK"
    echo " !! 请确认已获取 root 权限后重试"
    frame_mid
    exit 1
fi

{
    echo "time=$(date '+%F %T')"
    echo "model=$(getprop ro.product.model)"
    echo "platform=$(getprop ro.board.platform)"
    echo "build=$(getprop ro.build.display.id)"
    echo "kernel=$(uname -r)"
    echo "selfcheck_exit=$SC"
    echo "mode=$(cat "$CONFDIR/current_mode" 2>/dev/null)"
    echo "hyperos4_support=$(getprop debug.game.video.support)"
    echo "hyperos4_speed=$(getprop debug.game.video.speed)"
} > "$WORK/summary.txt" 2>/dev/null

step 3 "采集配置文件（白名单）"
for _f in settings.json current_mode rt_thermal_path mtk_fix status.json runtime.json; do
    [ -f "$CONFDIR/$_f" ] && cp -f "$CONFDIR/$_f" "$WORK/config/" 2>/dev/null
done
for _j in "$WORK/config"/*.json; do
    [ -f "$_j" ] || continue
    sanitize < "$_j" > "$_j.tmp" 2>/dev/null && mv -f "$_j.tmp" "$_j" 2>/dev/null
done
echo " - 已采集: $(ls -A "$WORK/config" 2>/dev/null | wc -l) 个配置项"
_ex=""
for _p in "$CONFDIR"/* "$CONFDIR"/.*; do
    [ -f "$_p" ] || continue
    _b=${_p##*/}
    [ "$_b" = . ] && continue
    [ "$_b" = .. ] && continue
    [ -f "$WORK/config/$_b" ] && continue
    _ex="$_ex$_b "
done
[ -n "$_ex" ] && echo " - 未采集: $_ex" || echo " - 未采集: 无"

step 4 "采集温控节点"
if [ -n "$TP" ] && [ -d "$TP" ]; then
    cp -a "$TP" "$WORK/thermal/current" 2>/dev/null
    echo " - 温控目录: $TP（$(ls -A "$WORK/thermal/current" 2>/dev/null | wc -l) 个文件）"
    (
        cd "$TP" 2>/dev/null
        for f in *; do
            [ -f "$f" ] && echo "$f=$(cat "$f" 2>/dev/null | head -c 200)"
        done
    ) > "$WORK/thermal/节点数值.txt" 2>/dev/null
else
    echo " - 温控目录未探测到，跳过"
fi

step 5 "采集日志（每个文件保留尾部 300 行）"
_n=0
for _lf in "$MODDIR"/log/*.log "$MODDIR"/*.log "$CONFDIR"/log/*.log; do
    [ -f "$_lf" ] || continue
    _base=$(basename "$_lf")
    [ -f "$WORK/log/$_base" ] && _base="more_$_base"
    tail -n 300 "$_lf" 2>/dev/null > "$WORK/log/$_base"
    _n=$((_n+1))
done
echo " - 已采集日志: $_n 个"
[ "$_n" -eq 0 ] && echo "本次运行时没有产生日志（模块可能刚启动或未运行）" > "$WORK/log/README.txt"

step 6 "采集运行状态"
{
    echo "=== 模块相关进程 ==="
    ps -A 2>/dev/null | grep -E 'thermal|mi_thermald|HyperOS|xj' | grep -v grep
    echo
    echo "=== 负载 TOP10 ==="
    top -b -n 1 -m 10 2>/dev/null
} > "$WORK/进程状态.txt" 2>/dev/null

{
    echo "=== 电量节点 ==="
    for n in temp current_now capacity status voltage_now \
             constant_charge_current_max constant_charge_current \
             charge_counter health; do
        [ -f "/sys/class/power_supply/battery/$n" ] && \
            echo "$n=$(cat "/sys/class/power_supply/battery/$n" 2>/dev/null)"
    done
    echo
    echo "=== 充电节点（旁路相关）==="
    for p in /sys/class/xm_power/charger/charger_thermal/wired_chg_curr \
             /sys/class/power_supply/usb/current_max; do
        [ -f "$p" ] && echo "$p=$(cat "$p" 2>/dev/null)" || echo "$p=不存在"
    done
} > "$WORK/battery.txt" 2>/dev/null

dmesg 2>/dev/null | tail -n 200 | sanitize > "$WORK/dmesg_tail.txt" 2>/dev/null
logcat -d -t 400 2>/dev/null | grep -iE 'thermal|mi_thermald|hyperos|xj' \
    | tail -n 200 | sanitize > "$WORK/logcat_tail.txt" 2>/dev/null

ls -l "$MODDIR" > "$WORK/module_files.txt" 2>/dev/null
[ -f "$MODDIR/thermal_core.sh" ] && md5sum "$MODDIR/thermal_core.sh" >> "$WORK/module_files.txt" 2>/dev/null
cp -f "$MODDIR/module.prop" "$WORK/" 2>/dev/null

{
    echo "模块名称=$(grep '^name=' "$MODDIR/module.prop" 2>/dev/null | sed 's/^name=//')"
    echo "模块版本=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | sed 's/^version=//')"
    echo "版本号=$(grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | sed 's/^versionCode=//')"
    echo "采集时间=$(date '+%F %T')"
    echo "品牌=$(getprop ro.product.brand)"
    echo "厂商=$(getprop ro.product.manufacturer)"
    echo "机型=$(getprop ro.product.model)"
    echo "市场名=$(getprop ro.product.marketname)"
    echo "设备代号=$(getprop ro.product.device)"
    echo "平台=$(getprop ro.board.platform)"
    echo "芯片=$(getprop ro.soc.model)"
    echo "安卓版本=$(getprop ro.build.version.release)"
    echo "SDK=$(getprop ro.build.version.sdk)"
    echo "系统版本=$(getprop ro.mi.os.version.name)$(getprop ro.miui.ui.version.name)"
    echo "构建号=$(getprop ro.build.display.id)"
    echo "内核=$(uname -r)"
    echo "ABI=$(getprop ro.product.cpu.abi)"
    echo "SELinux=$(getenforce 2>/dev/null)"
    echo "Root方案=$([ -d /data/adb/ksu ] && echo KernelSU || ([ -d /data/adb/ap ] && echo APatch || echo Magisk))"
    echo "安装模式=$([ -f "$CONFDIR/mtk_fix" ] && echo 天玑修复版 || echo 标准版)"
    echo "刷机时间=$(date -r "$MODDIR/module.prop" '+%F %T' 2>/dev/null)"
    echo "指纹(前32位)=$(getprop ro.build.fingerprint | cut -c1-32)"
} > "$WORK/机型信息.txt" 2>/dev/null

for f in "$WORK/summary.txt" "$WORK/机型信息.txt" "$WORK/module_files.txt"; do
    [ -f "$f" ] && sanitize < "$f" > "$f.s" 2>/dev/null && mv -f "$f.s" "$f" 2>/dev/null
done

step 7 "打包为 .tar.gz"
echo " - 说明：本机无 zip 命令，使用 tar.gz（WinRAR / 7-Zip / 系统自带解压均可直接打开）"
_OK=0
if command -v tar >/dev/null 2>&1; then
    if tar -czf "$OUT" -C "$(dirname "$WORK")" "$(basename "$WORK")" 2>/dev/null; then
        _OK=1
    fi
fi

if [ "$_OK" -eq 1 ]; then
    SIZE=$(ls -l "$OUT" 2>/dev/null | awk '{print $5}')
    echo " - 打包成功（$SIZE 字节）"
    rm -rf "$WORK" 2>/dev/null
    FINAL="$OUT"
else
    DEST="${OUT%.tar.gz}"
    rm -rf "$DEST" 2>/dev/null
    if mv "$WORK" "$DEST" 2>/dev/null; then
        echo " - 打包失败，已保留为目录: $DEST"
        FINAL="$DEST/"
    else
        echo " - 打包失败，临时目录保留在: $WORK"
        FINAL="$WORK/"
    fi
fi

step 8 "完成"
echo " - 已保存: $FINAL"
echo " - 可发给开发者排查"
frame_mid
echo " - 如需强制还原原厂配置："
echo "  sh $MODDIR/thermal_core.sh $MODDIR restore"
frame_mid
exit 0
