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

APK="$MODPATH/HyperOSxj.apk"

frame_mid
[ -s "$APK" ] || abort " [X] 缺少统一控制端 HyperOSxj.apk，请重新下载完整模块包"
_APK_RESULT=$(pm install -r "$APK" 2>&1)
_APK_RC=$?
if [ "$_APK_RC" != "0" ] || ! printf '%s\n' "$_APK_RESULT" | grep -q '^Success'; then
    print " [X] 统一控制端覆盖安装失败：$_APK_RESULT"
    abort " [X] 已中止安装并保留原 App 数据。请检查签名或版本冲突，勿卸载旧 App 后重试。"
fi
print " [OK] 已安装统一控制端 com.hyperos.xj，保留原 App 数据"

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
    # 解容子模块的用户配置（功率档/满电电压/强制覆盖/关机电压/免费 PPS/云控/循环伪装）
    # 都存在 battery/config/settings.conf，不迁移的话每次更新都会回到默认值
    # 【v1.0.42】旧逻辑“目标非空就跳过”导致新包自带的非空默认值把迁移彻底挡死：
    #   只要包里有 settings.conf，旧目录里的用户设置永远不会被采用。
    #   改为：目标仍是包内默认值时，允许旧用户值覆盖。
    _pack_def_hash=""
    if [ -s "$MODPATH/battery/config/settings.conf" ]; then
        _pack_def_hash=$(sha256sum "$MODPATH/battery/config/settings.conf" 2>/dev/null | awk '{print $1}')
    fi
    for _d in battery/config battery/state; do
        [ -d "$LEGACY_DIR/$_d" ] || continue
        mkdir -p "$MODPATH/$_d" 2>/dev/null
        for _f in "$LEGACY_DIR/$_d"/*; do
            [ -f "$_f" ] || continue
            _bn=$(basename "$_f")
            if [ -s "$MODPATH/$_d/$_bn" ]; then
                # 只有“目标仍等于包内默认值”才用旧值覆盖；已改过的目标保持不动
                _same_default=0
                if [ "$_d" = "battery/config" ] && [ "$_bn" = "settings.conf" ] && [ -n "$_pack_def_hash" ]; then
                    _cur_h=$(sha256sum "$MODPATH/$_d/$_bn" 2>/dev/null | awk '{print $1}')
                    [ "$_cur_h" = "$_pack_def_hash" ] && _same_default=1
                fi
                [ "$_same_default" = "1" ] || continue
            fi
            cp -f "$_f" "$MODPATH/$_d/$_bn" 2>/dev/null && MIGRATED=$((MIGRATED+1))
        done
    done
    if [ -d "$LEGACY_DIR/profiles" ]; then
        mkdir -p "$MODPATH/profiles" 2>/dev/null
        for _p in "$LEGACY_DIR"/profiles/*.conf; do
            [ -f "$_p" ] || continue
            _pn=$(basename "$_p")
                [ -s "$MODPATH/profiles/$_pn" ] || { cp -f "$_p" "$MODPATH/profiles/$_pn" 2>/dev/null && MIGRATED=$((MIGRATED+1)); }
        done
    fi
    if [ "$MIGRATED" -gt 0 ]; then
        frame_mid
        print " - 已迁移旧版用户数据($_LEGACY_ID):${MIGRATED} 项"
    fi
fi
# 模块目录外备份恢复：管理器原地更新会替换整个模块目录（含 config/ 与 battery/config/），
# 旧目录可能已不存在，光靠 LEGACY_DIR 迁移会丢设置。thermal_core 运行时会把用户设置
# 备份到 /data/adb/HyperOS_XJ_data，升级时优先从这里恢复。
XJ_DATA=/data/adb/HyperOS_XJ_data
if [ -d "$XJ_DATA" ]; then
    _REST=0
    if [ ! -s "$CONFDIR/settings.json" ] || ! head -c 1 "$CONFDIR/settings.json" 2>/dev/null | grep -q '{'; then
        if [ -s "$XJ_DATA/config/settings.json" ]; then
            mkdir -p "$CONFDIR" 2>/dev/null
            cp -f "$XJ_DATA/config/settings.json" "$CONFDIR/settings.json" 2>/dev/null && _REST=$((_REST+1))
        fi
    fi
    for _f in bypass_manual rearscreen.json; do
        if [ ! -s "$CONFDIR/$_f" ] && [ -s "$XJ_DATA/config/$_f" ]; then
            cp -f "$XJ_DATA/config/$_f" "$CONFDIR/$_f" 2>/dev/null && _REST=$((_REST+1))
        fi
    done
    # 解容配置（功率档/满电电压/PPS/云控/循环伪装/APL 等）用户改过的值全在这里，整体覆盖默认
    if [ -s "$XJ_DATA/battery/config/settings.conf" ]; then
        mkdir -p "$MODPATH/battery/config" 2>/dev/null
        cp -f "$XJ_DATA/battery/config/settings.conf" "$MODPATH/battery/config/settings.conf" 2>/dev/null && _REST=$((_REST+1))
    fi
    for _p in "$XJ_DATA"/profiles/*.conf; do
        [ -f "$_p" ] || continue
        _pn=$(basename "$_p")
        mkdir -p "$MODPATH/profiles" 2>/dev/null
        cp -f "$_p" "$MODPATH/profiles/$_pn" 2>/dev/null
    done
    if [ "$_REST" -gt 0 ]; then
        frame_mid
        print " - 已从备份恢复用户设置:${_REST} 项"
    fi
fi
if [ ! -s "$CONFDIR/rearscreen.json" ]; then
    cp -f "$MODPATH/default_rearscreen.json" "$CONFDIR/rearscreen.json" || abort "无法初始化背屏设置"
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

if [ -s "$MODPATH/webroot/index.html" ]; then
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
    _dev=$(getprop ro.product.device 2>/dev/null)
    _vd=$(getprop ro.product.vendor.device 2>/dev/null)
    _nm=$(getprop ro.product.name 2>/dev/null)
    _code=""
    for _c in xuanyuan dada haotian nezha myron annibale bixi onyx popsicle miro songyuan warsaw pudding pandora byron; do
        if [ "$_dev" = "$_c" ] || [ "$_vd" = "$_c" ] || [ "$_nm" = "$_c" ]; then _code=$_c; break; fi
    done
    # 按机型部署 BAA 载荷（与解容脚本的 dev_code 对应），未识别的机型沿用包内默认
    if [ -d "$BATDIR/baa/pool" ]; then
        if [ -n "$_code" ] && [ -d "$BATDIR/baa/pool/$_code" ]; then
            mkdir -p "$BATDIR/baa/modes" 2>/dev/null
            for _f in normal.json normal_nocloud.json normal_plain.json normal_nocloud_plain.json; do
                [ -f "$BATDIR/baa/pool/$_code/$_f" ] && cp -f "$BATDIR/baa/pool/$_code/$_f" "$BATDIR/baa/modes/" 2>/dev/null
            done
            cp -f "$BATDIR/baa/pool/$_code/payload_BAA_config_$_code.json" "$BATDIR/baa/" 2>/dev/null
            cp -f "$BATDIR/baa/pool/$_code/stock_BAA_config_$_code.json" "$BATDIR/baa/" 2>/dev/null
            for _oc in xuanyuan dada haotian nezha myron annibale bixi onyx popsicle miro songyuan warsaw pudding pandora byron; do
                [ "$_oc" = "$_code" ] && continue
                rm -f "$BATDIR/baa/payload_BAA_config_$_oc.json" "$BATDIR/baa/stock_BAA_config_$_oc.json" 2>/dev/null
            done
            print " - BAA：已部署 $_code 机型载荷"
        else
            print " - BAA：未找到 $_dev 机型载荷，沿用默认"
        fi
        rm -rf "$BATDIR/baa/pool" 2>/dev/null
    fi
    mkdir -p "$BATDIR/state" 2>/dev/null
    chmod 0755 "$BATDIR/bin/freepps" 2>/dev/null
    for _s in "$BATDIR"/scripts/*.sh "$BATDIR"/post-fs-data.sh "$BATDIR"/service.sh "$BATDIR"/uninstall.sh; do
        [ -f "$_s" ] && chmod 0755 "$_s" 2>/dev/null
    done
    # 恢复电池健康度显示：解容默认会禁用 PSS 导致「电池健康度」不显示，
    # 这里在刷入时启用一次并重启 batteryantiaging（只做这一步，不动解容本身）。
    pm enable com.miui.securitycenter >/dev/null 2>&1
    pm enable "com.miui.securitycenter/com.miui.powercenter.provider.PowerSaveService" >/dev/null 2>&1
    setprop ctl.restart batteryantiaging >/dev/null 2>&1
    print " - 已启用 PSS 并重启 batteryantiaging（恢复健康度显示）"

    # ===== 功能开关选择（只在全新安装时问；升级沿用用户原设置） =====
    _old_conf=/data/adb/modules/HyperOS_XJ/battery/config/settings.conf
    _can_ask=1
    command -v getevent >/dev/null 2>&1 || _can_ask=0

    conf_set_install() {
        _f="$BATDIR/config/settings.conf"; _k="$1"; _v="$2"
        [ -f "$_f" ] || return 1
        if grep -q "^${_k}=" "$_f" 2>/dev/null; then
            sed -i "s|^${_k}=.*|${_k}=${_v}|" "$_f" 2>/dev/null
        else
            printf '%s=%s\n' "$_k" "$_v" >> "$_f" 2>/dev/null
        fi
    }

    conf_set_install dev_code "${_code:-unsupported}"
    if [ -n "$_code" ] && [ -f "$BATDIR/dtbo/$_code.img" ]; then
        if cp -f "$BATDIR/dtbo/$_code.img" "$BATDIR/dtbo/local.img" 2>/dev/null; then
            print " - DTBO：已识别并准备本机镜像 $_code.img"
        else
            print " - DTBO：本机镜像 $_code.img 已内置，可在控制台手动刷入"
        fi
    elif [ -z "$_code" ]; then
        print " - DTBO：上游未提供本机镜像，不使用其它机型镜像"
    else
        print " - DTBO：本机镜像 $_code.img 资源缺失"
    fi

    _bc="$BATDIR/config/settings.conf"
    # 快照中的档位是旧守护触发前的选择；当前已被手动改档时不覆盖。
    _tg_action=$(grep -a '^thermal_action=' "$_bc" 2>/dev/null | tail -n1 | cut -d= -f2-)
    _tg_tier=$(grep -a '^tier=' "$BATDIR/state/thermal_prev" 2>/dev/null | head -n1 | cut -d= -f2-)
    _tg_current=$(grep -a '^power_limit=' "$_bc" 2>/dev/null | tail -n1 | cut -d= -f2-)
    case "$_tg_action" in slow|stop) _tg_expected=slow ;; mid|fast) _tg_expected=$_tg_action ;; *) _tg_expected="" ;; esac
    if [ -n "$_tg_expected" ] && [ "$_tg_current" = "$_tg_expected" ]; then
        case "$_tg_tier" in inf|fast|mid|slow) conf_set_install power_limit "$_tg_tier" ;; esac
    fi
    if [ "$_tg_action" = "stop" ]; then
        _tg_sw=$(grep -a '^slow_w=' "$BATDIR/state/thermal_prev" 2>/dev/null | head -n1 | cut -d= -f2-)
        [ -n "$_tg_sw" ] || _tg_sw=$(cat "$BATDIR/state/thermal_slow_w_prev" 2>/dev/null)
        case "$_tg_sw" in ''|*[!0-9]*|0) _tg_sw=10 ;; esac
        if [ "$(grep -a '^slow_w=' "$_bc" 2>/dev/null | tail -n1 | cut -d= -f2-)" = "2" ]; then
            conf_set_install slow_w "$_tg_sw"
        fi
    fi
    sed -i '/^thermal_guard=/d; /^thermal_limit=/d; /^thermal_hyst=/d; /^thermal_action=/d' "$_bc" 2>/dev/null
    rm -f "$BATDIR/state/thermal_prev" "$BATDIR/state/thermal_slow_w_prev" \
          "$BATDIR/state/thermal_restore_active" "$BATDIR/state/thermal_reapply" \
          "$BATDIR/state/wd_tg_last_restart" /data/local/tmp/xt_thermal_guard.pid 2>/dev/null
    ask_install_switch() {
        _label="$1"; _key="$2"; _def="$3"
        if [ "$_def" = "1" ]; then _cs=开; else _cs=关; fi
        print "   - ${_label}（默认：${_cs}）  音量+ = 开 / 音量- = 关"
        sleep 1
        _end=$(( $(date +%s) + 10 ))
        while [ "$(date +%s)" -lt "$_end" ]; do
            _ev=$(timeout 1 getevent -qlc 1 2>/dev/null)
            case "$_ev" in
                *KEY_VOLUMEUP*)   conf_set_install "$_key" 1; print "      -> 已设为开"; sleep 1; return 0 ;;
                *KEY_VOLUMEDOWN*) conf_set_install "$_key" 0; print "      -> 已设为关"; sleep 1; return 0 ;;
            esac
        done
        print "      -> 未按键，保持默认"
    }

    if [ -f "$_old_conf" ]; then
        print " - 功能开关：检测到旧版配置，沿用你原来的设置（不询问）"
    elif [ "$_can_ask" = "0" ]; then
        print " - 功能开关：本环境不支持音量键选择，使用默认值"
    else
        print " "
        print " - 功能开关设置（每项 10 秒，不按键则保持默认）"
        ask_install_switch "电池解容（防低电量锁容）"        unlock        1
        ask_install_switch "公版 PPS 解锁（第三方充电头提速）"  freepps       0
        ask_install_switch "云控屏蔽（防止云端改回参数）"        cloud_guard   1
        ask_install_switch "自适应功率爬坡（APL）"              apl_enable    0
        print " - 功能开关设置完成"
    fi

    # 【v1.0.47】安装时让用户自己选：在这个界面刷，还是跳过、稍后在控制台刷。
    #   用音量键选（安装界面无法输入文字）；15 秒不按 = 默认跳过，宁可不刷也不卡住安装。
    #   高级用户想安装时直接刷，可在包里放 dtbo/auto_install 标记文件。
    _dbg="$BATDIR/scripts/install_dtbo.sh"
    _dtbo_want=0
    if [ ! -f "$_dbg" ]; then
        print " - DTBO：包里没有刷写脚本，跳过"
    elif [ -f "$BATDIR/dtbo/auto_install" ]; then
        _dtbo_want=1
        print " - DTBO：检测到 auto_install 标记，直接刷入"
    else
        print " "
        print " - DTBO 刷写选择（10 秒内用音量键选）"
        print "     音量 +  ：现在刷入（重启后生效）"
        print "     音量 -  ：跳过，稍后在控制台「电池 -> DTBO」自己刷"
        print "     不按键  ：超时后默认跳过"
        _dtbo_end=$(( $(date +%s) + 10 ))
        sleep 1
        if ! command -v getevent >/dev/null 2>&1; then
            print "     -> 本环境不支持音量键选择，已跳过（请在控制台刷）"
        else
            while [ "$(date +%s)" -lt "$_dtbo_end" ]; do
                _ev=$(timeout 1 getevent -qlc 1 2>/dev/null)
                case "$_ev" in
                    *KEY_VOLUMEUP*)   _dtbo_want=1; print "     -> 已选择：现在刷入"; break ;;
                    *KEY_VOLUMEDOWN*) print "     -> 已选择：跳过，稍后可在控制台刷"; break ;;
                esac
            done
            if [ "$_dtbo_want" != "1" ] && [ "${_ev#*KEY_VOLUME}" = "$_ev" ]; then
                print "     -> 未按键/超时，已跳过（随时可在控制台刷）"
            fi
        fi
    fi
    if [ "$_dtbo_want" = "1" ] && [ -f "$_dbg" ]; then
        _dout=/data/local/tmp/xj_dtbo_install.out
        XBT="$BATDIR" sh "$_dbg" > "$_dout" 2>&1
        _drc=$?
        if [ -s "$_dout" ]; then
            while IFS= read -r _l; do print "   $_l"; done < "$_dout"
        fi
        rm -f "$_dout" 2>/dev/null
        if [ "$_drc" = "0" ]; then
            print "   DTBO 已写入，重启后生效"
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
    elif [ "$_dtbo_want" != "1" ] && [ -f "$_dbg" ]; then
        :   # 已在上方提示过跳过原因
    fi
    mkdir -p "$XJ_DATA/battery/config" 2>/dev/null
    cp -f "$BATDIR/config/settings.conf" "$XJ_DATA/battery/config/settings.conf" 2>/dev/null
fi

rm -rf "$MODPATH/config/log" 2>/dev/null
set_perm_recursive "$MODPATH" 0 0 0755 0644 2>/dev/null
set_perm "$MODPATH/thermal_core.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/service.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/action.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/uninstall.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/customize.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/module.prop" 0 0 0644 2>/dev/null
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755 2>/dev/null
set_perm "$MODPATH/battery/bin/freepps" 0 0 0755 2>/dev/null
for _s in "$MODPATH"/battery/scripts/*.sh "$MODPATH"/battery/post-fs-data.sh "$MODPATH"/battery/service.sh "$MODPATH"/battery/uninstall.sh; do
    [ -f "$_s" ] && set_perm "$_s" 0 0 0755 2>/dev/null
done
set_perm "$MODPATH/default_settings.json" 0 0 0644 2>/dev/null
set_perm "$MODPATH/default_settings.mtk.json" 0 0 0644 2>/dev/null
find "$MODPATH" -type f -name '*.sh' -exec chmod 0755 {} \; 2>/dev/null
