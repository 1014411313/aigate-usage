#!/system/bin/sh
# Perf Tuner 核心逻辑，由 service.sh / action.sh / customize.sh / WebUI 共用。
# 调用方需先设置 MODDIR 指向模块目录。
MODDIR=${MODDIR:-${0%/*}}

CONFIG_DIR=/data/adb/perf_tuner
PROFILE_FILE=$CONFIG_DIR/profile
DEFAULTS_FILE=$CONFIG_DIR/defaults

PROFILES="powersave balanced performance"

GOVERNOR_PATHS="/sys/devices/system/cpu/cpufreq/policy*/scaling_governor /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
READ_AHEAD_PATHS="/sys/block/*/queue/read_ahead_kb"
SCHEDULER_PATHS="/sys/block/*/queue/scheduler"
VM_DIR=/proc/sys/vm
VM_PATHS="$VM_DIR/swappiness $VM_DIR/vfs_cache_pressure $VM_DIR/dirty_ratio $VM_DIR/dirty_background_ratio"

say() {
  if command -v ui_print >/dev/null 2>&1; then
    ui_print "$*"
  else
    echo "$*"
  fi
}

write_file() {
  [ -w "$1" ] || return 1
  printf '%s\n' "$2" >"$1" 2>/dev/null
}

block_devices() {
  for dev in /sys/block/*; do
    case "${dev##*/}" in
      loop* | ram* | zram* | sr* | md*) continue ;;
    esac
    echo "$dev"
  done
}

tunable_paths() {
  for pattern in $VM_PATHS $GOVERNOR_PATHS $READ_AHEAD_PATHS $SCHEDULER_PATHS; do
    for path in $pattern; do
      [ -e "$path" ] && echo "$path"
    done
  done
}

# 首次生效前记录设备原始取值，供 reset 与卸载时还原
snapshot_defaults() {
  [ -f "$DEFAULTS_FILE" ] && return 0
  mkdir -p "$CONFIG_DIR"
  : >"$DEFAULTS_FILE"
  for path in $(tunable_paths); do
    [ -r "$path" ] || continue
    value=$(cat "$path" 2>/dev/null)
    # scheduler 的当前值带方括号，还原时需要裸名称
    if [ "${path##*/}" = "scheduler" ]; then
      value=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$path" 2>/dev/null)
    fi
    [ -n "$value" ] && printf '%s|%s\n' "$path" "$value" >>"$DEFAULTS_FILE"
  done
}

restore_defaults() {
  [ -f "$DEFAULTS_FILE" ] || return 0
  while IFS='|' read -r path value; do
    [ -n "$path" ] || continue
    write_file "$path" "$value"
  done <"$DEFAULTS_FILE"
}

set_governor() {
  for path in $GOVERNOR_PATHS; do
    [ -w "$path" ] || continue
    available=$(cat "${path%/*}/scaling_available_governors" 2>/dev/null)
    [ -n "$available" ] || available=$(cat "$path" 2>/dev/null)
    for want in $1; do
      case " $available " in
        *" $want "*)
          write_file "$path" "$want"
          break
          ;;
      esac
    done
  done
}

set_scheduler() {
  for dev in $(block_devices); do
    path=$dev/queue/scheduler
    [ -w "$path" ] || continue
    available=$(tr -d '[]' <"$path" 2>/dev/null)
    for want in $1; do
      case " $available " in
        *" $want "*)
          write_file "$path" "$want"
          break
          ;;
      esac
    done
  done
}

set_read_ahead() {
  for dev in $(block_devices); do
    write_file "$dev/queue/read_ahead_kb" "$1"
  done
}

