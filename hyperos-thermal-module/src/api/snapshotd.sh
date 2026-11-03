#!/system/bin/sh
MODDIR=${SNAP_MODDIR:-$(CDPATH= cd -- "${0%/*}/.." 2>/dev/null && pwd -P)}
XBT=$MODDIR/battery
RUN=$MODDIR/run
CONFIG=$MODDIR/config
PIDF=$RUN/snapshot.pid
LOCK=$RUN/snapshot.lock
LOG=$MODDIR/log/snapshot.log
API_DIR=$MODDIR/api
SYS=${SNAP_SYSROOT:-/sys}
APP_PKG=com.hyperos.xj
PROVIDER=content://com.hyperos.xj.rearsnapshot
DETAIL_CACHE=$RUN/detail.kv
DETAIL_STAMP=$RUN/detail.stamp
FULL_CACHE=$RUN/status.kv
FULL_STAMP=$RUN/status.stamp
DETAIL_INTERVAL=${SNAP_DETAIL_INTERVAL:-8}
PROVIDER_CHECK=$RUN/provider.checked
PROVIDER_HEALTH=$RUN/provider_health.json

mkdir -p "$RUN" "${LOG%/*}" 2>/dev/null
umask 077
XJ_BAK=$RUN
. "$API_DIR/config_io.sh"
WORK=$(mktemp -d "$RUN/snapshot-work.XXXXXXXX") || exit 1
stop_running() {
  read -r p s < "$LOCK/owner" 2>/dev/null || return 0
  owner_live "$p" "$s" && kill -TERM "$p" 2>/dev/null
}
snapshot_cleanup() {
  [ "$(cat "$LOCK/owner" 2>/dev/null)" = "$$ $START" ] && rm -f "$PIDF"
  cleanup
}
trap 'snapshot_cleanup' EXIT
trap 'exit 0' HUP INT TERM
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then stop_running; exit 0; fi
attempt=0
until lock_acquire "$LOCK" "$RUN/snapshot.reap"; do
  attempt=$((attempt+1)); [ "$attempt" -lt 15 ] || exit 0
  sleep 1
done
printf '%s %s\n' "$$" "$START" > "$PIDF"
chmod 0644 "$PIDF" 2>/dev/null

log_limited() {
  code=$1; msg=$2; now=$(date +%s)
  last=$(awk -F= -v k="$code" '$1==k{v=$2} END{print v}' "$RUN/provider.logstamp" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now-last)) -ge 60 ]; then
    printf '%s=%s\n' "$code" "$now" >> "$RUN/provider.logstamp"
    printf '%s [snapshot] %s\n' "$(date '+%F %T')" "$msg" >> "$LOG"
  fi
}
read_fast() { [ -n "${SNAP_FAST_FILE:-}" ] && cat "$SNAP_FAST_FILE" || sh "$XBT/scripts/status_fast.sh" 2>/dev/null; }
read_detail() { [ -n "${SNAP_DETAIL_FILE:-}" ] && cat "$SNAP_DETAIL_FILE" || sh "$XBT/scripts/detail_kv.sh" 2>/dev/null; }
read_full() { [ -n "${SNAP_FULL_FILE:-}" ] && cat "$SNAP_FULL_FILE" || SNAP_XBT="$XBT" SNAP_SYSROOT="$SYS" sh "$API_DIR/snapshot_ro.sh" 2>/dev/null; }
read_settings() {
  awk -F= '/^[A-Za-z0-9_]+=/ { k=$1; a[k]=substr($0,index($0,"=")+1) } END { for(k in a) printf "CFG:%s=%s\n",k,a[k] }' "$XBT/config/settings.conf" 2>/dev/null
}
read_rear() {
  file=$CONFIG/rearscreen.json
  [ -r "$file" ] || { printf '%s\n' '{"enabled":false,"fields":["temp","soc","volt","cur"],"accent":"78,161,255","theme":"aurora","font_scale":1}'; return; }
  LC_ALL=C awk -v check=rear -f "$API_DIR/json.awk" -f "$API_DIR/validate.awk" "$file" >/dev/null 2>&1 || return 1
  LC_ALL=C awk -v mode=root -f "$API_DIR/json.awk" "$file" 2>/dev/null
}
read_runtime() {
  mode=unknown; temp=; soc=; desired=; effective=
  [ -r "$CONFIG/current_mode" ] && IFS= read -r mode < "$CONFIG/current_mode"
  [ -r "$SYS/class/power_supply/battery/temp" ] && IFS= read -r temp < "$SYS/class/power_supply/battery/temp"
  [ -r "$SYS/class/power_supply/battery/capacity" ] && IFS= read -r soc < "$SYS/class/power_supply/battery/capacity"
  case "$temp" in ''|*[!0-9-]*) temp= ;; *) temp=$(awk -v t="$temp" 'BEGIN{printf "%.1f",t/10}') ;; esac
  case "$soc" in ''|*[!0-9]*) soc= ;; esac
  [ -r "$CONFIG/settings.json" ] && desired=$(awk -F'"' '/"default_mode"[[:space:]]*:/ {print $4; exit}' "$CONFIG/settings.json" 2>/dev/null)
  [ -r "$CONFIG/status.json" ] && effective=$(awk -F'"' '/"mode"[[:space:]]*:/ {print $4; exit}' "$CONFIG/status.json" 2>/dev/null)
  printf 'CFG:_mode=%s\nCFG:_desired=%s\nCFG:_effective=%s\nCFG:_actual=%s\nCFG:_thermal_temp=%s\nCFG:_thermal_soc=%s\n' "$mode" "$desired" "$effective" "$mode" "$temp" "$soc"
}
publish_if_installed() {
  [ "${SNAP_NO_PROVIDER:-0}" = 1 ] && return 0
  now=$(date +%s); checked=$(cat "$PROVIDER_CHECK" 2>/dev/null)
  case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
  if [ ! -f "$PROVIDER_CHECK" ] || [ $((now-checked)) -ge 300 ]; then
    printf '%s' "$now" > "$PROVIDER_CHECK.tmp" && mv -f "$PROVIDER_CHECK.tmp" "$PROVIDER_CHECK"
    installed=0
    cmd package list packages --user 0 "$APP_PKG" 2>/dev/null | grep -Fqx "package:$APP_PKG" && installed=1
    printf '%s' "$installed" > "$RUN/provider.installed.tmp" && mv -f "$RUN/provider.installed.tmp" "$RUN/provider.installed"
  fi
  [ "$(cat "$RUN/provider.installed" 2>/dev/null)" = 1 ] || return 0
  out=$(content call --user 0 --uri "$PROVIDER" --method publish_snapshot --arg "$b64" 2>&1)
  if printf '%s' "$out" | grep -Eq '(^|[^[:alnum:]_])ok=true([^[:alnum:]_]|$)' && ! printf '%s' "$out" | grep -Eq '(^|[^[:alnum:]_])ok=false([^[:alnum:]_]|$)'; then
    printf '{"ok":true,"timestamp":%s}\n' "$now" > "$PROVIDER_HEALTH.tmp"
    mv -f "$PROVIDER_HEALTH.tmp" "$PROVIDER_HEALTH"
  else
    printf '{"ok":false,"timestamp":%s,"error":"publish_failed"}\n' "$now" > "$PROVIDER_HEALTH.tmp"
    mv -f "$PROVIDER_HEALTH.tmp" "$PROVIDER_HEALTH"
    log_limited publish "Provider publish_snapshot 失败: ${out:-empty output}"
  fi
}

