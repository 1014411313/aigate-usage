#!/system/bin/sh
# smart_fv 变化回调（inotify handler）
FV=/sys/class/xm_power/charger/smart_charge/smart_fv
LOG=/data/local/tmp/xt_toolbox.log
v=$(cat "$FV" 2>/dev/null)
if [ -n "$v" ] && [ "$v" != "0" ]; then
  echo 0 > "$FV" 2>/dev/null
  echo "$(date '+%F %T') fv_guard: [inotify] $v -> 0" >> "$LOG"
fi