apply_profile() {
  case "$1" in
    powersave)
      governor="powersave schedutil conservative"
      scheduler="kyber mq-deadline cfq bfq none"
      read_ahead=128
      swappiness=60
      vfs_cache_pressure=200
      dirty_ratio=20
      dirty_background_ratio=10
      ;;
    balanced)
      governor="schedutil interactive ondemand conservative"
      scheduler="cfq mq-deadline kyber bfq none"
      read_ahead=512
      swappiness=100
      vfs_cache_pressure=100
      dirty_ratio=20
      dirty_background_ratio=5
      ;;
    performance)
      governor="performance schedutil"
      scheduler="none mq-deadline kyber cfq"
      read_ahead=2048
      swappiness=60
      vfs_cache_pressure=50
      dirty_ratio=40
      dirty_background_ratio=10
      ;;
    *)
      return 1
      ;;
  esac

  set_governor "$governor"
  set_scheduler "$scheduler"
  set_read_ahead "$read_ahead"
  write_file "$VM_DIR/swappiness" "$swappiness"
  write_file "$VM_DIR/vfs_cache_pressure" "$vfs_cache_pressure"
  write_file "$VM_DIR/dirty_ratio" "$dirty_ratio"
  write_file "$VM_DIR/dirty_background_ratio" "$dirty_background_ratio"
}

current_profile() {
  if [ -r "$PROFILE_FILE" ]; then
    cat "$PROFILE_FILE"
  else
    echo default
  fi
}

next_profile() {
  case "$1" in
    powersave) echo balanced ;;
    balanced) echo performance ;;
    performance) echo powersave ;;
    *) echo balanced ;;
  esac
}

is_profile() {
  case " $PROFILES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

apply() {
  profile=$1
  if ! is_profile "$profile"; then
    echo "未知方案：$profile（可用：$PROFILES）"
    return 1
  fi
  mkdir -p "$CONFIG_DIR"
  snapshot_defaults
  apply_profile "$profile" || return 1
  printf '%s\n' "$profile" >"$PROFILE_FILE"
  say "已应用 $profile 方案"
}

reset() {
  restore_defaults
  mkdir -p "$CONFIG_DIR"
  printf 'default\n' >"$PROFILE_FILE"
  say "已恢复设备原始取值"
}

status() {
  echo "当前方案：$(current_profile)"
  for path in $VM_PATHS; do
    [ -r "$path" ] || continue
    printf '%s = %s\n' "${path##*/}" "$(cat "$path" 2>/dev/null)"
  done
  for path in $GOVERNOR_PATHS; do
    [ -r "$path" ] || continue
    printf '%s = %s\n' "${path%/*}" "$(cat "$path" 2>/dev/null)"
    break
  done
  for dev in $(block_devices); do
    [ -r "$dev/queue/read_ahead_kb" ] || continue
    printf '%s read_ahead_kb = %s\n' "${dev##*/}" "$(cat "$dev/queue/read_ahead_kb" 2>/dev/null)"
  done
}

# 音量键选择方案：音量下键切换，音量上键确认，超时保留初始方案。
# 结果写入全局变量 SELECTED_PROFILE（不用 stdout，避免污染调用方输出）。
select_profile() {
  limit=${1:-15}
  SELECTED_PROFILE=$2
  if ! is_profile "$SELECTED_PROFILE"; then
    SELECTED_PROFILE=balanced
  fi

  if ! command -v getevent >/dev/null 2>&1; then
    say "未找到 getevent，使用 $SELECTED_PROFILE 方案"
    return 0
  fi

  say "音量下键：切换方案，音量上键：确认（${limit} 秒后使用 $SELECTED_PROFILE）"
  say "当前选择：$SELECTED_PROFILE"
  deadline=$(($(date +%s) + limit))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    event=$(timeout 1 getevent -qlc 1 2>/dev/null)
    case "$event" in
      *KEY_VOLUMEUP*DOWN*)
        break
        ;;
      *KEY_VOLUMEDOWN*DOWN*)
        SELECTED_PROFILE=$(next_profile "$SELECTED_PROFILE")
        say "当前选择：$SELECTED_PROFILE"
        ;;
    esac
  done
}
