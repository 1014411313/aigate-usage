#!/system/bin/sh

SKIPUNZIP=0
MODDIR=${MODPATH:-/data/adb/modules/HyperOS_XJ}

print() { ui_print "$@"; }

frame_mid() { print "------------------------------------------"; }

[ -z "$MODPATH" ] && MODPATH="$MODDIR"
[ -z "$TMPDIR" ] && TMPDIR=/dev/tmp

clear

frame_mid
print " - HyperOS - 动态温控·解容 ｜ 电池解容 / PPS / DTBO"
frame_mid
print " - 二改声明：本包为二改整合版本，非原作者官方发布"
print " - 动态温控作者：Axiaojiux"
print " - 电池解容工具箱作者：听夜风1337"
print " - 二改整合维护：小米热炸了"
frame_mid
print " - 过去不翻旧账 未来不空许诺"

PLATFORM=$(getprop ro.board.platform 2>/dev/null)
[ -z "$PLATFORM" ] && PLATFORM=$(getprop ro.hardware 2>/dev/null)
IS_MTK=0
case "$PLATFORM" in
mt*|MT*) IS_MTK=1 ;;
esac

read_volkey() {
    _o=""
    if command -v timeout >/dev/null 2>&1; then
        _o=$(timeout 15 getevent -lc 400 2>/dev/null | grep -m1 -E 'KEY_VOLUMEUP|KEY_VOLUMEDOWN')
        [ -z "$_o" ] && _o=$(timeout 15 getevent -l 2>/dev/null | grep -m1 -E 'KEY_VOLUMEUP|KEY_VOLUMEDOWN')
    else
        _o=$(getevent -lc 400 2>/dev/null | grep -m1 -E 'KEY_VOLUMEUP|KEY_VOLUMEDOWN')
        [ -z "$_o" ] && _o=$(getevent -l 2>/dev/null | grep -m1 -E 'KEY_VOLUMEUP|KEY_VOLUMEDOWN')
    fi
    case "$_o" in
        *KEY_VOLUMEUP*)   printf 'up' ;;
        *KEY_VOLUMEDOWN*) printf 'down' ;;
        *)                printf 'none' ;;
    esac
}

frame_mid
print " - 安装模式"
frame_mid
print " - [1] 默认配置：完整功能"
print " - [2] 天玑修复版：移除部分功能"
frame_mid
print " - 音量上键 (+) → [1]   音量下键 (-) → [2]"
frame_mid

if [ "$IS_MTK" = "1" ]; then
    print " - 平台：$PLATFORM（联发科）"
    print " - 建议选择 [2]"
    frame_mid
    print " - 15 秒无操作，默认选择 [2]"
else
    print " - 平台：${PLATFORM:-未知}"
    frame_mid
    print " - 15 秒无操作，默认选择 [1]"
fi

frame_mid

if [ "$IS_MTK" = "1" ]; then INSTALL_MODE=2; else INSTALL_MODE=1; fi
VK=$(read_volkey)
case "$VK" in
    up)   INSTALL_MODE=1 ;;
    down) INSTALL_MODE=2 ;;
    *)    : ;;
esac

if [ "$VK" = "none" ] && [ -f "$MODPATH/config/mtk_fix" ]; then
    INSTALL_MODE=2
fi

if [ "$INSTALL_MODE" = "2" ]; then
    print " - 已选择：[2] 天玑设备专用修复版"
else
    print " - 已选择：[1] 默认配置"
fi

frame_mid

if [ -f "$MODPATH/config/core.pid" ]; then
    OLD_PID=$(cat "$MODPATH/config/core.pid" 2>/dev/null)
    case "$OLD_PID" in
        ''|*[!0-9]*) ;;
        *) kill "$OLD_PID" 2>/dev/null && print " - 已停止旧核心进程 ($OLD_PID)" ;;
    esac
fi
pkill -f 'thermal_core.sh' 2>/dev/null
OLD_MOD=/data/adb/modules/HyperOS_XJ
if [ -f "$OLD_MOD/thermal_core.sh" ] && [ "$OLD_MOD" != "$MODPATH" ]; then
    pkill -f "$OLD_MOD" 2>/dev/null
    print " - 检测到旧版模块目录，已终止其进程"
