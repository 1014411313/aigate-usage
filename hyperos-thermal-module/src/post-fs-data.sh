#!/system/bin/sh
MODDIR=${0%/*}
BAT="$MODDIR/battery"
LOGDIR="$MODDIR/log"

mkdir -p "$LOGDIR" 2>/dev/null

if [ -f "$BAT/post-fs-data.sh" ]; then
    sh "$BAT/post-fs-data.sh" >> "$LOGDIR/battery.log" 2>&1
fi
exit 0
