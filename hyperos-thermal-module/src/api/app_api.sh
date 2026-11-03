#!/system/bin/sh
MODDIR=$(CDPATH= cd -- "${0%/*}/.." 2>/dev/null && pwd -P) || exit 1
API_DIR=$MODDIR/api
XBT=$MODDIR/battery
. "$API_DIR/config_io.sh"
. "$API_DIR/job.sh"
OP=${1:-}
[ "$#" -le 2 ] || error '参数过多'
PAYLOAD=${2:-}
[ "${#PAYLOAD}" -le 1400000 ] || error '请求过大'
internal_path "$MODDIR/run" || error 'API 目录包含链接'
mkdir -p "$MODDIR/run" || error '无法准备 API 目录'
WORK=$(mktemp -d "$MODDIR/run/request.XXXXXXXXXX") || error '无法准备请求'
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
REQ=$WORK/request.json
if [ -n "${2:-}" ]; then
  case "$2" in *[!A-Za-z0-9+/=]*) error '请求编码错误' 2 ;; esac
  printf '%s' "$2" | base64 -d > "$REQ" 2>/dev/null || error '请求编码错误' 2
  # A round trip also rejects ignored garbage, bad padding, and noncanonical input.
  encoded=$(base64 < "$REQ" | tr -d '\r\n')
  [ "$encoded" = "$2" ] || error '请求编码错误' 2
else printf '{}\n' > "$REQ"; fi
json_check object "$REQ" > "$WORK/canonical" 2>/dev/null || error '请求必须是有效 JSON 对象' 2
mv "$WORK/canonical" "$REQ" || error '请求初始化失败'

case "$OP" in
  settings.save|rear.settings.save|battery.setting.set|battery.power|battery.apl|battery.unlock|battery.pps|battery.cloud|battery.cycle|battery.voltage.start|battery.voltage.stop|battery.voltage.restore|battery.rearscreen|bypass.set|thermal.apply|hyperspeed.set|notice.seen|logs.append|logs.export|profile.save|backup.run|backup.ui.export|backup.full.export|backup.full.restore|action.run)
    lock_acquire || error 'API 正忙，请稍后重试' 6 ;;
esac

run_script() {
  script=$1; shift
  sh "$script" "$@" > "$WORK/script.out" 2>&1
  script_rc=$?
  printf '{"output":'; cat "$WORK/script.out" | json_quote; printf ',"exitCode":%s}\n' "$script_rc"
  return "$script_rc"
}
battery_key() {
  need_string key; key=$FIELD
  case "$key" in power_limit|unlock|freepps|cloud_guard|apl_enable|fv_v|term_v|fv_force|cycle_fake|pss_disable|rearscreen) ;; *) error '未授权配置键' ;; esac
}
battery_value() {
  need value; value=$FIELD
  case "$key" in
    power_limit) case "$value" in inf|fast|mid|slow) ;; *) error '无效功率档' ;; esac ;;
    unlock|freepps|cloud_guard|apl_enable|fv_force|pss_disable|rearscreen)
      case "$value" in true) value=1 ;; false) value=0 ;; 0|1) ;; *) error '无效开关值' ;; esac ;;
    fv_v) [ -z "$value" ] || uint "$value" 4300 4700 || error '满电电压范围为 4300..4700' ;;
    term_v) [ -z "$value" ] || uint "$value" 2800 3500 || error '关机电压范围为 2800..3500' ;;
    cycle_fake) [ -z "$value" ] || uint "$value" 0 20000 || error '循环次数范围为 0..20000' ;;
  esac
}
battery_read() {
  case "$key" in unlock|cloud_guard|pss_disable) default=1 ;; freepps|apl_enable|fv_force|rearscreen) default=0 ;; power_limit) default=inf ;; *) default= ;; esac
  value=$(awk -F= -v key="$key" '$1==key{v=substr($0,index($0,"=")+1)} END{printf "%s",v}' "$XBT/config/settings.conf" 2>/dev/null)
  [ -n "$value" ] || value=$default
  printf '{"key":"%s","value":' "$key"; printf '%s' "$value" | json_quote; printf '}\n'
}
read_log() {
  LOG=$MODDIR/log/core.log
  [ -s "$LOG" ] || LOG=$MODDIR/切换log.log
  [ -s "$LOG" ] || LOG=$MODDIR/config/core.log
  internal_path "$LOG" || error '日志路径包含链接'
  [ -f "$LOG" ] && tail -c 262144 "$LOG" || :
}
ui_content() {
  extract content "$REQ" > "$WORK/content" 2>/dev/null || error '缺少 content'
  if [ "$(field_type content)" = string ]; then
    LC_ALL=C awk -v check=text -v path=content -f "$JSON_AWK" -f "$API_DIR/validate.awk" "$REQ" > "$WORK/content" || error 'UI 内容无效'
  fi
  json_check ui "$WORK/content" > "$WORK/ui.valid" 2>/dev/null || error 'UI 内容必须是大小不超过 512KiB 的 JSON 对象'
}

