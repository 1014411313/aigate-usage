#!/system/bin/sh
umask 077
BAK=${XJ_BAK:-/data/adb/HyperOS_XJ_data}
JOBS=$BAK/api-jobs
JSON_AWK=$API_DIR/json.awk
LOCK_HELD=0
BATTERY_HELD=0

error() { printf '{"error":'; printf '%s' "$1" | json_quote; printf '}\n'; exit "${2:-3}"; }
json_quote() {
  LC_ALL=C awk 'BEGIN{printf "\""} {if(NR>1) printf "\\n"; for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="\"" || c=="\\") printf "\\%s",c; else if(c ~ /[[:cntrl:]]/){for(j=0;j<128;j++) if(c==sprintf("%c",j)) break; printf "\\u%04x",j} else printf "%s",c}} END{printf "\""}'
}
json_check() { LC_ALL=C awk -v check="$1" -f "$JSON_AWK" -f "$API_DIR/validate.awk" "$2"; }
field() { LC_ALL=C awk -v check=raw -v path="$1" -f "$JSON_AWK" -f "$API_DIR/validate.awk" "$REQ" 2>/dev/null; }
field_type() { LC_ALL=C awk -v check=type -v path="$1" -f "$JSON_AWK" -f "$API_DIR/validate.awk" "$REQ" 2>/dev/null; }
extract() { LC_ALL=C awk -v check=extract -v path="$1" -f "$JSON_AWK" -f "$API_DIR/validate.awk" "$2"; }
request_keys() { LC_ALL=C awk -v check=keys -v allowed="$1" -f "$JSON_AWK" -f "$API_DIR/validate.awk" "$REQ" >/dev/null || error '请求字段无效'; }
need() { FIELD=$(field "$1") || error "缺少或无效字段: $1"; }
need_string() { [ "$(field_type "$1")" = string ] || error "字段必须为字符串: $1"; need "$1"; }
need_bool() { [ "$(field_type "$1")" = bool ] || error "字段必须为布尔值: $1"; need "$1"; [ "$FIELD" = true ] && FIELD=1 || FIELD=0; }
uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 10 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

