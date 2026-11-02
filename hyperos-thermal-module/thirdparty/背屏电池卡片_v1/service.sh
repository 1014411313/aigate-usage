#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/local/tmp/eta_rearscreen.log
say(){ echo "$(date '+%H:%M:%S') $*" >> $LOG; }

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do sleep 2; i=$((i+1)); done
sleep 3
say "service start"

DATA=/storage/emulated/0/Android/data/com.eta.rearscreen/files
mkdir -p $DATA

( while true; do
    MV=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
    MA=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
    T=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    ST=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    printf '%s %s %s %s %s' "$MV" "$MA" "$T" "$CAP" "$ST" > $DATA/batt.txt 2>/dev/null
    sleep 2
  done ) &

while true; do
  if ! pidof com.eta.rearscreen >/dev/null 2>&1; then
    am start -n com.eta.rearscreen/.MainActivity >/dev/null 2>&1
    sleep 4
  fi
  UID=$(dumpsys package com.eta.rearscreen 2>/dev/null | grep -m1 appId= | sed 's/.*appId=//')
  if [ -n "$UID" ]; then
    LINE=$(dumpsys activity activities 2>/dev/null | grep -m1 "A=$UID:com.eta.rearscreen")
    T=$(echo "$LINE" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
    if [ -n "$T" ]; then
      ON=$(dumpsys activity activities 2>/dev/null | grep -A2 'Display #1' | grep -c 'com.eta.rearscreen')
      if [ "$ON" = "0" ]; then
        service call activity_task 50 i32 $T i32 1 >/dev/null 2>&1
        say "pushed $T"
      fi
    fi
  fi
  sleep 3
done