fi

chmod 0755 "$MODPATH/thermal_core.sh" "$MODPATH/service.sh" \
           "$MODPATH/action.sh" "$MODPATH/uninstall.sh" "$MODPATH/customize.sh" 2>/dev/null
chmod 0755 "$MODPATH/HyperOS/HyperOS-yes" "$MODPATH/HyperOS/HyperOS-off" 2>/dev/null

THERMAL_PATH=""
for c in /data/vendor/thermal/config /data/vendor/thermal/thermal-config /data/vendor/thermal; do
    if [ -d "$c" ]; then THERMAL_PATH="$c"; break; fi
done

BK_MOD="$MODPATH/backup/thermal-config"
BK_MIR="/data/adb/HyperOS_XJ_backup/thermal-config"

frame_mid

bk_ok() {
    [ -f "$1/.done" ] || return 1
    [ -n "$(ls -A "$1" 2>/dev/null | grep -v '^\.done$')" ] || return 1
    return 0
}

if [ -n "$THERMAL_PATH" ]; then
    N=$(ls -A "$THERMAL_PATH" 2>/dev/null | wc -l)
    print " - 温控配置目录：$THERMAL_PATH （$N 个文件）"
    if bk_ok "$BK_MOD" || bk_ok "$BK_MIR"; then
        if bk_ok "$BK_MIR" && ! bk_ok "$BK_MOD"; then
            mkdir -p "$BK_MOD" 2>/dev/null
            cp -a "$BK_MIR/." "$BK_MOD/" 2>/dev/null
        elif bk_ok "$BK_MOD" && ! bk_ok "$BK_MIR"; then
            mkdir -p "$BK_MIR" 2>/dev/null
            cp -a "$BK_MOD/." "$BK_MIR/" 2>/dev/null
        fi
        print " - 检测到已有原厂温控备份，跳过备份"
    elif [ "${N:-0}" -gt 0 ]; then
        mkdir -p "$BK_MOD" "$BK_MIR" 2>/dev/null
        cp -a "$THERMAL_PATH/." "$BK_MOD/" 2>/dev/null
        cp -a "$THERMAL_PATH/." "$BK_MIR/" 2>/dev/null
        date '+%F %T' > "$BK_MOD/.done" 2>/dev/null
        cp -f "$BK_MOD/.done" "$BK_MIR/.done" 2>/dev/null
        print " [OK] 已备份原厂温控配置"
    else
        print " [!] 温控目录为空 跳过备份"
    fi
else
    print " [!] 未找到温控配置目录 开机后由守护进程自动探测"
fi

if [ "$INSTALL_MODE" = "2" ]; then
    if [ -s "$MODPATH/default_settings.mtk.json" ]; then
        [ -s "$MODPATH/default_settings.full.json" ] || \
            cp -f "$MODPATH/default_settings.json" "$MODPATH/default_settings.full.json" 2>/dev/null
        cp -f "$MODPATH/default_settings.mtk.json" "$MODPATH/default_settings.json" 2>/dev/null
    fi
    rm -f "$MODPATH/thermal_core.mtk.sh" 2>/dev/null
    frame_mid
    print " [OK] 已启用天玑修复模式"
    print " -    已关闭充电电流与旁路供电调节"
else
    if [ -s "$MODPATH/default_settings.full.json" ]; then
        cp -f "$MODPATH/default_settings.full.json" "$MODPATH/default_settings.json" 2>/dev/null
        rm -f "$MODPATH/default_settings.full.json" 2>/dev/null
    fi
    rm -f "$MODPATH/thermal_core.mtk.sh" 2>/dev/null
fi

APK="$MODPATH/HyperOSxj.apk"