pid_start() { awk '{sub(/^.*\) /, ""); print $20}' "/proc/$1/stat" 2>/dev/null; }
pid_state() { awk '{sub(/^.*\) /, ""); print $1}' "/proc/$1/stat" 2>/dev/null; }
owner_live() {
  case "$1:$2" in *[!0-9:]*|:*|*:) return 1 ;; esac
  kill -0 "$1" 2>/dev/null && [ "$(pid_start "$1")" = "$2" ] || return 1
  case "$(pid_state "$1")" in ''|Z|X|x) return 1 ;; esac
}
reap_enter() {
  reap_start=$(pid_start "$$")
  [ -n "$reap_start" ] && printf '%s %s\n' "$$" "$reap_start" > "$WORK/reap-owner" || return 1
  mkdir "$REAP" 2>/dev/null && {
    mv "$WORK/reap-owner" "$REAP/owner" || { rmdir "$REAP" 2>/dev/null; return 1; }
    REAP_HELD=1
    return 0
  }
  read -r reap_pid reap_pid_start < "$REAP/owner" 2>/dev/null || reap_pid=
  if [ -n "$reap_pid" ] && owner_live "$reap_pid" "$reap_pid_start"; then return 1; fi
  if [ -z "$reap_pid" ]; then
    [ -d "$REAP" ] || return 1
    sleep 1
    [ -d "$REAP" ] && [ ! -e "$REAP/owner" ] || return 1
    rmdir "$REAP" 2>/dev/null || return 1
    return 1
  fi
  reap_before=$(cat "$REAP/owner" 2>/dev/null)
  sleep 1
  reap_after=$(cat "$REAP/owner" 2>/dev/null)
  if [ "$reap_before" = "$reap_after" ] && ! owner_live "$reap_pid" "$reap_pid_start"; then
    rm -f "$REAP/owner"; rmdir "$REAP" 2>/dev/null
  fi
  return 1
}
reap_leave() {
  [ "${REAP_HELD:-0}" = 1 ] || return 0
  if [ "$(cat "$REAP/owner" 2>/dev/null)" = "$$ $reap_start" ]; then rm -f "$REAP/owner"; rmdir "$REAP" 2>/dev/null; fi
  REAP_HELD=0
}
lock_acquire() {
  [ "$LOCK_HELD" = 0 ] || return 0
  LOCK=${1:-$BAK/api.lock}
  REAP=${2:-$LOCK.reap}
  internal_path "$LOCK" && internal_path "$REAP" || return 1
  internal_path "$BAK" || return 1
  mkdir -p "$BAK" || return 1
  START=$(pid_start "$$")
  [ -n "$START" ] && printf '%s %s\n' "$$" "$START" > "$WORK/lock-owner" || return 1
  if ! mkdir "$LOCK" 2>/dev/null; then
    read -r old_pid old_start < "$LOCK/owner" 2>/dev/null || old_pid=
    if [ -z "$old_pid" ]; then
      [ -d "$LOCK" ] || return 1
      sleep 1
      [ -d "$LOCK" ] && [ ! -e "$LOCK/owner" ] || return 1
      rmdir "$LOCK" 2>/dev/null || return 1
      mkdir "$LOCK" 2>/dev/null || return 1
    elif owner_live "$old_pid" "$old_start"; then return 1
    else
      reap_attempt=0
      until reap_enter; do reap_attempt=$((reap_attempt+1)); [ "$reap_attempt" -lt 3 ] || return 1; done
      current_owner=$(cat "$LOCK/owner" 2>/dev/null)
      if [ "$current_owner" = "$old_pid $old_start" ] && ! owner_live "$old_pid" "$old_start"; then
        rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null
      fi
      reap_leave
      mkdir "$LOCK" 2>/dev/null || return 1
    fi
  fi
  mv "$WORK/lock-owner" "$LOCK/owner" || { rmdir "$LOCK" 2>/dev/null; return 1; }
  LOCK_HELD=1
}
lock_release() {
  if [ "$LOCK_HELD" = 1 ] && [ "$(cat "$LOCK/owner" 2>/dev/null)" = "$$ $START" ]; then
    rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null
  fi
  LOCK_HELD=0
}
battery_lock() {
  [ "$BATTERY_HELD" = 0 ] || return 0
  internal_path "$MODDIR/battery/state" || return 1
  mkdir -p "$MODDIR/battery/state" || return 1
  saved_lock=$LOCK; saved_start=$START; saved_held=$LOCK_HELD; saved_reap=$REAP; saved_reap_held=${REAP_HELD:-0}; saved_reap_start=${reap_start:-}
  LOCK_HELD=0
  REAP_HELD=0
  battery_attempts=0; battery_rc=1
  while [ "$battery_attempts" -lt 5 ]; do
    if lock_acquire "$MODDIR/battery/state/.config-write.lock" "$MODDIR/battery/state/.config-write.reap"; then battery_rc=0; break; fi
    battery_attempts=$((battery_attempts+1)); sleep 1
  done
  if [ "$battery_rc" = 0 ]; then BATTERY_HELD=1; BATTERY_START=$START; fi
  LOCK=$saved_lock; START=$saved_start; LOCK_HELD=$saved_held; REAP=$saved_reap; REAP_HELD=$saved_reap_held; reap_start=$saved_reap_start
  return "$battery_rc"
}
battery_release() {
  [ "$BATTERY_HELD" = 1 ] || return 0
  battery_owner=$MODDIR/battery/state/.config-write.lock/owner
  if [ "$(cat "$battery_owner" 2>/dev/null)" = "$$ $BATTERY_START" ]; then
    rm -f "$battery_owner"; rmdir "${battery_owner%/*}" 2>/dev/null
  fi
  BATTERY_HELD=0
}
cleanup() {
  reap_leave
  battery_release
  lock_release
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    # WORK is always an internal mktemp directory, never a request path.
    find "$WORK" -depth -type f -exec rm -f {} \; 2>/dev/null
    find "$WORK" -depth -type d -exec rmdir {} \; 2>/dev/null
  fi
}

no_symlinks() {
  case "$1" in /*) ;; *) return 1 ;; esac
  check_path=; old_ifs=$IFS; IFS=/; set -f
  for part in $1; do
    [ -z "$part" ] && continue
    case "$part" in .|..) IFS=$old_ifs; set +f; return 1 ;; esac
    check_path=$check_path/$part
    [ ! -L "$check_path" ] || { IFS=$old_ifs; set +f; return 1; }
  done
  IFS=$old_ifs; set +f
}
external_path() {
  case "$1" in /sdcard|/sdcard/*) EXTERNAL=/storage/emulated/0${1#/sdcard} ;; /storage/emulated/0|/storage/emulated/0/*) EXTERNAL=$1 ;; *) return 1 ;; esac
  case "$EXTERNAL" in *[!A-Za-z0-9_./\ -]*|*//*|*/../*|*/..|*/./*|*/.) return 1 ;; esac
  no_symlinks "$EXTERNAL"
}
internal_path() { no_symlinks "$1"; }

