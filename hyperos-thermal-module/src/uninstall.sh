#!/system/bin/sh
MODDIR=${0%/*}
CONFDIR="$MODDIR/config"

say() { echo "$*"; }
log() { say "$*"; }

say "===== 开始卸载 HyperOS · 动态温控 ====="
say "模块目录：$MODDIR"
say " "

STOPPED=0
if [ -f "$CONFDIR/core.pid" ]; then
    P=$(cat "$CONFDIR/core.pid" 2>/dev/null)
    case "$P" in
        ''|*[!0-9]*) ;;
        *) kill "$P" 2>/dev/null && { say "- 已停止核心进程 pid=$P"; STOPPED=1; } ;;
    esac
fi
pkill -f 'thermal_core.sh' 2>/dev/null && STOPPED=1
pkill -f "$MODDIR/service.sh" 2>/dev/null && STOPPED=1
pkill -f "$MODDIR" 2>/dev/null
sleep 1
[ "$STOPPED" = "1" ] && say "- 温控核心进程与服务已全部停止" || say "- 未发现运行中的核心进程"
say " "

if grep -q '"hyperos4"[[:space:]]*:[[:space:]]*true' "$CONFDIR/settings.json" 2>/dev/null; then
    setprop debug.game.video.support false 2>/dev/null
    setprop debug.game.video.speed false 2>/dev/null
    say "[OK] 检测到场景页 HyperOS 游戏三倍速开关为开启状态，已关闭三倍速属性"
else
    say "- HyperOS 游戏三倍速开关未开启，跳过属性还原"
fi
say " "

THERMAL_PATH=""
if [ -s "$CONFDIR/rt_thermal_path" ]; then
    THERMAL_PATH=$(cat "$CONFDIR/rt_thermal_path" 2>/dev/null)
fi
if [ -z "$THERMAL_PATH" ] || [ ! -d "$THERMAL_PATH" ]; then
    for c in /data/vendor/thermal/config /data/vendor/thermal/thermal-config /data/vendor/thermal; do
        [ -d "$c" ] && { THERMAL_PATH="$c"; break; }
    done
fi

BK_MOD="$MODDIR/backup/thermal-config"
BK_MIR="/data/adb/HyperOS_XJ_backup/thermal-config"

BK=""
[ -f "$BK_MOD/.done" ] && BK="$BK_MOD"
[ -z "$BK" ] && [ -f "$BK_MIR/.done" ] && BK="$BK_MIR"

if [ -n "$THERMAL_PATH" ]; then
    say "- 温控目录：$THERMAL_PATH"
    chattr -R -i -a "$THERMAL_PATH" 2>/dev/null
    case "$THERMAL_PATH" in
        */config|*/thermal-config)
            rm -rf "$THERMAL_PATH"/* 2>/dev/null
            rm -f "$THERMAL_PATH"/.[!.]* 2>/dev/null
            ;;
        *)
            say "! 温控目录层级异常，跳过清理：$THERMAL_PATH"
            ;;
    esac
    if [ -n "$BK" ]; then
        cp -a "$BK/." "$THERMAL_PATH/" 2>/dev/null
        rm -f "$THERMAL_PATH/.done" 2>/dev/null
        chown -R root:system "$THERMAL_PATH" 2>/dev/null
        chcon -R u:object_r:thermal_data_file:s0 "$THERMAL_PATH" 2>/dev/null
        chmod -R 0771 "$THERMAL_PATH" 2>/dev/null
        say "[OK] 已还原原厂温控配置（来自 $BK，$(ls -A "$THERMAL_PATH" 2>/dev/null | wc -l) 个文件）"
    else
        chown -R root:system "$THERMAL_PATH" 2>/dev/null
        chcon -R u:object_r:thermal_data_file:s0 "$THERMAL_PATH" 2>/dev/null
        chmod -R 0771 "$THERMAL_PATH" 2>/dev/null
        say "[!] 无原厂备份，已清空覆盖文件，交由守护进程重建默认配置"
    fi
else
    say "[!] 未找到温控目录，跳过还原"
fi

DAEMON=""
for d in mi_thermald thermald thermal-engine; do
    if [ -f "/system/bin/$d" ] || [ -f "/vendor/bin/$d" ]; then DAEMON="$d"; break; fi
done
if [ -n "$DAEMON" ]; then
    stop "$DAEMON" 2>/dev/null
    sleep 1
    start "$DAEMON" 2>/dev/null
    say "[OK] 已重启温控守护进程：$DAEMON"
fi
say " "

ORIG=$(cat "$CONFDIR/rt_charge_orig" 2>/dev/null)
NODE=$(cat "$CONFDIR/rt_charge_node" 2>/dev/null)
if [ -z "$NODE" ]; then
    for n in /sys/class/power_supply/battery/constant_charge_current_max \
             /sys/class/power_supply/battery/constant_charge_current \
             /sys/class/power_supply/battery/current_max; do
        [ -f "$n" ] && { NODE="$n"; break; }
    done
fi
case "$ORIG" in
    ''|*[!0-9]*) say "- 无充电电流原值记录，跳过回写" ;;
    *)
        if [ -n "$NODE" ] && [ -f "$NODE" ]; then
            chmod 0644 "$NODE" 2>/dev/null
            if echo "$ORIG" > "$NODE" 2>/dev/null; then
                say "[OK] 已还原充电电流原值 $ORIG（$NODE）"
            else
                say "[!] 回写充电电流失败：$NODE"
            fi
        else
            say "[!] 找不到充电电流节点，跳过回写"
        fi
        ;;
esac
say " "

if pm list packages 2>/dev/null | grep -q 'com.hyperos.xj'; then
    if pm uninstall --user 0 com.hyperos.xj >/dev/null 2>&1; then
        say "[OK] 已卸载控制台 APK（com.hyperos.xj）"
    elif pm uninstall com.hyperos.xj >/dev/null 2>&1; then
        say "[OK] 已卸载控制台 APK（全局）"
    else
        say "[!] APK 卸载失败，请手动卸载 com.hyperos.xj"
    fi
else
    say "- 未安装 com.hyperos.xj，跳过"
fi
say " "

if [ -f "$MODDIR/battery/uninstall.sh" ]; then
    say " "
    say "===== 电池解容 / PPS 子模块清理 ====="
    sh "$MODDIR/battery/uninstall.sh" 2>&1
    say " "
fi
if [ -d /data/adb/modules/battery_tune ] && [ ! -f /data/adb/modules/battery_tune/module.prop ]; then
    rm -rf /data/adb/modules/battery_tune 2>/dev/null
fi

rm -rf /data/adb/HyperOS_XJ_backup 2>/dev/null && say "- 已清理镜像备份 /data/adb/HyperOS_XJ_backup"
rm -rf /data/local/tmp/xj_diag_* 2>/dev/null
rm -f /data/local/tmp/HyperOS_XJ_uninstall.log 2>/dev/null
rm -f /data/local/tmp/HyperOS_XJ_action.log 2>/dev/null
say "- 已清理临时日志与诊断包工作目录"

rm -rf "$CONFDIR/log" 2>/dev/null
rm -f "$MODDIR/thermal_list" "$MODDIR/切换log.log" 2>/dev/null
rm -rf /data/adb/modules_update/HyperOS_XJ 2>/dev/null
say "- 已清理运行态残留文件"

case "$MODDIR" in
    /data/adb/modules/*|/data/adb/modules_update/*)
        find "$MODDIR" -mindepth 1 -maxdepth 1 ! -name 'uninstall.sh' -exec rm -rf {} + 2>/dev/null
        ( sleep 2; rm -rf "$MODDIR" ) >/dev/null 2>&1 &
        say "[OK] 已清理模块目录：$MODDIR"
        ;;
    *)
        say "! 非标准模块目录，跳过目录清理：$MODDIR"
        ;;
esac

say " "
say "===== 卸载完成，重启后全部生效 ====="
exit 0
