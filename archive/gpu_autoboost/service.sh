#!/system/bin/sh
# GPU 智能升频 · 启动入口与看门狗
MODDIR=${0%/*}
DAEMON="$MODDIR/gpud"
DATA=/data/adb/gpu_autoboost
LOCK="$DATA/gpud.lock"
PAUSE="$DATA/pause"

[ -f "$PAUSE" ] && exit 0

mkdir -p "$DATA/run" 2>/dev/null
[ -f "$DATA/config.conf" ] || cp "$MODDIR/default.conf" "$DATA/config.conf" 2>/dev/null

# 不能只看锁文件在不在：守护被 kill -9 时不会走 cleanup，锁文件会残留。
# 判据是锁里的 pid 是否还存在，且 cmdline 确实是 gpud（pid 会被复用）。
alive() {
    [ -f "$LOCK" ] || return 1
    PID=$(cat "$LOCK" 2>/dev/null)
    case "$PID" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$PID" ] || return 1
    tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null | grep -q gpud
}

# KernelSU / Magisk 同步执行 service.sh，前台阻塞会占住 runner，
# 所以等待与看门狗整体放进子 shell 立刻返回。
(
    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 150 ]; do
        sleep 2
        i=$((i + 1))
    done
    sleep 5

    while true; do
        if [ ! -f "$PAUSE" ] && ! alive; then
            # 拉起前先清掉所有残留实例。只靠 lock 指向的 pid 不够：
            # 多个守护竞争写 lock 时，最后写的那个可能已经死了，
            # 而先启动的那个还在跑，看门狗会当作“没人”再拉一个，越积越多。
            for f in /proc/[0-9]*/cmdline; do
                p=${f#/proc/}
                p=${p%/cmdline}
                grep -q "gpu_autoboost/gpud" "$f" 2>/dev/null && kill "$p" 2>/dev/null
            done
            sleep 1
            [ -f "$LOCK" ] && rm -f "$LOCK" 2>/dev/null
            nohup sh "$DAEMON" >/dev/null 2>&1 </dev/null &
        fi
        sleep 30
    done
) &
exit 0
