#!/system/bin/sh
MODDIR="${1:-${0%/*}}"
CMD="${2:-}"

CONFDIR="$MODDIR/config"
LOGDIR="$MODDIR/log"
LOGFILE="$LOGDIR/core.log"
BACKUP_DIR="$MODDIR/backup/thermal-config"
BACKUP_MIRROR="/data/adb/HyperOS_XJ_backup/thermal-config"
PROFILE_FILE="$MODDIR/profiles/default.conf"
PKG_NAME="com.hyperos.xj"

LAST_RESTART=0
FORCE=0

BUILD_VER=$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2 | tr -d '\r')
[ -n "$BUILD_VER" ] || BUILD_VER="K2"

if [ -f "$CONFDIR/mtk_fix" ]; then MTK_MODE=1; else MTK_MODE=0; fi

BAT_TEMP=0
BAT_CUR=0
BAT_CAP=0
BAT_VOLT=0
BAT_STATUS="Unknown"
IS_CHARGING=0

mkdir -p "$CONFDIR" "$LOGDIR" 2>/dev/null

log() {
    if [ -f "$LOGFILE" ]; then
        local lc=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
        if [ "${lc:-0}" -gt 800 ]; then
            tail -n 400 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv -f "$LOGFILE.tmp" "$LOGFILE"
        fi
    fi
    echo "$(date '+%F %T') $*" >> "$LOGFILE" 2>/dev/null
}

json_val() {
    [ -s "$1" ] || return 0
    awk -v k="$2" '
        {
            if (match($0, "\"" k "\"[ \t]*:[ \t]*")) {
                v = substr($0, RSTART + RLENGTH)
                sub(/[ \t]*[,;]?[ \t]*$/, "", v)
                if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*$/, "", v) }
                else { sub(/[ \t].*/, "", v) }
                print v
                exit
            }
        }' "$1" 2>/dev/null
}

conf() {
    local v=$(json_val "$CONFDIR/settings.json" "$1")
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

profile_get() {
    [ -f "$PROFILE_FILE" ] || PROFILE_FILE="$MODDIR/profiles/default.conf"
    local v=""
    [ -f "$PROFILE_FILE" ] && v=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$PROFILE_FILE" 2>/dev/null | tail -1 | sed 's/^[^=]*=//; s/[[:space:]]*$//')
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

init_profile() {
    local model=$(getprop ro.product.model 2>/dev/null)
    PROFILE_FILE="$MODDIR/profiles/default.conf"
    for p in "$MODDIR/profiles/$model.conf" "$MODDIR/profiles/$(echo "$model" | tr ' ' '_').conf"; do
        if [ -f "$p" ]; then PROFILE_FILE="$p"; fi
    done
    POLL_INTERVAL=$(profile_get poll_interval 3)
    FG_INTERVAL=$(profile_get foreground_interval 10)
    BYPASS_DEFAULT=$(profile_get bypass_current 500000)
    COOLDOWN=$(profile_get restart_cooldown 6)
    ENABLE_GUARD=$(profile_get enable_guard 1)
    TEMP_GUARD=$(profile_get temp_guard 480)
    LOCK_CONF=$(profile_get lock_conf 1)
    case "$POLL_INTERVAL" in ''|*[!0-9]*) POLL_INTERVAL=3 ;; esac
    case "$FG_INTERVAL" in ''|*[!0-9]*) FG_INTERVAL=10 ;; esac
    case "$COOLDOWN" in ''|*[!0-9]*) COOLDOWN=6 ;; esac
    case "$TEMP_GUARD" in ''|*[!0-9]*) TEMP_GUARD=480 ;; esac
    [ "$FG_INTERVAL" -lt "$POLL_INTERVAL" ] && FG_INTERVAL="$POLL_INTERVAL"
}

valid_mode() {
    case "$1" in
        default|unlimited|level_1|level_2|level_3|level_4|level_5) return 0 ;;
    esac
    return 1
}

mode_label() {
    case "$1" in
        default)   echo "系统默认" ;;
        unlimited) echo "无限制" ;;
        level_1)   echo "一档" ;;
        level_2)   echo "二档" ;;
        level_3)   echo "三档" ;;
        level_4)   echo "四档" ;;
        level_5)   echo "五档" ;;
        bypass)    echo "旁路供电" ;;
        off)       echo "已关闭" ;;
        disabled)  echo "已禁用" ;;
        *)         [ -n "$1" ] && echo "$1" || echo "系统默认" ;;
    esac
}

uniform_mode() {
    local dm=$(conf default_mode default)
    valid_mode "$dm" || return 1
    [ "$dm" = "default" ] && return 1
    [ "$(conf charge_mode true)" = "true" ] || return 1
    [ "$(conf charge_level unlimited)" = "$dm" ] || return 1
    [ "$(conf time_level level_1)"  = "$dm" ] || return 1
    local sl=$(conf sleep_level "")
    [ -n "$sl" ] && [ "$sl" != "$dm" ] && return 1
    if [ "$(conf game_mode true)" = "true" ]; then
        [ "$(conf game_level unlimited)" = "$dm" ] || return 1
        case "$(conf game_fps 0)" in
            ''|0|null|false) ;;
            *) return 1 ;;
        esac
    fi
    printf '%s' "$dm"
    return 0
}

uniform_mode_cached() {
    local sig=$(stat -c '%Y:%s' "$CONFDIR/settings.json" 2>/dev/null)
    local last=""
    [ -n "$sig" ] && last=$(cat "$CONFDIR/.uni_sig" 2>/dev/null)
    if [ -z "$sig" ] || [ "$sig" != "$last" ]; then
        local m=$(uniform_mode)
        printf '%s' "$m" > "$CONFDIR/.uni_cache" 2>/dev/null
        [ -n "$sig" ] && printf '%s' "$sig" > "$CONFDIR/.uni_sig" 2>/dev/null
        printf '%s' "$m"
        return 0
    fi
    cat "$CONFDIR/.uni_cache" 2>/dev/null
}