while [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ]; do
  fast=$(read_fast)
  now=$(date +%s)
  stamp=$(cat "$DETAIL_STAMP" 2>/dev/null); case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
  if [ $((now-stamp)) -ge "$DETAIL_INTERVAL" ] || [ ! -f "$DETAIL_CACHE" ]; then
    detail=$(read_detail)
    if [ -n "$detail" ]; then printf '%s\n' "$detail" > "$DETAIL_CACHE.tmp" && mv -f "$DETAIL_CACHE.tmp" "$DETAIL_CACHE"; printf '%s' "$now" > "$DETAIL_STAMP.tmp" && mv -f "$DETAIL_STAMP.tmp" "$DETAIL_STAMP"; fi
  fi
  stamp=$(cat "$FULL_STAMP" 2>/dev/null); case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
  if [ $((now-stamp)) -ge "$DETAIL_INTERVAL" ] || [ ! -f "$FULL_CACHE" ]; then
    full=$(read_full)
    if [ -n "$full" ]; then printf '%s\n' "$full" > "$FULL_CACHE.tmp" && mv -f "$FULL_CACHE.tmp" "$FULL_CACHE"; printf '%s' "$now" > "$FULL_STAMP.tmp" && mv -f "$FULL_STAMP.tmp" "$FULL_STAMP"; fi
  fi
  rear=$(read_rear)
  cfg="$(read_settings)
$(read_runtime)"
  input=$RUN/snapshot.input
  {
    printf '%s\n' "$(cat "$FULL_CACHE" "$DETAIL_CACHE" 2>/dev/null)" | while IFS= read -r line; do [ -n "$line" ] && printf 'KV:%s\n' "$line"; done
    printf '%s\n' "$fast" | while IFS= read -r line; do [ -n "$line" ] && printf 'FAST:%s\n' "$line"; done
    printf '%s\n' "$cfg"
    printf 'CFG:_timestamp=%s\n' "$now"
    [ -n "$rear" ] && printf 'REAR:%s\n' "$rear"
  } > "$input.tmp"
  mv -f "$input.tmp" "$input"
  awk -f "$API_DIR/snapshot.awk" "$input" > "$RUN/snapshot.json.tmp" 2>/dev/null
  if [ -s "$RUN/snapshot.json.tmp" ] && mv -f "$RUN/snapshot.json.tmp" "$RUN/snapshot.json"; then
    b64=$(base64 "$RUN/snapshot.json" 2>/dev/null | tr -d '\r\n')
    publish_if_installed
  fi
  [ "${SNAP_ONCE:-0}" = 1 ] && break
  sleep 1
done
exit 0
