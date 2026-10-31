#!/system/bin/sh
# apl_toggle.sh —— 自适应功率爬坡器开关（整合版新增）
# 用法：apl_toggle.sh 1|0        # 1=开启（需 power_limit=inf），0=关闭
# 说明：APL 是常驻进程，改配置后必须重启进程才生效；这里只做「停旧 + 按新配置起新」，
#       不碰 charge_guard 的其它逻辑。
XBT=${XBT:-/data/adb/modules/HyperOS_XJ/battery}
if [ ! -f "$XBT/scripts/common.sh" ]; then
    echo "ERR: 找不到 common.sh（$XBT）"
    exit 1
fi
. "$XBT/scripts/common.sh" 2>/dev/null
if ! command -v cfg_set >/dev/null 2>&1 || ! command -v cfg_get >/dev/null 2>&1; then
    echo "ERR: common.sh 未提供 cfg_set/cfg_get"
    exit 1
fi

on="$1"
case "$on" in 1|0) ;; *) echo "usage: apl_toggle.sh 1|0" >&2; exit 2 ;; esac

cfg_set apl_enable "$on" >/dev/null 2>&1
_back=$(cfg_get apl_enable "")
if [ "$_back" != "$on" ]; then
    echo "ERR: 配置写入失败（读到[$_back]）"
    exit 3
fi

_stop() {
    for _p in $(timeout 5 pgrep -f 'HyperOS_XJ/battery/scripts/apl\.sh' 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        kill -TERM "$_p" 2>/dev/null
    done
    sleep 0.4
    for _p in $(timeout 5 pgrep -f 'HyperOS_XJ/battery/scripts/apl\.sh' 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        kill -9 "$_p" 2>/dev/null
    done
    rm -f "$XBT/state/apl.pid" "$XBT/state/apl_target_ma" "$XBT/state/apl_urgent" 2>/dev/null
}
_stop

if [ "$on" = "1" ]; then
    if [ "$(cfg_get power_limit inf)" != "inf" ]; then
        echo "APL 已开启，但当前功率档不是「全速」，切到全速后才会运行"
        exit 0
    fi
    if [ -f "$XBT/scripts/apl.sh" ]; then
        ( setsid sh "$XBT/scripts/apl.sh" >/dev/null 2>&1 < /dev/null & )
        sleep 2
        _pid=$(cat "$XBT/state/apl.pid" 2>/dev/null)
        case "$_pid" in
            ''|*[!0-9]*) echo "APL 已开启（进程尚未写入 pid，稍等几秒再看状态）" ;;
            *) echo "APL 已开启（pid=$_pid）" ;;
        esac
    else
        echo "ERR: 缺少 scripts/apl.sh"
        exit 4
    fi
else
    echo "APL 已关闭"
fi