src_for_mode() {
    case "$1" in
        unlimited) echo "$MODDIR/t_blank" ;;
        level_1|level_2|level_3|level_4|level_5) echo "$MODDIR/thermal/${1#level_}/thermal-scene.conf" ;;
        *) echo "" ;;
    esac
}

set_desc() {
    [ -w "$MODDIR/module.prop" ] || return 0
    local cur=$(grep '^description=' "$MODDIR/module.prop" 2>/dev/null | sed 's/^description=//')
    [ "$cur" = "$1" ] && return 0
    if sed -i "s#^description=.*#description=$1#" "$MODDIR/module.prop" 2>/dev/null; then
        return 0
    fi
    grep -v '^description=' "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null
    echo "description=$1" >> "$MODDIR/module.prop.tmp"
    mv -f "$MODDIR/module.prop.tmp" "$MODDIR/module.prop" 2>/dev/null
}

set_status_err() {
    set_desc "异常：$1"
    log "错误: $1"
}

update_status() {
    local label=$(mode_label "$1")
    local t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    case "$t" in ''|*[!0-9-]*) t="" ;; esac
    if [ -n "$t" ]; then
        [ "$t" -lt 0 ] && t=0
        set_desc "运行中 ｜ ${label} ｜ $((t / 10)).$((t % 10))℃"
    else
        set_desc "运行中 ｜ ${label} ｜ --.-℃"
    fi
}

