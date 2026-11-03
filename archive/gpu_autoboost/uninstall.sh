#!/system/bin/sh
# GPU 智能升频 · 卸载清理
#
# 顺序：先停守护（它持原始值快照，正常退出会自己恢复），
# 再按 run/orig_min 兜底写回，最后清掉数据目录。

DATA=/data/adb/gpu_autoboost
LOCK=$DATA/gpud.lock
ORIG=$DATA/run/orig_min
GPU=/sys/class/kgsl/kgsl-3d0

if [ -f "$LOCK" ]; then
    p=$(cat "$LOCK" 2>/dev/null)
    case "$p" in
        ''|*[!0-9]*) : ;;
        *) kill "$p" 2>/dev/null ;;
    esac
    i=0
    while [ "$i" -lt 10 ] && [ -d "/proc/$p" ]; do
        sleep 0.3
        i=$((i + 1))
    done
    case "$p" in
        ''|*[!0-9]*) : ;;
        *) [ -d "/proc/$p" ] && kill -9 "$p" 2>/dev/null ;;
    esac
fi

if [ -f "$ORIG" ] && [ -w "$GPU/min_pwrlevel" ]; then
    o=$(cat "$ORIG" 2>/dev/null)
    case "$o" in
        ''|*[!0-9]*) : ;;
        *) printf '%s\n' "$o" > "$GPU/min_pwrlevel" 2>/dev/null ;;
    esac
fi

# 路径写字面量而不是变量：变量万一为空，rm -rf 删的就是 /data/adb
rm -rf /data/adb/gpu_autoboost 2>/dev/null

echo "GPU 智能升频：已恢复启动前状态"
