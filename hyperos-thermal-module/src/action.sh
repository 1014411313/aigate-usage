#!/system/bin/sh
MODDIR=${0%/*}
LOG="$MODDIR/log/core.log"
mkdir -p "$MODDIR/log" 2>/dev/null
log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

log "---------- action.sh 触发 | MODDIR=$MODDIR ----------"

PKG=com.hyperos.xj

OUT=$(am start -n "$PKG/.MainActivity" 2>&1)
case "$OUT" in
    *Error*|*Exception*|*Failure*)
        log "am start -n 失败: $(echo "$OUT" | tr '\n' ' ')"
        ;;
    *)
        log "am start -n $PKG/.MainActivity 成功"
        exit 0
        ;;
esac

OUT=$(am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p "$PKG" 2>&1)
case "$OUT" in
    *Error*|*Exception*|*Failure*)
        log "am start -p 失败: $(echo "$OUT" | tr '\n' ' ')"
        ;;
    *)
        log "am start -p $PKG 成功"
        exit 0
        ;;
esac

OUT=$(monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 2>&1)
case "$OUT" in
    *"No activities found"*|*"aborted"*|*Error*|*Exception*)
        log "monkey 失败: $(echo "$OUT" | tr '\n' ' ')"
        ;;
    *)
        log "monkey 启动成功"
        exit 0
        ;;
esac

log "启动失败：$PKG 未安装或入口被禁用"
echo "无法启动 $PKG，请确认控制台 APK 已安装。日志：$LOG"
exit 1