detect_daemon() {
    local d
    for d in mi_thermald thermal-engine thermald thermal-manager; do
        if command -v "$d" >/dev/null 2>&1 \
           || [ -x "/system/bin/$d" ] || [ -x "/vendor/bin/$d" ] \
           || [ -x "/system/vendor/bin/$d" ] || [ -x "/system_ext/bin/$d" ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

daemon_running() {
    [ -n "$THERMAL_DAEMON" ] && pgrep -f "$THERMAL_DAEMON" >/dev/null 2>&1
}

detect_thermal_path() {
    local p
    for p in /data/vendor/thermal/config /data/thermal/config /data/vendor/thermal/thermal-config; do
        if [ -d "$p" ]; then echo "$p"; return 0; fi
    done
    if [ -d /data/vendor/thermal ] || [ ! -d /data/thermal ]; then
        echo "/data/vendor/thermal/config"
    else
        echo "/data/thermal/config"
    fi
}

detect_charge_node() {
    local n ov=$(profile_get charge_node "")
    if [ -n "$ov" ] && [ -f "$ov" ] && [ -w "$ov" ]; then echo "$ov"; return 0; fi
    for n in /sys/class/xm_power/charger/charger_thermal/wired_chg_curr \
             /sys/class/power_supply/battery/constant_charge_current_max \
             /sys/class/power_supply/battery/charge_control_limit \
             /sys/class/power_supply/battery/constant_charge_current \
             /sys/class/power_supply/battery/input_current_limit; do
        if [ -f "$n" ] && [ -w "$n" ]; then echo "$n"; return 0; fi
    done
    return 1
}

detect_voltage_node() {
    local n
    for n in /sys/class/power_supply/battery/voltage_now \
             /sys/class/power_supply/battery/voltage_ocv; do
        if [ -f "$n" ]; then echo "$n"; return 0; fi
    done
    return 1
}

probe() {
    THERMAL_DAEMON=$(detect_daemon)
    THERMAL_PATH=$(detect_thermal_path)
    CHARGE_NODE=$(detect_charge_node)
    VOLTAGE_NODE=$(detect_voltage_node)
    PLATFORM=$(getprop ro.board.platform 2>/dev/null)
    MODEL=$(getprop ro.product.model 2>/dev/null)
    MARKET_NAME=$(getprop ro.product.marketname 2>/dev/null)
    [ -z "$MARKET_NAME" ] && MARKET_NAME="$MODEL"
    OS_VER=$(getprop ro.mi.os.version.incremental 2>/dev/null | sed 's/OS//' | cut -d'.' -f1)
    [ -z "$OS_VER" ] && OS_VER=$(getprop ro.miui.ui.version.name 2>/dev/null)

    printf '%s' "$THERMAL_DAEMON" > "$CONFDIR/rt_thermal_daemon"
    printf '%s' "$THERMAL_PATH"   > "$CONFDIR/rt_thermal_path"
    printf '%s' "$CHARGE_NODE"    > "$CONFDIR/rt_charge_node"
    printf '%s' "$VOLTAGE_NODE"   > "$CONFDIR/rt_voltage_node"
    printf '%s' "$PLATFORM"       > "$CONFDIR/rt_platform"
    printf '%s' "$MODEL"          > "$CONFDIR/rt_model"

    printf '{"thermal_daemon":"%s","os_version":"%s","thermal_path":"%s","charge_node":"%s","voltage_node":"%s","platform":"%s","model":"%s","market_name":"%s","build":"%s"}\n' \
        "$THERMAL_DAEMON" "$OS_VER" "$THERMAL_PATH" "$CHARGE_NODE" "$VOLTAGE_NODE" \
        "$PLATFORM" "$MODEL" "$MARKET_NAME" "$BUILD_VER" > "$CONFDIR/runtime.json"

    log "探测: daemon=${THERMAL_DAEMON:-无} path=$THERMAL_PATH node=${CHARGE_NODE:-无} platform=$PLATFORM"
    [ -n "$THERMAL_DAEMON" ]
}

bootstrap() {
    THERMAL_DAEMON=$(cat "$CONFDIR/rt_thermal_daemon" 2>/dev/null)
    THERMAL_PATH=$(cat "$CONFDIR/rt_thermal_path" 2>/dev/null)
    CHARGE_NODE=$(cat "$CONFDIR/rt_charge_node" 2>/dev/null)
    if [ -z "$THERMAL_DAEMON" ] || [ -z "$THERMAL_PATH" ] || [ ! -d "$THERMAL_PATH" ]; then
        probe || return 1
    fi
    [ -n "$CHARGE_NODE" ] || CHARGE_NODE=$(detect_charge_node)
    return 0
}

ensure_thermal_dir() {
    if [ -f "$CONFDIR/.dir_ok" ] && [ -d "$THERMAL_PATH" ] \
       && [ "$(cat "$CONFDIR/.dir_ok" 2>/dev/null)" = "$THERMAL_PATH" ]; then
        return 0
    fi
    local parent=$(dirname "$THERMAL_PATH")
    chattr -R -i -a "$parent" 2>/dev/null
    if [ ! -d "$THERMAL_PATH" ]; then
        rm -f "$THERMAL_PATH" 2>/dev/null
        if [ ! -d "$parent" ]; then
            chattr -i -a "$(dirname "$parent")" 2>/dev/null
            rm -f "$parent" 2>/dev/null
            mkdir -p "$parent" 2>/dev/null
        fi
        mkdir -p "$THERMAL_PATH" 2>/dev/null
    fi
    chown -R root:system "$parent" 2>/dev/null
    chcon -R u:object_r:thermal_data_file:s0 "$parent" 2>/dev/null
    chmod -R 0771 "$parent" 2>/dev/null
    printf '%s' "$THERMAL_PATH" > "$CONFDIR/.dir_ok"
}

backup_ready() {
    [ -f "$BACKUP_DIR/.done" ] || [ -f "$BACKUP_MIRROR/.done" ]
}

backup_source() {
    if [ -f "$BACKUP_DIR/.done" ]; then echo "$BACKUP_DIR"; else echo "$BACKUP_MIRROR"; fi
}

factory_backup() {
    [ -n "$THERMAL_PATH" ] || bootstrap
    if backup_ready; then
        if [ -f "$BACKUP_DIR/.done" ] && [ ! -f "$BACKUP_MIRROR/.done" ]; then
            mkdir -p "$BACKUP_MIRROR" 2>/dev/null
            cp -a "$BACKUP_DIR/." "$BACKUP_MIRROR/" 2>/dev/null
        fi
        return 0
    fi
    [ -d "$THERMAL_PATH" ] || { log "原厂备份: 配置目录不存在，稍后重试"; return 1; }
    local n=$(ls -A "$THERMAL_PATH" 2>/dev/null | wc -l)
    if [ "${n:-0}" -eq 0 ]; then
        log "原厂备份: 目录为空（可能被其它模块清理过），跳过"
        return 1
    fi
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    cp -a "$THERMAL_PATH/." "$BACKUP_DIR/" 2>/dev/null
    echo "$(date '+%F %T') from=$THERMAL_PATH files=$n" > "$BACKUP_DIR/.done"
    mkdir -p "$BACKUP_MIRROR" 2>/dev/null
    cp -a "$BACKUP_DIR/." "$BACKUP_MIRROR/" 2>/dev/null
    log "原厂备份完成: ${n} 个文件 → $BACKUP_DIR"
    return 0
}

restore_factory() {
    local bk=$(backup_source)
    unlock_files
    chattr -R -i -a "$THERMAL_PATH" 2>/dev/null
    case "$THERMAL_PATH" in
        */config|*/thermal-config) ;;
        *) set_status_err "温控目录异常，拒绝清空"; return 1 ;;
    esac
    rm -rf "$THERMAL_PATH"/* 2>/dev/null
    rm -f "$THERMAL_PATH"/.[!.]* 2>/dev/null
    if [ -f "$bk/.done" ]; then
        cp -a "$bk/." "$THERMAL_PATH/" 2>/dev/null
        rm -f "$THERMAL_PATH/.done" 2>/dev/null
        log "已还原原厂温控配置 ($(ls -A "$THERMAL_PATH" 2>/dev/null | wc -l) 个文件)"
    else
        log "无原厂备份，交由守护进程重新生成默认配置"
    fi
    chown -R root:system "$THERMAL_PATH" 2>/dev/null
    chcon -R u:object_r:thermal_data_file:s0 "$THERMAL_PATH" 2>/dev/null
    chmod -R 0771 "$THERMAL_PATH" 2>/dev/null
    return 0
}

charge_node_now() {
    local ov=$(profile_get charge_node "")
    if [ -n "$ov" ] && [ -f "$ov" ] && [ -w "$ov" ]; then echo "$ov"; return 0; fi
    local n=$(cat "$CONFDIR/rt_charge_node" 2>/dev/null)
    if [ -n "$n" ] && [ -f "$n" ] && [ -w "$n" ]; then echo "$n"; return 0; fi
    detect_charge_node
}

save_charge_orig() {
    [ "$MTK_MODE" = "1" ] && return 0
    if [ -s "$CONFDIR/rt_charge_orig" ]; then return 0; fi
    local node=$(charge_node_now)
    [ -n "$node" ] || return 1
    local v=$(cat "$node" 2>/dev/null)
    case "$v" in
        ''|*[!0-9]*|0) log "充电电流原值不可用(node=$node v=$v)，将不做回写"; return 1 ;;
    esac
    printf '%s' "$v" > "$CONFDIR/rt_charge_orig"
    printf '%s' "$node" > "$CONFDIR/rt_charge_node"
    log "记录充电电流原值 = $v ($node)"
    return 0
}

set_charge_current() {
    [ "$MTK_MODE" = "1" ] && return 0
    local target="$1" node cur
    case "$target" in ''|*[!0-9]*) return 1 ;; esac
    for node in $(cat "$CONFDIR/rt_charge_node" 2>/dev/null) $(charge_node_now); do
        [ -n "$node" ] || continue
        [ -f "$node" ] && [ -w "$node" ] || continue
        cur=$(cat "$node" 2>/dev/null)
        [ "$cur" = "$target" ] && continue
        chmod 0644 "$node" 2>/dev/null
        if ! echo "$target" > "$node" 2>/dev/null; then
            log "写入充电电流失败: $node=$target"
        fi
    done
    return 0
}

bypass_current() {
    local v=$(conf bypass_current "")
    case "$v" in ''|*[!0-9]*) v="$BYPASS_DEFAULT" ;; esac
    case "$v" in ''|*[!0-9]*) v=500000 ;; esac
    local orig=$(cat "$CONFDIR/rt_charge_orig" 2>/dev/null)
    case "$orig" in
        ''|*[!0-9]*) ;;
        *) [ "$v" -gt "$orig" ] && v="$orig" ;;
    esac
    [ "$v" -lt 500000 ] && v=500000
    echo "$v"
}

scan_thermal_dir() {
    local d
    for d in /system/vendor/etc /vendor/etc /odm/etc /system_ext/etc /system/etc; do
        [ -d "$d" ] && echo "$d"
    done
}

refresh_thermal_list() {
    local d f
    : > "$MODDIR/thermal_list" 2>/dev/null
    for d in $(scan_thermal_dir); do
        for f in "$d"/thermal*.conf; do
            [ -f "$f" ] && basename "$f"
        done
    done | sort -u > "$MODDIR/thermal_list" 2>/dev/null
    [ -s "$MODDIR/thermal_list" ] || return 1
    return 0
}

write_map_files() {
    [ -s "$MODDIR/thermal_list" ] || refresh_thermal_list
    grep -i 'thermal-' "$MODDIR/thermal_list" 2>/dev/null | grep -i '\-map' | grep -iv '\-region\-map' > "$CONFDIR/.maps" 2>/dev/null
    local i d n=0
    while read -r i; do
        [ -n "$i" ] || continue
        for d in $(scan_thermal_dir); do
            if [ -f "$d/$i" ]; then
                cp -f "$MODDIR/t_map" "$THERMAL_PATH/$i" 2>/dev/null && n=$((n + 1))
                break
            fi
        done
    done < "$CONFDIR/.maps"
    echo "$n"
}

lock_files() {
    [ "$LOCK_CONF" = "1" ] || return 0
    [ -f "$CONFDIR/.lock_fail" ] && return 0
    local f
    chattr +i "$THERMAL_PATH/thermal-normal.conf" 2>/dev/null
    while read -r f; do
        [ -n "$f" ] && [ -f "$THERMAL_PATH/$f" ] && chattr +i "$THERMAL_PATH/$f" 2>/dev/null
    done < "$CONFDIR/.maps"
    return 0
}

unlock_files() {
    chattr -R -i -a "$THERMAL_PATH" 2>/dev/null
    return 0
}

restart_daemon() {
    local now=$(date +%s)
    if [ "$FORCE" != "1" ] && [ "${LAST_RESTART:-0}" -gt 0 ] && [ $((now - LAST_RESTART)) -lt "$COOLDOWN" ]; then
        log "重启节流: 距上次 $((now - LAST_RESTART))s < ${COOLDOWN}s"
        return 0
    fi
    LAST_RESTART=$now
    echo "$now" > "$CONFDIR/.last_restart"
    unlock_files
    stop "$THERMAL_DAEMON" 2>/dev/null
    sleep 1
    start "$THERMAL_DAEMON" 2>/dev/null
    sleep 1
    if ! daemon_running; then
        if command -v restart >/dev/null 2>&1; then
            restart "$THERMAL_DAEMON" 2>/dev/null
            sleep 1
        fi
    fi
    if daemon_running; then
        rm -f "$CONFDIR/.daemon_down" 2>/dev/null
    else
        echo 1 > "$CONFDIR/.daemon_down"
        log "警告: $THERMAL_DAEMON 重启后未运行（部分机型首次开机需更久）"
    fi
    local t=$(cat "$CONFDIR/rt_charge_orig" 2>/dev/null)
    if [ "$(cat "$CONFDIR/bypass_active" 2>/dev/null)" = "1" ]; then
        t=$(bypass_current)
    fi
    case "$t" in ''|*[!0-9]*) ;; *) set_charge_current "$t" ;; esac
    log "已重启温控进程 $THERMAL_DAEMON"
    return 0
}

apply_conf_mode() {
    local mode="$1" src="$2" tmd5 curmd5 curname
    ensure_thermal_dir
    tmd5=$(md5sum "$src" 2>/dev/null | cut -d' ' -f1)
    curmd5=$(md5sum "$THERMAL_PATH/thermal-normal.conf" 2>/dev/null | cut -d' ' -f1)
    curname=$(cat "$CONFDIR/current_mode" 2>/dev/null)
    if [ -z "$tmd5" ]; then
        set_status_err "档位文件读取失败: $(basename "$src")"
        return 1
    fi
    if [ "$curmd5" != "$tmd5" ] || [ "$curname" != "$mode" ]; then
        unlock_files
        ensure_thermal_dir
        if ! cp -f "$src" "$THERMAL_PATH/thermal-normal.conf" 2>/dev/null; then
            set_status_err "写入温控配置失败（权限/只读）"
            return 1
        fi
        local n=$(write_map_files)
        restart_daemon
        lock_files
        printf '%s' "$mode" > "$CONFDIR/current_mode"
        update_status "$mode"
        log "切换 → $(mode_label "$mode") ｜ map=$n"
    fi
    return 0
}

thermal_sig() {
    local p="$1"
    [ -d "$p" ] || { echo "none"; return 0; }
    (
        cd "$p" 2>/dev/null || { echo "none"; return 0; }
        for f in *; do
            [ -f "$f" ] && echo "$f=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)"
        done
    ) | md5sum 2>/dev/null | cut -d' ' -f1
}

apply_default() {
    local cur=$(cat "$CONFDIR/current_mode" 2>/dev/null)
    local sig nowsig last
    sig=$(thermal_sig "$THERMAL_PATH")
    last=$(cat "$CONFDIR/.default_sig" 2>/dev/null)
    if [ "$cur" = "default" ] && [ -n "$last" ] && [ "$sig" = "$last" ]; then
        log "已是系统默认且配置未变更，跳过重复还原"
        return 0
    fi
    ensure_thermal_dir
    restore_factory || return 1
    restart_daemon
    printf 'default' > "$CONFDIR/current_mode"
    update_status default
    nowsig=$(thermal_sig "$THERMAL_PATH")
    echo "$nowsig" > "$CONFDIR/.default_sig" 2>/dev/null
    log "切换 → 系统默认（已还原原厂配置，指纹=${nowsig}）"
    return 0
}

apply_bypass() {
    if [ "$MTK_MODE" = "1" ]; then
        log "天玑修复模式：旁路供电已禁用，忽略本次请求"
        return 0
    fi
    local src="$MODDIR/t_bypass_0" tmd5 curmd5
    ensure_thermal_dir
    tmd5=$(md5sum "$src" 2>/dev/null | cut -d' ' -f1)
    curmd5=$(md5sum "$THERMAL_PATH/thermal-normal.conf" 2>/dev/null | cut -d' ' -f1)
    if [ -n "$tmd5" ] && [ "$curmd5" != "$tmd5" ]; then
        unlock_files
        ensure_thermal_dir
        cp -f "$src" "$THERMAL_PATH/thermal-normal.conf" 2>/dev/null
        write_map_files > /dev/null
        restart_daemon
        lock_files
    fi
    set_charge_current "$(bypass_current)"
    if [ "$(cat "$CONFDIR/current_mode" 2>/dev/null)" != "bypass" ]; then
        printf 'bypass' > "$CONFDIR/current_mode"
        update_status bypass
        log "切换 → 旁路供电 ($(bypass_current) uA)"
    fi
    return 0
}

expected_md5() {
    local src=$(src_for_mode "$1")
    [ -n "$src" ] || return 1
    md5sum "$src" 2>/dev/null | cut -d' ' -f1
}

heal_if_needed() {
    local mode=$(cat "$CONFDIR/current_mode" 2>/dev/null)
    case "$mode" in unlimited|level_1|level_2|level_3|level_4|level_5) ;; *) return 0 ;; esac
    [ -f "$CONFDIR/.lock_fail" ] && return 0
    local exp=$(expected_md5 "$mode") cur
    [ -n "$exp" ] || return 0
    cur=$(md5sum "$THERMAL_PATH/thermal-normal.conf" 2>/dev/null | cut -d' ' -f1)
    if [ "$cur" = "$exp" ]; then
        printf '0' > "$CONFDIR/.heal"
        return 0
    fi
    local n=$(cat "$CONFDIR/.heal" 2>/dev/null || echo 0)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    n=$((n + 1))
    printf '%s' "$n" > "$CONFDIR/.heal"
    if [ "$n" -gt 8 ]; then
        echo 1 > "$CONFDIR/.lock_fail"
        set_status_err "配置反复被回写，已停止自愈（可试关闭 lock_conf）"
        log "自愈失败 8 次，放弃锁与自愈"
        return 0
    fi
    log "检测到配置被回写（第 $n 次），自愈中"
    local src=$(src_for_mode "$mode")
    unlock_files
    cp -f "$src" "$THERMAL_PATH/thermal-normal.conf" 2>/dev/null
    lock_files
    return 0
}

screen_on() {
    [ "$(dumpsys deviceidle get screen 2>/dev/null)" != "false" ]
}

foreground_pkg() {
    local fg=""
    fg=$(dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus' | sed -e 's/.*mCurrentFocus=//' -e 's/}.*//' -e 's/.*[ {]//')
    if [ -z "$fg" ]; then
        fg=$(dumpsys activity activities 2>/dev/null | grep -m1 'mResumedActivity' | sed -e 's/.*mResumedActivity=//' -e 's/}.*//' -e 's/.*[ {]//')
    fi
    case "$fg" in
        */*) echo "${fg%%/*}" ;;
        *.) echo "" ;;
        *) case "$fg" in *[!A-Za-z0-9._]*) echo "" ;; *) echo "$fg" ;; esac ;;
    esac
}

is_gaming() {
    local pkgs=$(conf game_apps "")
    [ -n "$pkgs" ] || return 1
    local fg=$(cat "$CONFDIR/.fg_pkg" 2>/dev/null)
    [ -n "$fg" ] || return 1
    local p
    for p in $(echo "$pkgs" | tr '|' ' '); do
        [ "$fg" = "$p" ] && return 0
    done
    return 1
}

apply_fps() {
    local fps="$1"
    case "$fps" in ''|*[!0-9]*) fps=0 ;; esac
    local cur=$(cat "$CONFDIR/.fps_applied" 2>/dev/null)
    [ "$cur" = "$fps" ] && return 0
    if [ "$fps" = "0" ]; then
        local pk=$(cat "$CONFDIR/rt_fps_peak_orig" 2>/dev/null)
        local mn=$(cat "$CONFDIR/rt_fps_min_orig" 2>/dev/null)
        case "$pk" in ''|null|*[!0-9.]*) pk="" ;; esac
        case "$mn" in ''|null|*[!0-9.]*) mn="" ;; esac
        [ -n "$pk" ] && settings put system peak_refresh_rate "$pk" 2>/dev/null
        [ -n "$mn" ] && settings put system min_refresh_rate "$mn" 2>/dev/null
        rm -f "$CONFDIR/rt_fps_peak_orig" "$CONFDIR/rt_fps_min_orig" 2>/dev/null
        log "刷新率恢复 ${pk:-默认}/${mn:-默认}"
    else
        if [ ! -f "$CONFDIR/rt_fps_peak_orig" ]; then
            local op=$(settings get system peak_refresh_rate 2>/dev/null)
            local om=$(settings get system min_refresh_rate 2>/dev/null)
            case "$op" in ''|null|*[!0-9.]*) op="" ;; esac
            case "$om" in ''|null|*[!0-9.]*) om="" ;; esac
            printf '%s' "$op" > "$CONFDIR/rt_fps_peak_orig"
            printf '%s' "$om" > "$CONFDIR/rt_fps_min_orig"
        fi
        settings put system min_refresh_rate "$fps" 2>/dev/null
        settings put system peak_refresh_rate "$fps" 2>/dev/null
        log "刷新率锁定 ${fps}Hz"
    fi
    printf '%s' "$fps" > "$CONFDIR/.fps_applied"
    return 0
}

write_status_json() {
    printf '{"temp":%s,"current":%s,"capacity":%s,"status":"%s","mode":"%s","voltage":%s,"bypass":"%s","guard":"%s","build":"%s","ts":%s}\n' \
        "${BAT_TEMP:-0}" "${BAT_CUR:-0}" "${BAT_CAP:-0}" "${BAT_STATUS:-Unknown}" \
        "$(cat "$CONFDIR/current_mode" 2>/dev/null)" "${BAT_VOLT:-0}" \
        "$(cat "$CONFDIR/bypass_active" 2>/dev/null)" \
        "$(cat "$CONFDIR/.guard" 2>/dev/null)" "$BUILD_VER" "$(date +%s)" > "$CONFDIR/status.json"
}

guard_apply() {
    local mode="$1"
    [ "$ENABLE_GUARD" = "1" ] || { echo "$mode"; return 0; }
    local t=${BAT_TEMP:-0}
    if [ "$t" -ge "$TEMP_GUARD" ]; then
        case "$mode" in
            unlimited|level_1|level_2|default)
                echo "level_3"
                printf '1' > "$CONFDIR/.guard"
                return 0
                ;;
        esac
    fi
    printf '0' > "$CONFDIR/.guard"
    echo "$mode"
}

bypass_decide() {
    local tc="$1" cap=${BAT_CAP:-0}
    local manual=$(cat "$CONFDIR/bypass_manual" 2>/dev/null)
    local trig=$(cat "$CONFDIR/bypass_trigger" 2>/dev/null)
    local allow=$(cat "$CONFDIR/bypass_allow" 2>/dev/null)
    local t_on=$(conf bypass_temp_on 0)
    local t_off=$(conf bypass_temp_off 0)
    local lvl=$(conf bypass_level 0)
    case "$t_on" in ''|*[!0-9]*) t_on=0 ;; esac
    case "$t_off" in ''|*[!0-9]*) t_off=35 ;; esac
    case "$lvl" in ''|*[!0-9]*) lvl=0 ;; esac

    if [ "$manual" = "1" ]; then echo "1:manual"; return 0; fi
    if [ -n "$trig" ]; then
        case "$trig" in
            temp)  [ "$tc" -le "$t_off" ] && { echo 0; return 0; } ;;
            level) [ "$cap" -lt "$lvl" ] && { echo 0; return 0; } ;;
            game)  [ "$allow" = "1" ] || { echo 0; return 0; } ;;
        esac
    fi
    if [ "$t_on" -gt 0 ] && [ "$tc" -ge "$t_on" ]; then echo "1:temp"; return 0; fi
    if [ "$lvl" -gt 2 ] && [ "$lvl" -le 100 ] && [ "$cap" -ge "$lvl" ]; then echo "1:level"; return 0; fi
    if [ "$allow" = "1" ]; then echo "1:game"; return 0; fi
    echo 0
}

hyperos_keepalive() {
    [ "$(conf hyperos4 false)" = "true" ] || return 0
    local now=$(date +%s)
    local last=$(cat "$CONFDIR/.hyp_ka" 2>/dev/null); [ -z "$last" ] && last=0
    [ $((now - last)) -lt 30 ] && return 0
    printf '%s' "$now" > "$CONFDIR/.hyp_ka"
    local ok=1
    [ "$(getprop debug.game.video.support 2>/dev/null)" = "true" ] || ok=0
    [ "$(getprop debug.game.video.speed 2>/dev/null)" = "true" ] || ok=0
    [ "$ok" = "1" ] && return 0
    local rp=""
    for c in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop /data/adb/ap/bin/resetprop; do
        [ -x "$c" ] && { rp="$c"; break; }
    done
    [ -z "$rp" ] && command -v resetprop >/dev/null 2>&1 && rp="resetprop"
    local k
    for k in debug.game.video.support debug.game.video.speed; do
        [ -n "$rp" ] && "$rp" -n "$k" true >/dev/null 2>&1
        setprop "$k" true >/dev/null 2>&1
    done
    log "三倍速属性被系统重置，已自动重新应用"
    return 0
}

tick() {
    ensure_thermal_dir

    if [ -f "$MODDIR/disable" ]; then
        if [ "$(cat "$CONFDIR/current_mode" 2>/dev/null)" != "disabled" ]; then
            apply_default
            printf 'disabled' > "$CONFDIR/current_mode"
            update_status disabled
            log "模块被禁用，已还原原厂配置"
        fi
        return 0
    fi

    if [ "$(conf enabled true)" = "false" ]; then
        if [ "$(cat "$CONFDIR/current_mode" 2>/dev/null)" != "off" ]; then
            apply_default
            printf 'off' > "$CONFDIR/current_mode"
            update_status off
            log "模块开关已关闭，已还原原厂配置"
        fi
        return 0
    fi

    hyperos_keepalive

    BAT_TEMP=$(cat /sys/class/power_supply/battery/temp 2>/dev/null); [ -z "$BAT_TEMP" ] && BAT_TEMP=0
    BAT_CUR=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null); [ -z "$BAT_CUR" ] && BAT_CUR=0
    BAT_CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null); [ -z "$BAT_CAP" ] && BAT_CAP=0
    BAT_STATUS=$(cat /sys/class/power_supply/battery/status 2>/dev/null); [ -z "$BAT_STATUS" ] && BAT_STATUS="Unknown"
    local vn=$(cat "$CONFDIR/rt_voltage_node" 2>/dev/null)
    BAT_VOLT=0
    [ -n "$vn" ] && [ -f "$vn" ] && BAT_VOLT=$(cat "$vn" 2>/dev/null)
    [ -z "$BAT_VOLT" ] && BAT_VOLT=0

    IS_CHARGING=0
    case "$BAT_STATUS" in Charging|Full) IS_CHARGING=1 ;; esac

    local on=0
    screen_on && on=1
    local uni=$(uniform_mode_cached)
    local skip_scene=0
    [ -n "$uni" ] && [ "$(conf game_bypass false)" != "true" ] && skip_scene=1
    if [ "$skip_scene" = "1" ]; then
        if [ ! -f "$CONFDIR/.uni_logged" ]; then
            log "各场景档位一致（$(mode_label "$uni")），已启用快速通道：跳过前台采样与游戏判定"
            : > "$CONFDIR/.uni_logged" 2>/dev/null
        fi
    else
        rm -f "$CONFDIR/.uni_logged" 2>/dev/null
        local now=$(date +%s)
        local last_fg=$(cat "$CONFDIR/.fg_time" 2>/dev/null); [ -z "$last_fg" ] && last_fg=0
        if [ "$on" = "1" ]; then
            if [ $((now - last_fg)) -ge "$FG_INTERVAL" ]; then
                printf '%s' "$(foreground_pkg)" > "$CONFDIR/.fg_pkg"
                printf '%s' "$now" > "$CONFDIR/.fg_time"
            fi
        else
            : > "$CONFDIR/.fg_pkg"
        fi
    fi

    local want_bypass=0 trig=""
    if [ "$MTK_MODE" != "1" ] && [ "$IS_CHARGING" = "1" ]; then
        if [ "$(conf game_mode true)" = "true" ] && [ "$on" = "1" ] && [ "$(conf game_bypass false)" = "true" ] && is_gaming; then
            printf '1' > "$CONFDIR/bypass_allow"
        else
            rm -f "$CONFDIR/bypass_allow" 2>/dev/null
        fi
        local d=$(bypass_decide "$((BAT_TEMP / 10))")
        case "$d" in
            1:*) want_bypass=1; trig="${d#1:}" ;;
            1)   want_bypass=1 ;;
        esac
    fi

    if [ "$want_bypass" = "1" ]; then
        [ -n "$trig" ] && printf '%s' "$trig" > "$CONFDIR/bypass_trigger"
        printf '1' > "$CONFDIR/bypass_active"
        apply_bypass
        write_status_json
        return 0
    fi
    if [ "$(cat "$CONFDIR/bypass_active" 2>/dev/null)" = "1" ]; then
        rm -f "$CONFDIR/bypass_active" 2>/dev/null
        local t=$(cat "$CONFDIR/rt_charge_orig" 2>/dev/null)
        case "$t" in
            ''|*[!0-9]*) log "旁路关闭：无原值可回写" ;;
            *) set_charge_current "$t"; log "旁路关闭：充电电流恢复 $t" ;;
        esac
    fi

    local target="default"
    if [ "$IS_CHARGING" = "1" ] && [ "$MTK_MODE" != "1" ]; then
        if [ "$(conf charge_mode true)" = "true" ]; then
            target=$(conf charge_level unlimited)
            local ts=$(conf time_start 0) te=$(conf time_end 0) tl=$(conf time_level level_1)
            case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
            case "$te" in ''|*[!0-9]*) te=0 ;; esac
            local hour=$(date +%H | sed 's/^0//'); [ -z "$hour" ] && hour=0
            if [ "$ts" -ne 0 ] && [ "$te" -ne 0 ] && [ "$ts" -ne "$te" ]; then
                if [ "$ts" -gt "$te" ]; then
                    { [ "$hour" -ge "$ts" ] || [ "$hour" -lt "$te" ]; } && target="$tl"
                else
                    { [ "$hour" -ge "$ts" ] && [ "$hour" -lt "$te" ]; } && target="$tl"
                fi
            fi
            if [ "$on" = "0" ]; then
                local sl=$(conf sleep_level "")
                [ -n "$sl" ] && target="$sl"
            fi
        else
            target="default"
        fi
    else
        target=$(conf default_mode default)
    fi

    local gaming=0
    if [ "$skip_scene" = "0" ] && [ "$(conf game_mode true)" = "true" ] && [ "$on" = "1" ] && is_gaming; then
        gaming=1
        target=$(conf game_level unlimited)
    fi

    if ! valid_mode "$target"; then
        log "非法档位值 '$target'，沿用上一次有效档位"
        target=$(cat "$CONFDIR/current_mode" 2>/dev/null)
        valid_mode "$target" || target="default"
    fi

    target=$(guard_apply "$target")

    if [ "$gaming" = "1" ]; then
        apply_fps "$(conf game_fps 0)"
    else
        apply_fps 0
    fi

    case "$target" in
        default) apply_default ;;
        unlimited) apply_conf_mode unlimited "$MODDIR/t_blank" ;;
        level_1|level_2|level_3|level_4|level_5)
            local src=$(src_for_mode "$target")
            if [ -s "$src" ] && [ "$(wc -c < "$src" 2>/dev/null || echo 0)" -ge 512 ]; then
                apply_conf_mode "$target" "$src"
            else
                set_status_err "档位文件缺失或损坏：$(basename "$src")"
                apply_default
            fi
            ;;
        *) apply_default ;;
    esac

    heal_if_needed
    update_status "$(cat "$CONFDIR/current_mode" 2>/dev/null)"
    write_status_json
    return 0
}

MD5_BLANK="de59942d3dffc090f0dae74dfc4d47ce"
MD5_BYPASS_0="006bb13431c52592192e710e46e76879"
MD5_BYPASS_1="959b4f8711503653abea8a019936ab2c"
MD5_MAP="43b4b914ef6b45119bbfe2030e4025a7"

check_core_files() {
    local ok=1
    [ "$(md5sum "$MODDIR/t_blank" 2>/dev/null | cut -d' ' -f1)" = "$MD5_BLANK" ] || ok=0
    [ "$(md5sum "$MODDIR/t_bypass_0" 2>/dev/null | cut -d' ' -f1)" = "$MD5_BYPASS_0" ] || ok=0
    [ "$(md5sum "$MODDIR/t_bypass_1" 2>/dev/null | cut -d' ' -f1)" = "$MD5_BYPASS_1" ] || ok=0
    [ "$(md5sum "$MODDIR/t_map" 2>/dev/null | cut -d' ' -f1)" = "$MD5_MAP" ] || ok=0
    [ "$ok" = "1" ] && echo 1 || echo 0
}

restore_core_files() {
    local f
    for f in t_blank t_bypass_0 t_bypass_1 t_map; do
        [ -f "$MODDIR/thermal/$f" ] && cp -f "$MODDIR/thermal/$f" "$MODDIR/$f" 2>/dev/null
    done
}

ensure_core_files() {
    if [ "$(check_core_files)" != "1" ]; then
        restore_core_files
        if [ "$(check_core_files)" != "1" ]; then
            set_status_err "核心温控文件损坏，请重装模块"
            return 1
        fi
        log "核心文件已从 thermal/ 恢复"
    fi
    return 0
}

selfcheck() {
    init_profile
    local fail=0
    echo "================ 自检 ================"
    if ensure_core_files; then echo "[OK] 核心文件完整"; else echo "[X] 核心文件损坏"; fail=$((fail + 1)); fi
    BOOT=$(getprop sys.boot_completed 2>/dev/null)
    echo "· 开机完成标记: ${BOOT:-0}"
    probe >/dev/null 2>&1
    if [ -n "$THERMAL_DAEMON" ]; then echo "[OK] 温控守护进程: $THERMAL_DAEMON"; else echo "[X] 未找到温控守护进程"; fail=$((fail + 1)); fi
    if daemon_running; then echo "[OK] 守护进程运行中"; else echo "[!] 守护进程未运行（开机初期正常）"; fi
    echo "· 温控配置目录: $THERMAL_PATH"
    if [ -d "$THERMAL_PATH" ] && [ -w "$THERMAL_PATH" ]; then echo "[OK] 配置目录可写"; else echo "[X] 配置目录不可写"; fail=$((fail + 1)); fi
    if backup_ready; then
        echo "[OK] 原厂备份: $(backup_source) ($(ls -A "$(backup_source)" 2>/dev/null | wc -l) 个文件)"
    else
        echo "[!] 尚无原厂备份（守卫会持续尝试）"
    fi
    refresh_thermal_list
    local maps=$(grep -ci '\-map' "$MODDIR/thermal_list" 2>/dev/null)
    echo "· thermal-map 文件: ${maps:-0} 个"
    [ "${maps:-0}" -gt 0 ] || { echo "[X] 未找到 thermal-*-map，机型可能不受支持"; fail=$((fail + 1)); }
    if [ "$MTK_MODE" = "1" ]; then
        echo "· 充电电流调节: 已禁用（天玑修复模式）"
    elif [ -n "$CHARGE_NODE" ]; then
        echo "[OK] 充电电流节点: $CHARGE_NODE"
        echo "· 充电电流原值: $(cat "$CONFDIR/rt_charge_orig" 2>/dev/null || echo 未记录)"
    else
        echo "[!] 未找到可写充电电流节点（旁路功能受限）"
    fi
    echo "· 平台/机型: ${PLATFORM:-?} / ${MODEL:-?}"
    echo "· 当前档位: $(mode_label "$(cat "$CONFDIR/current_mode" 2>/dev/null)")"
    local t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    case "$t" in ''|*[!0-9]*) ;; *) echo "· 电池温度: $((t / 10)).$((t % 10))℃" ;; esac
    if [ -f "$CONFDIR/status.json" ]; then echo "· 状态: $(cat "$CONFDIR/status.json")"; fi
    echo "· 机型档案: $(basename "$PROFILE_FILE")"
    echo "======================================"
    [ "$fail" -eq 0 ] && echo "自检通过" || echo "自检发现 $fail 项问题"
    return "$fail"
}

init_profile
mkdir -p "$CONFDIR" 2>/dev/null

if ! ensure_core_files; then
    exit 1
fi

case "$CMD" in
    probe)
        if probe; then
            save_charge_orig
            factory_backup
            refresh_thermal_list
            exit 0
        fi
        set_status_err "未找到温控守护进程，模块无法工作"
        exit 1
        ;;
    apply|tick)
        bootstrap || { set_status_err "运行时信息缺失，无法应用"; exit 1; }
        save_charge_orig
        factory_backup
        tick
        exit 0
        ;;
    status)
        cat "$CONFDIR/status.json" 2>/dev/null
        exit 0
        ;;
    selfcheck)
        bootstrap >/dev/null 2>&1
        selfcheck
        exit $?
        ;;
    restore)
        bootstrap || exit 1
        restore_factory
        _orig=$(cat "$CONFDIR/rt_charge_orig" 2>/dev/null)
        case "$_orig" in ''|*[!0-9]*) ;; *) set_charge_current "$_orig" ;; esac
        restart_daemon
        printf 'default' > "$CONFDIR/current_mode"
        update_status default
        log "手动还原原厂配置完成"
        exit 0
        ;;
esac

bootstrap || exit 1
save_charge_orig
factory_backup
refresh_thermal_list
rm -f "$CONFDIR/.heal" 2>/dev/null
LAST_RESTART=0
log "thermal_core 启动 daemon=$THERMAL_DAEMON path=$THERMAL_PATH"
while true; do
    tick
    sleep "$POLL_INTERVAL"
done