atomic_file() {
  af_src=$1; af_dest=$2
  [ "$LOCK_HELD" = 1 ] && internal_path "$af_dest" || return 1
  [ ! -e "$af_dest" ] || [ -f "$af_dest" ] || return 1
  mkdir -p "${af_dest%/*}" || return 1
  af_tmp=$(mktemp "${af_dest%/*}/.api-write.XXXXXX") || return 1
  if ! cat "$af_src" > "$af_tmp" || ! cmp -s "$af_src" "$af_tmp"; then rm -f "$af_tmp"; return 1; fi
  chmod 0600 "$af_tmp" || { rm -f "$af_tmp"; return 1; }
  internal_path "$af_dest" && { [ ! -e "$af_dest" ] || [ -f "$af_dest" ]; } || { rm -f "$af_tmp"; return 1; }
  mv -f "$af_tmp" "$af_dest" || { rm -f "$af_tmp"; return 1; }
  cmp -s "$af_src" "$af_dest"
}
commit_config() {
  cc_rel=$1; cc_src=$2
  internal_path "$MODDIR/$cc_rel" && internal_path "$BAK/$cc_rel" || return 1
  [ ! -e "$MODDIR/$cc_rel" ] || [ -f "$MODDIR/$cc_rel" ] || return 1
  [ ! -e "$BAK/$cc_rel" ] || [ -f "$BAK/$cc_rel" ] || return 1
  cc_old=$(mktemp "$WORK/rollback.XXXXXXXXXX") || return 1
  cc_existed=0
  if [ -f "$MODDIR/$cc_rel" ]; then cc_existed=1; cp "$MODDIR/$cc_rel" "$cc_old" || return 1; fi
  atomic_file "$cc_src" "$MODDIR/$cc_rel" || return 1
  if ! atomic_file "$cc_src" "$BAK/$cc_rel"; then
    if [ "$cc_existed" = 1 ]; then atomic_file "$cc_old" "$MODDIR/$cc_rel" || return 1; else rm -f "$MODDIR/$cc_rel"; fi
    return 1
  fi
}
settings_prepare() {
  sp_src=$1; sp_out=$2
  if ! extract webui_defaults "$sp_src" > "$WORK/webui" 2>/dev/null; then
    if ! extract webui_defaults "$MODDIR/config/settings.json" > "$WORK/webui" 2>/dev/null; then
      extract webui_defaults "$MODDIR/default_settings.json" > "$WORK/webui" || return 1
    fi
    API_WEBUI=$(cat "$WORK/webui") LC_ALL=C awk -v check=add_webui -f "$JSON_AWK" -f "$API_DIR/validate.awk" "$sp_src" > "$WORK/settings.merged" || return 1
    sp_src=$WORK/settings.merged
  fi
  json_check settings "$sp_src" > "$sp_out"
}

profile_paths() {
  need_string target; target=$FIELD
  case "$target" in default) PROFILE=default.conf ;; current)
    model=$(getprop ro.product.model 2>/dev/null)
    case "$model" in ''|*[!A-Za-z0-9._\ -]*|.*) error '机型名称无效' ;; esac
    [ "${#model}" -le 64 ] || error '机型名称过长'
    PROFILE=$model.conf
    underscored=$(printf '%s' "$model" | tr ' ' '_').conf
    [ -f "$MODDIR/profiles/$underscored" ] && PROFILE=$underscored
    ;; *) error 'target 仅允许 current 或 default' ;; esac
  PROFILE_SOURCE=$MODDIR/profiles/$PROFILE
  [ -f "$PROFILE_SOURCE" ] || PROFILE_SOURCE=$MODDIR/profiles/default.conf
  internal_path "$PROFILE_SOURCE" || error '档案路径无效'
}
profile_json() {
  LC_ALL=C awk -F= '
  BEGIN{split("poll_interval foreground_interval bypass_current restart_cooldown lock_conf charge_node",a," ");d[1]=3;d[2]=10;d[3]=500000;d[4]=6;d[5]=1;d[6]=""}
  /^[A-Za-z_]+=/ {v[$1]=substr($0,index($0,"=")+1)}
  END{printf "{";for(i=1;i<=6;i++){x=(a[i] in v?v[a[i]]:d[i]);if(i>1)printf ",";if(i==6){if(x ~ /[^A-Za-z0-9_\/.]/)exit 2;printf "\"%s\":\"%s\"",a[i],x}else {if(x !~ /^[0-9]+$/)exit 2;printf "\"%s\":%s",a[i],x}}print "}"}' "$1"
}
profile_merge() {
  pm_source=$1; pm_values=$2; pm_out=$3
  awk -F= 'NR==FNR{v[$1]=substr($0,index($0,"=")+1);next} {k=$1;if(k in v){if(!seen[k]++)print k "=" v[k]}else print} END{for(k in v)if(!seen[k])print k "=" v[k]}' "$pm_values" "$pm_source" > "$pm_out"
}