install_apk() {
    pm install -r -d "$1" >/dev/null 2>&1 && return 0
    pm install -r --user 0 "$1" >/dev/null 2>&1 && return 0
    pm install -r "$1" >/dev/null 2>&1 && return 0
    # 本版 APK 重新签过名，与旧版签名不同 → 覆盖安装会报签名冲突，
    # 卸载旧版后再装（控制台无本地数据，卸载不损失配置）。
    print " - 检测到签名变更，先卸载旧版控制台…"
    pm uninstall --user 0 com.hyperos.xj >/dev/null 2>&1
    pm uninstall com.hyperos.xj >/dev/null 2>&1
    pm install -r "$1" >/dev/null 2>&1 && return 0
    pm install "$1" >/dev/null 2>&1 && return 0
    return 1
}
if [ -f "$APK" ]; then
    frame_mid
    print " - 正在安装控制台…"
    _w=0
    while [ "$_w" -lt 5 ] && ! command -v pm >/dev/null 2>&1; do sleep 1; _w=$((_w + 1)); done
    if command -v pm >/dev/null 2>&1 && install_apk "$APK"; then
        frame_mid
        print " - 已安装控制台 APP"
    else
        frame_mid
        print " [!] 自动安装失败，重启后请手动安装：$APK"
    fi
else
    frame_mid
    print " [!] 未找到 HyperOSxj.apk，跳过自动安装"
fi

CONFDIR="$MODPATH/config"
mkdir -p "$CONFDIR" 2>/dev/null

if [ "$INSTALL_MODE" = "2" ]; then
    printf '1' > "$CONFDIR/mtk_fix"
else
    rm -f "$CONFDIR/mtk_fix" 2>/dev/null
fi

rm -f "$CONFDIR/status.json" "$CONFDIR/runtime.json" "$CONFDIR/core.pid" \
      "$CONFDIR/.dir_ok" "$CONFDIR/.heal" "$CONFDIR/.lock_fail" "$CONFDIR/.maps" \
      "$CONFDIR/.fg_pkg" "$CONFDIR/.fg_time" "$CONFDIR/.fps_applied" \
      "$CONFDIR/.last_restart" "$CONFDIR/.daemon_down" "$CONFDIR/bypass_active" \
      "$CONFDIR/bypass_allow" "$CONFDIR/bypass_trigger" 2>/dev/null
rm -f "$CONFDIR"/rt_* 2>/dev/null
rm -f "$MODPATH/thermal_list" "$MODPATH/切换log.log" "$MODPATH/log/"*.log 2>/dev/null
frame_mid
print " - 已清理运行态残留文件"

_LEGACY_ID="${MODID:-}"
if [ -z "$_LEGACY_ID" ] && [ -s "$MODPATH/module.prop" ]; then
    _LEGACY_ID=$(grep -m1 '^id=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r')
