#!/system/bin/sh
# GPU 智能升频 · 供 KernelSU 管理器「执行」按钮使用（音量键菜单）
MODDIR=${0%/*}
DATA=/data/adb/gpu_autoboost
API="$MODDIR/webroot/api.sh"

say() { echo "$1"; }

clear 2>/dev/null
say "====================================="
say "        GPU 智能升频 · 快捷操作"
say "====================================="
say "   [音量+]  查看状态"
say "   [音量-]  重启守护"
say "====================================="

key=""
i=0
while [ "$i" -lt 60 ]; do
    k=$(getevent -qlc 1 2>/dev/null | grep -m1 -E "KEY_VOLUME(UP|DOWN)")
    case "$k" in
        *VOLUMEUP*) key=up; break ;;
        *VOLUMEDOWN*) key=down; break ;;
    esac
    i=$((i + 1))
done

say ""
if [ "$key" = "up" ]; then
    sh "$API" status
elif [ "$key" = "down" ]; then
    sh "$API" restart
    say ">> 已重启守护"
else
    say ">> 操作超时"
fi