case "$OP" in
  snapshot)
    request_keys ''
    [ -s "$MODDIR/run/snapshot.json" ] || error '快照尚未生成' 4
    cat "$MODDIR/run/snapshot.json" ;;
  settings.get) request_keys ''; [ -f "$MODDIR/config/settings.json" ] || error '设置文件不存在' 4; cat "$MODDIR/config/settings.json" ;;
  settings.save)
    request_keys settings
    extract settings "$REQ" > "$WORK/settings" 2>/dev/null || error '缺少完整 settings 对象'
    settings_prepare "$WORK/settings" "$WORK/settings.valid" 2>/dev/null || error 'settings schema2 校验失败'
    commit_config config/settings.json "$WORK/settings.valid" || error '设置提交或外备份失败' 8
    cat "$MODDIR/config/settings.json" ;;
  battery.setting.get) request_keys key; battery_key; battery_read ;;
  battery.setting.set)
    request_keys 'key value'; battery_key; battery_value
    sh "$XBT/scripts/cfg_cli.sh" set "$key" "$value" > "$WORK/script.out" 2>&1; rc=$?
    [ "$rc" = 0 ] || { printf '{"error":'; cat "$WORK/script.out" | json_quote; printf '}\n'; exit "$rc"; }
    battery_read ;;
  battery.power)
    request_keys mode; need_string mode
    case "$FIELD" in inf|fast|mid|slow) run_script "$XBT/scripts/power_limit.sh" set "$FIELD" ;; *) error '无效功率档' ;; esac ;;
  battery.apl) request_keys enabled; need_bool enabled; run_script "$XBT/scripts/apl_toggle.sh" "$FIELD" ;;
  battery.unlock|battery.pps|battery.cloud)
    request_keys enabled; need_bool enabled
    [ "$FIELD" = 1 ] && arg=on || arg=off
    case "$OP" in battery.unlock) script=unlock.sh ;; battery.pps) script=freepps.sh ;; battery.cloud) script=cloud_guard.sh ;; esac
    run_script "$XBT/scripts/$script" "$arg" ;;
  battery.cycle)
    request_keys 'clear count'
    clear=$(field clear 2>/dev/null)
    if [ "$clear" = true ]; then [ "$(field_type clear)" = bool ] || error 'clear 必须是布尔值'; run_script "$XBT/scripts/unlock.sh" cycle clear
    else [ -z "$clear" ] || [ "$clear" = false ] || error 'clear 必须是布尔值'; need count; uint "$FIELD" 0 20000 || error '循环次数无效'; run_script "$XBT/scripts/unlock.sh" cycle "$FIELD"; fi ;;
  battery.voltage.start) request_keys ''; run_script "$XBT/scripts/volt_guard.sh" start ;;
  battery.voltage.stop) request_keys ''; run_script "$XBT/scripts/volt_guard.sh" stop ;;
  battery.voltage.restore) request_keys ''; run_script "$XBT/scripts/volt_guard.sh" restore_force ;;
  battery.rearscreen)
    request_keys enabled; need_bool enabled; enabled=$FIELD
    if [ -f "$MODDIR/config/rearscreen.json" ]; then cp "$MODDIR/config/rearscreen.json" "$WORK/rear.base"
    else printf '%s\n' '{"enabled":false,"fields":["temp","soc","volt","power"],"accent":"78,161,255","theme":"aurora","font_scale":1}' > "$WORK/rear.base"; fi
    LC_ALL=C awk -v enabled="$enabled" -f "$JSON_AWK" -f "$API_DIR/rear_toggle.awk" "$WORK/rear.base" > "$WORK/rear" || error '背屏配置无效'
    json_check rear "$WORK/rear" > "$WORK/rear.valid" || error '背屏配置无效'
    commit_config config/rearscreen.json "$WORK/rear.valid" || error '背屏配置保存失败'
    run_script "$XBT/scripts/cfg_cli.sh" set rearscreen "$enabled" ;;
  rear.settings.get)
    request_keys ''
    if [ -f "$MODDIR/config/rearscreen.json" ]; then cat "$MODDIR/config/rearscreen.json"
    else printf '%s\n' '{"enabled":false,"fields":["temp","soc","volt","power"],"accent":"78,161,255","theme":"aurora","font_scale":1}'; fi ;;
  rear.settings.save)
    request_keys 'enabled fields accent theme font_scale'
    json_check rear "$REQ" > "$WORK/rear.valid" 2>/dev/null || error '背屏配置校验失败'
    commit_config config/rearscreen.json "$WORK/rear.valid" || error '背屏配置保存或外备份失败'
    cat "$MODDIR/config/rearscreen.json" ;;
  bypass.get)
    request_keys ''; enabled=$(cat "$MODDIR/config/bypass_manual" 2>/dev/null); [ "$enabled" = 1 ] && enabled=true || enabled=false; printf '{"enabled":%s}\n' "$enabled" ;;
  bypass.set)
    request_keys enabled; need_bool enabled; printf '%s\n' "$FIELD" > "$WORK/bypass"
    commit_config config/bypass_manual "$WORK/bypass" || error '旁路设置保存失败'; printf '{"enabled":%s}\n' "$([ "$FIELD" = 1 ] && printf true || printf false)" ;;
  thermal.apply) request_keys ''; run_script "$MODDIR/thermal_core.sh" "$MODDIR" apply ;;
  hyperspeed.set)
    request_keys enabled; need_bool enabled
    [ "$FIELD" = 1 ] && script=HyperOS-yes || script=HyperOS-off
    run_script "$MODDIR/HyperOS/$script" ;;
  device.runtime)
    request_keys ''
    [ -f "$MODDIR/config/runtime.json" ] && json_check object "$MODDIR/config/runtime.json" > "$WORK/runtime" || printf '{}\n' > "$WORK/runtime"
    RUNTIME_VALUE=$(getprop persist.vendor.high_temp_stop_charge 2>/dev/null); export RUNTIME_VALUE
    awk -f "$API_DIR/json.awk" -f "$API_DIR/runtime_merge.awk" "$WORK/runtime" || error '运行态数据无效' ;;
  device.os)
    request_keys ''; printf '{'
    comma=
    for entry in android:ro.build.version.release hyperos:ro.mi.os.version.name incremental:ro.mi.os.version.incremental code:ro.build.version.sdk miui:ro.miui.ui.version.name; do
      name=${entry%%:*}; prop=${entry#*:}
      printf '%s"%s":' "$comma" "$name"; getprop "$prop" 2>/dev/null | json_quote; comma=,
    done
    printf '}\n' ;;
  device.root)
    request_keys ''; printf '{"uid":%s,"name":' "$(id -u)"
    manager=unknown; root_version=
    [ -d /data/adb/ksu ] && manager=KernelSU
    [ -d /data/adb/ap ] && manager=APatch
    if command -v magisk >/dev/null 2>&1; then manager=Magisk; root_version=$(magisk -v 2>/dev/null); fi
    if [ "$manager" = KernelSU ] && [ -x /data/adb/ksud ]; then root_version=$(/data/adb/ksud -V 2>/dev/null); fi
    if [ "$manager" = APatch ] && [ -x /data/adb/apd ]; then root_version=$(/data/adb/apd -V 2>/dev/null); fi
    printf '%s' "$manager" | json_quote; printf ',"version":'; printf '%s' "$root_version" | json_quote; printf '}\n' ;;
  module.info)
    request_keys ''; printf '{'; comma=
    for key in id name version versionCode author description; do
      val=$(awk -F= -v key="$key" '$1==key{print substr($0,index($0,"=")+1);exit}' "$MODDIR/module.prop")
      printf '%s"%s":' "$comma" "$key"; printf '%s' "$val" | json_quote; comma=,
    done; printf '}\n' ;;
  module.changelog) request_keys ''; printf '{"content":'; cat "$MODDIR/更新日志.log" 2>/dev/null | json_quote; printf '}\n' ;;
  notice.get)
    request_keys ''; version=$(awk -F= '$1=="versionCode"{print $2;exit}' "$MODDIR/module.prop"); seen=$(cat "$MODDIR/config/.notice_seen" 2>/dev/null)
    printf '{"versionCode":'; printf '%s' "$version" | json_quote; printf ',"seen":'; printf '%s' "$seen" | json_quote; printf '}\n' ;;
  notice.seen)
    request_keys ''; awk -F= '$1=="versionCode"{print $2;exit}' "$MODDIR/module.prop" > "$WORK/notice"
    commit_config config/.notice_seen "$WORK/notice" || error '欢迎页状态保存失败'; printf '{"seen":true}\n' ;;
  logs.read) request_keys ''; printf '{"output":'; read_log | json_quote; printf '}\n' ;;
  logs.append)
    request_keys text; need_string text; [ "${#FIELD}" -le 4096 ] || error '日志过长'
    internal_path "$MODDIR/log/core.log" || error '日志路径包含链接'
    mkdir -p "$MODDIR/log" || error '无法准备日志目录'
    printf '%s [APP] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$FIELD" >> "$MODDIR/log/core.log" || error '日志写入失败'; printf '{"ok":true}\n' ;;
  logs.export)
    request_keys directory; need_string directory; external_path "$FIELD" || error '导出目录无效'; directory=$EXTERNAL
    mkdir -p "$directory" || error '无法创建导出目录'; read_log > "$WORK/log"
    destination=$directory/HyperOS_XJ_log_$(date +%Y%m%d_%H%M%S)_$$.txt
    atomic_file "$WORK/log" "$destination" || error '日志导出失败'; printf '{"path":'; printf '%s' "$destination" | json_quote; printf '}\n' ;;
  profile.load|profile.summary)
    request_keys target; profile_paths
    profile_json "$PROFILE_SOURCE" > "$WORK/profile" || error '档案内容无效'
    json_check profile "$WORK/profile" > "$WORK/profile.valid" || error '档案参数校验失败'
    printf '{"target":'; printf '%s' "$target" | json_quote; printf ',"name":'; printf '%s' "$PROFILE" | json_quote; printf ',"settings":'
    cat "$WORK/profile.valid"
    if [ "$OP" = profile.load ]; then
      printf ',"path":'; printf '%s' "$MODDIR/profiles/$PROFILE" | json_quote
      [ -f "$MODDIR/profiles/$PROFILE" ] && is_new=false || is_new=true
      printf ',"isNew":%s' "$is_new"
    fi
    printf '}\n' ;;
  profile.save)
    request_keys 'target settings'; profile_paths
    extract settings "$REQ" > "$WORK/profile" 2>/dev/null || error '缺少档案 settings'
    json_check profile "$WORK/profile" > "$WORK/profile.valid" 2>/dev/null || error '档案六键校验失败'
    LC_ALL=C awk -f "$JSON_AWK" -f "$API_DIR/profile_values.awk" "$WORK/profile.valid" > "$WORK/values" || error '档案参数无效'
    profile_merge "$PROFILE_SOURCE" "$WORK/values" "$WORK/profile.conf" || error '档案生成失败'
    commit_config "profiles/$PROFILE" "$WORK/profile.conf" || error '档案保存失败'; cat "$WORK/profile.valid" ;;
  backup.run)
    request_keys ''; battery_lock || error '电池配置正忙' 6
    export MODDIR; XJ_BAK=$BAK; export XJ_BAK; run_script "$MODDIR/config_backup.sh" ;;
  backup.ui.export)
    request_keys 'directory content'; need_string directory; external_path "$FIELD" || error '备份目录无效'; directory=$EXTERNAL
    ui_content
    mkdir -p "$directory" || error '无法创建导出目录'
    destination=$directory/HyperOS_XJ_ui_$(date +%Y%m%d_%H%M%S)_$$.json
    atomic_file "$WORK/ui.valid" "$destination" || error 'UI 备份导出失败'
    commit_config ui/ui-settings.json "$WORK/ui.valid" || error 'UI 设置外备份失败'
    printf '{"path":'; printf '%s' "$destination" | json_quote; printf '}\n' ;;
  backup.full.export)
    request_keys 'directory content'; need_string directory; external_path "$FIELD" || error '备份目录无效'; if field_type content >/dev/null 2>&1; then ui_content; fi
    job_start backup.full.export ;;
  backup.full.restore)
    request_keys path; need_string path; external_path "$FIELD" || error '备份路径无效'; job_start backup.full.restore ;;
  action.run)
    request_keys id; need_string id
    case "$FIELD" in diagnose|dtbo_flash|uninstall) job_start "$FIELD" ;; *) error '未授权任务' ;; esac ;;
  job.get) request_keys jobId; job_get ;;
  *) error '未授权操作' ;;
esac