fi
LEGACY_DIR="/data/adb/modules/$_LEGACY_ID"
MIGRATED=0
if [ -n "$_LEGACY_ID" ] && [ "$LEGACY_DIR" != "$MODPATH" ] && [ -d "$LEGACY_DIR" ]; then
    _CUR_OK=0
    if [ -s "$CONFDIR/settings.json" ] && head -c 1 "$CONFDIR/settings.json" 2>/dev/null | grep -q '{'; then
        _CUR_OK=1
    fi
    if [ "$_CUR_OK" = "0" ]; then
        if [ -s "$LEGACY_DIR/config/settings.json" ] && head -c 1 "$LEGACY_DIR/config/settings.json" 2>/dev/null | grep -q '{'; then
            cp -f "$LEGACY_DIR/config/settings.json" "$CONFDIR/.settings.migrate" 2>/dev/null \
                && mv -f "$CONFDIR/.settings.migrate" "$CONFDIR/settings.json" 2>/dev/null \
                && MIGRATED=$((MIGRATED+1))
        fi
    fi
    for _f in current_mode bypass_current bypass_manual; do
        if [ ! -s "$CONFDIR/$_f" ] && [ -s "$LEGACY_DIR/config/$_f" ]; then
            cp -f "$LEGACY_DIR/config/$_f" "$CONFDIR/$_f" 2>/dev/null && MIGRATED=$((MIGRATED+1))
        fi
    done
    if [ -d "$LEGACY_DIR/profiles" ]; then
        mkdir -p "$MODPATH/profiles" 2>/dev/null
        for _p in "$LEGACY_DIR"/profiles/*.conf; do
            [ -f "$_p" ] || continue
            _pn=$(basename "$_p")
            [ "$_pn" = "default.conf" ] && continue
            [ -s "$MODPATH/profiles/$_pn" ] || { cp -f "$_p" "$MODPATH/profiles/$_pn" 2>/dev/null && MIGRATED=$((MIGRATED+1)); }
        done
    fi
    if [ "$MIGRATED" -gt 0 ]; then
        frame_mid
        print " - 已迁移旧版用户数据($_LEGACY_ID):${MIGRATED} 项"
    fi
fi
NEED_DEFAULT=0
if [ -s "$CONFDIR/settings.json" ]; then
    if head -c 1 "$CONFDIR/settings.json" 2>/dev/null | grep -q '{'; then
        frame_mid
        print " - 保留已有配置"
    else
        NEED_DEFAULT=1
    fi
else
    NEED_DEFAULT=1
fi

if [ "$NEED_DEFAULT" = "1" ]; then
    if [ -s "$MODPATH/default_settings.json" ]; then
        cp -f "$MODPATH/default_settings.json" "$CONFDIR/.settings.new" 2>/dev/null
        mv -f "$CONFDIR/.settings.new" "$CONFDIR/settings.json" 2>/dev/null
        frame_mid
        print " [OK] 已生成默认配置"
    else
    frame_mid
        print " [!] 缺少 default_settings.json 配置可能异常"
    fi
fi

if [ -s "$CONFDIR/settings.json" ]; then
    cp -f "$CONFDIR/settings.json" "$CONFDIR/settings.json.bak" 2>/dev/null
    frame_mid
    print " - 已备份用户配置到 config/settings.json.bak"
fi

if [ -s "$CONFDIR/settings.json" ]; then
    grep -q '"schema"' "$CONFDIR/settings.json" || print " [!] 旧版配置结构 运行时将自动兼容"
fi

if [ "$INSTALL_MODE" = "2" ]; then
    M=$(cat "$CONFDIR/current_mode" 2>/dev/null)
    [ "$M" = "bypass" ] && printf 'default' > "$CONFDIR/current_mode"
else
    [ -s "$CONFDIR/bypass_current" ] || printf '500000' > "$CONFDIR/bypass_current"
fi

[ -s "$CONFDIR/current_mode" ] || printf 'default' > "$CONFDIR/current_mode"
chmod -R 0771 "$CONFDIR" 2>/dev/null

frame_mid
print " - 模块刷入自检："
FAIL=0

for _f in t_blank t_bypass_0 t_bypass_1 t_map; do
    [ -f "$MODPATH/$_f" ] || {
        [ -f "$MODPATH/thermal/$_f" ] && cp -f "$MODPATH/thermal/$_f" "$MODPATH/$_f" 2>/dev/null
    }
done

check_md5() {
    local f="$1" want="$2" got
    got=$(md5sum "$MODPATH/$f" 2>/dev/null | cut -d' ' -f1)
    if [ "$got" != "$want" ] && [ -f "$MODPATH/thermal/$f" ]; then
        cp -f "$MODPATH/thermal/$f" "$MODPATH/$f" 2>/dev/null
        got=$(md5sum "$MODPATH/$f" 2>/dev/null | cut -d' ' -f1)
    fi
    if [ "$got" = "$want" ]; then
        print " [OK] $f"
    else
        print " [!] $f 校验失败"
        FAIL=$((FAIL + 1))
    fi
}
check_md5 t_blank    de59942d3dffc090f0dae74dfc4d47ce
check_md5 t_bypass_0 006bb13431c52592192e710e46e76879
check_md5 t_bypass_1 959b4f8711503653abea8a019936ab2c
check_md5 t_map      43b4b914ef6b45119bbfe2030e4025a7

for s in thermal_core.sh service.sh action.sh uninstall.sh; do
    if [ -f "$MODPATH/$s" ]; then
        if sh -n "$MODPATH/$s" 2>/dev/null; then :; else
            print " [!] $s 语法错误"
            FAIL=$((FAIL + 1))
        fi
    else
        print " [!] 缺少 $s"
        FAIL=$((FAIL + 1))
    fi
done

if [ -s "$MODPATH/hyperosui/index.html" ]; then
    print " [OK] WebUI"
else
    print " [X] WebUI 缺失"
    FAIL=$((FAIL + 1))
fi

if [ -n "$THERMAL_PATH" ] && [ -w "$THERMAL_PATH" ]; then
    print " [OK] 温控目录可写"
else
    print " [!] 温控目录当前不可写（开机后由核心修复）"
fi

DAEMON=""
for d in mi_thermald thermald thermal-engine; do
    if [ -f "/system/bin/$d" ] || [ -f "/vendor/bin/$d" ]; then DAEMON="$d"; break; fi
done
if [ -n "$DAEMON" ]; then print " [OK] 温控守护进程：$DAEMON"; else print " [!] 未找到已知温控守护进程（可能机型差异）"; fi

MODEL=$(getprop ro.product.model 2>/dev/null)
[ -f "$MODPATH/profiles/$MODEL.conf" ] && print " [OK] 机型档案：$MODEL.conf" || print " [OK] 机型档案：使用 default.conf"

frame_mid

if [ "$FAIL" -eq 0 ]; then
    print " - 安装完成 重启生效"
else
    print " - 自检发现 $FAIL 项问题，请查看上述输出"
fi

frame_mid

if [ "$INSTALL_MODE" = "2" ]; then
    print " - 当前模式：天玑设备专用修复版（无充电电流/旁路调节）"
else
    print " - 当前模式：默认配置"
fi

frame_mid

BATDIR="$MODPATH/battery"
if [ -d "$BATDIR" ]; then
    frame_mid
    print " - 电池解容 / PPS：初始化"
    mkdir -p "$BATDIR/state" 2>/dev/null
    chmod 0755 "$BATDIR/bin/freepps" 2>/dev/null
    for _s in "$BATDIR"/scripts/*.sh "$BATDIR"/post-fs-data.sh "$BATDIR"/service.sh "$BATDIR"/uninstall.sh; do
        [ -f "$_s" ] && chmod 0755 "$_s" 2>/dev/null
    done
    _dbg="$BATDIR/scripts/install_dtbo.sh"
    if [ -f "$_dbg" ]; then
        print " - DTBO：校验系统版本与分区后刷入"
        _dout=/data/local/tmp/xj_dtbo_install.out
        XBT="$BATDIR" sh "$_dbg" > "$_dout" 2>&1
        _drc=$?
        if [ -s "$_dout" ]; then
            while IFS= read -r _l; do print "   $_l"; done < "$_dout"
        fi
        rm -f "$_dout" 2>/dev/null
        if [ "$_drc" = "0" ]; then
            _code=$(grep -E '^dev_code=' "$BATDIR/config/settings.conf" 2>/dev/null | tail -1 | cut -d= -f2-)
            for _img in "$BATDIR/dtbo"/*.img; do
                [ -f "$_img" ] || continue
                case "$(basename "$_img")" in
                    local.img) ;;
                    "$_code.img") mv -f "$_img" "$BATDIR/dtbo/local.img" 2>/dev/null ;;
                    *) rm -f "$_img" 2>/dev/null ;;
                esac
            done
        fi
    fi
fi

rm -rf "$MODPATH/config/log" 2>/dev/null
set_perm_recursive "$MODPATH" 0 0 0755 0644 2>/dev/null
set_perm "$MODPATH/thermal_core.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/service.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/action.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/uninstall.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/customize.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/hyperosui/bin/applabel" 0 0 0755 2>/dev/null
set_perm "$MODPATH/module.prop" 0 0 0644 2>/dev/null
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/battery/bin/freepps" 0 0 0755 2>/dev/null
for _s in "$MODPATH"/battery/scripts/*.sh "$MODPATH"/battery/post-fs-data.sh "$MODPATH"/battery/service.sh "$MODPATH"/battery/uninstall.sh; do
    [ -f "$_s" ] && set_perm "$_s" 0 0 0755 2>/dev/null
done
set_perm "$MODPATH/default_settings.json" 0 0 0644 2>/dev/null
set_perm "$MODPATH/default_settings.mtk.json" 0 0 0644 2>/dev/null
