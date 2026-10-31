#!/system/bin/sh
MODDIR=${0%/*}
CONFDIR="$MODDIR/config"
LOGDIR="$MODDIR/log"
SVC_LOG="$LOGDIR/service.log"
CORE="$MODDIR/thermal_core.sh"
PIDFILE="$CONFDIR/core.pid"
PROP="$MODDIR/module.prop"

mkdir -p "$CONFDIR" "$LOGDIR" 2>/dev/null

CORE_LOG="$LOGDIR/core.log"
slog() {
    local _ts=$(date '+%F %T')
    local _line="$_ts [SVC] $*"
    echo "$_line" >> "$SVC_LOG" 2>/dev/null
    echo "$_line" >> "$CORE_LOG" 2>/dev/null
    if [ -f "$SVC_LOG" ]; then
        local n=$(wc -l < "$SVC_LOG" 2>/dev/null || echo 0)
        [ "${n:-0}" -gt 500 ] && { tail -n 250 "$SVC_LOG" > "$SVC_LOG.tmp" 2>/dev/null && mv -f "$SVC_LOG.tmp" "$SVC_LOG"; }
    fi
    if [ -f "$CORE_LOG" ]; then
        local m=$(wc -l < "$CORE_LOG" 2>/dev/null || echo 0)
        [ "${m:-0}" -gt 800 ] && { tail -n 400 "$CORE_LOG" > "$CORE_LOG.tmp" 2>/dev/null && mv -f "$CORE_LOG.tmp" "$CORE_LOG"; }
    fi
}

set_desc() {
    local d="$1"
    [ -f "$PROP" ] || return 0
    local cur=$(grep '^description=' "$PROP" 2>/dev/null | sed 's/^description=//')
    [ "$cur" = "$d" ] && return 0
    grep -v '^description=' "$PROP" > "$PROP.tmp" 2>/dev/null
    printf 'description=%s\n' "$d" >> "$PROP.tmp" 2>/dev/null
    mv -f "$PROP.tmp" "$PROP" 2>/dev/null
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

temp_str() {
    local t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    case "$t" in
        ''|*[!0-9-]*) echo "--.-" ; return 0 ;;
    esac
    [ "$t" -lt 0 ] && t=0
    echo "$((t / 10)).$((t % 10))"
}

i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    i=$((i + 1))
    [ "$i" -ge 180 ] && { slog "等待开机超时，继续尝试启动"; break; }
    sleep 1
done
slog "service 启动（等待 ${i}s）"

if [ ! -s "$CONFDIR/settings.json" ]; then
    if [ -s "$MODDIR/default_settings.json" ]; then
        cp -f "$MODDIR/default_settings.json" "$CONFDIR/.settings.new" 2>/dev/null
        mv -f "$CONFDIR/.settings.new" "$CONFDIR/settings.json" 2>/dev/null
        slog "已生成默认配置 settings.json"
    fi
else

    head -c 1 "$CONFDIR/settings.json" 2>/dev/null | grep -q '{' || {
        cp -f "$MODDIR/default_settings.json" "$CONFDIR/.settings.new" 2>/dev/null
        mv -f "$CONFDIR/.settings.new" "$CONFDIR/settings.json" 2>/dev/null
        slog "配置损坏，已重置为默认"
    }
fi
if grep -q '"hyperos4"[[:space:]]*:[[:space:]]*true' "$CONFDIR/settings.json" 2>/dev/null; then
    if [ -f "$MODDIR/HyperOS/HyperOS-yes" ]; then
        if sh "$MODDIR/HyperOS/HyperOS-yes" >/dev/null 2>&1; then
            slog "开机已自动应用 HyperOS 三倍速（HyperOS/HyperOS-yes）"
        else
            slog "开机应用 HyperOS 三倍速失败（HyperOS/HyperOS-yes）"
        fi
    else
        slog "三倍速开关为开启状态，但缺少 HyperOS/HyperOS-yes，已跳过"
    fi
else
    [ -f "$MODDIR/HyperOS/HyperOS-off" ] && sh "$MODDIR/HyperOS/HyperOS-off" >/dev/null 2>&1
fi

[ -s "$CONFDIR/current_mode" ] || printf 'default' > "$CONFDIR/current_mode"

if [ ! -f "$CONFDIR/mtk_fix" ]; then
    [ -s "$CONFDIR/bypass_current" ] || printf '500000' > "$CONFDIR/bypass_current"
else
    rm -f "$CONFDIR/bypass_current" "$CONFDIR/bypass_active" 2>/dev/null
fi

chmod 0755 "$CORE" 2>/dev/null


set_desc "初始化中：正在探测温控环境"
if "$CORE" "$MODDIR" probe >> "$SVC_LOG" 2>&1; then
    slog "环境探测成功"
else
    slog "环境探测失败，等待守护进程"
fi


"$CORE" "$MODDIR" selfcheck >> "$SVC_LOG" 2>&1
SC=$?
slog "自检退出码=$SC"


start_core() {

    if [ -s "$PIDFILE" ]; then
        local p=$(cat "$PIDFILE" 2>/dev/null)
        case "$p" in
            ''|*[!0-9]*) ;;
            *) [ -d "/proc/$p" ] && return 0 ;;
        esac
    fi
    nohup "$CORE" "$MODDIR" >> "$LOGDIR/core.stdout" 2>&1 &
    echo $! > "$PIDFILE"
    slog "thermal_core 已拉起 pid=$(cat "$PIDFILE" 2>/dev/null)"
}

start_core


sleep 3
CURDESC=$(grep '^description=' "$PROP" 2>/dev/null | sed 's/^description=//')
case "$CURDESC" in
    *初始化*|"")
        if [ "$SC" = "0" ]; then
            set_desc "运行中 ｜ $(mode_label "$(cat "$CONFDIR/current_mode" 2>/dev/null)") ｜ $(temp_str)℃"
        else
            set_desc "功能受限 ｜ 自检 $SC 项异常 ｜ 请在模块内运行 action.sh"
        fi
        ;;
esac


while true; do
    sleep 60
    [ -f "$MODDIR/disable" ] && continue
    local_ok=1
    if [ -s "$PIDFILE" ]; then
        p=$(cat "$PIDFILE" 2>/dev/null)
        case "$p" in
            ''|*[!0-9]*) local_ok=0 ;;
            *) [ -d "/proc/$p" ] || local_ok=0 ;;
        esac
    else
        local_ok=0
    fi
    if [ "$local_ok" = "0" ]; then
        slog "核心进程丢失，重启"
        set_desc "重连中 ｜ 温控核心正在拉起"
        start_core
        sleep 5
        set_desc "运行中 ｜ $(mode_label "$(cat "$CONFDIR/current_mode" 2>/dev/null)") ｜ $(temp_str)℃"
    fi
done
