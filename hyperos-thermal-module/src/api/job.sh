#!/system/bin/sh
job_state() {
  js_status=$1; js_code=$2
  printf '{"jobId":"%s","status":"%s","output":' "$JOB_ID" "$js_status" > "$JOB/state.tmp.$$" || return 1
  if [ -f "$JOB/output.log" ]; then tail -c 262144 "$JOB/output.log" | json_quote >> "$JOB/state.tmp.$$"; else printf '""' >> "$JOB/state.tmp.$$"; fi
  printf ',"exitCode":%s}\n' "$js_code" >> "$JOB/state.tmp.$$"
  mv -f "$JOB/state.tmp.$$" "$JOB/state.json"
}
job_start() {
  internal_path "$JOBS" || error '任务目录包含链接'
  mkdir -p "$JOBS" || error '无法准备任务目录'
  JOB=$(mktemp -d "$JOBS/jXXXXXXXXXX") || error '无法创建任务'
  mkdir "$JOB/runtime" || error '无法准备任务程序'
  for runtime_file in job.sh config_io.sh backup.sh json.awk validate.awk conf_check.awk tar_check.awk runtime_merge.awk; do
    cp "$API_DIR/$runtime_file" "$JOB/runtime/$runtime_file" || error '无法复制任务程序'
  done
  JOB_ID=${JOB##*/}
  cp "$REQ" "$JOB/request.json" || error '无法保存任务请求'
  printf '%s\n' "$1" > "$JOB/action"
  : > "$JOB/output.log"
  job_state queued null || error '无法保存任务状态'
  # All descriptors are detached; the RPC returns without waiting for the worker.
  XJ_BAK=$BAK nohup sh "$JOB/runtime/job.sh" "$MODDIR" "$JOB_ID" </dev/null >/dev/null 2>&1 &
  worker=$!
  printf '%s %s\n' "$worker" "$(pid_start "$worker")" > "$JOB/worker.tmp.$$"
  mv "$JOB/worker.tmp.$$" "$JOB/worker"
  cat "$JOB/state.json"
}
job_get() {
  need_string jobId
  case "$FIELD" in j??????????) case "$FIELD" in *[!A-Za-z0-9]*) error '任务 ID 无效' ;; esac ;; *) error '任务 ID 无效' ;; esac
  JOB_ID=$FIELD; JOB=$JOBS/$JOB_ID
  [ -f "$JOB/state.json" ] && internal_path "$JOB/state.json" || error '任务不存在' 4
  internal_path "$JOB/output.log" && internal_path "$JOB/worker" || error '任务记录包含链接'
  state=$(cat "$JOB/state.json")
  status=$(printf '%s' "$state" | LC_ALL=C awk -v check=raw -v path=status -f "$JSON_AWK" -f "$API_DIR/validate.awk" 2>/dev/null)
  code=$(printf '%s' "$state" | LC_ALL=C awk -v check=extract -v path=exitCode -f "$JSON_AWK" -f "$API_DIR/validate.awk")
  case "$status" in running|queued)
    read -r worker worker_start < "$JOB/worker" 2>/dev/null || worker=
    if [ -z "$worker" ]; then
      sleep 1
      read -r worker worker_start < "$JOB/worker" 2>/dev/null || worker=
    fi
    if ! owner_live "$worker" "$worker_start"; then
      state=$(cat "$JOB/state.json")
      status=$(printf '%s' "$state" | LC_ALL=C awk -v check=raw -v path=status -f "$JSON_AWK" -f "$API_DIR/validate.awk" 2>/dev/null)
      code=$(printf '%s' "$state" | LC_ALL=C awk -v check=extract -v path=exitCode -f "$JSON_AWK" -f "$API_DIR/validate.awk")
      case "$status" in running|queued) status=failed; code=125 ;; esac
    fi
    ;;
  esac
  status=$(printf '%s' "$status" | json_quote)
  printf '{"jobId":"%s","status":%s,"output":' "$JOB_ID" "$status"
  tail -c 262144 "$JOB/output.log" | json_quote
  printf ',"exitCode":%s}\n' "$code"
}
job_finish() {
  finish_rc=$?
  trap - EXIT HUP INT TERM
  [ "$finish_rc" = 0 ] && finish_status=succeeded || finish_status=failed
  if [ "$LOCK_HELD" = 0 ]; then
    attempts=0
    until lock_acquire; do attempts=$((attempts+1)); [ "$attempts" -lt 10 ] || break; sleep 1; done
  fi
  [ "$LOCK_HELD" = 1 ] && job_state "$finish_status" "$finish_rc"
  cleanup
  exit "$finish_rc"
}

if [ "${0##*/}" = job.sh ] && [ "${1:-}" = --get ]; then
  case "${2:-}" in j??????????) case "$2" in *[!A-Za-z0-9]*) exit 3 ;; esac ;; *) exit 3 ;; esac
  API_DIR=$(CDPATH= cd -- "${0%/*}" && pwd -P) || exit 1
  XJ_BAK=$(CDPATH= cd -- "$API_DIR/../../.." && pwd -P) || exit 1
  . "$API_DIR/config_io.sh"
  MODDIR=/data/adb/modules/HyperOS_XJ
  WORK=$(mktemp -d "$JOBS/.query.XXXXXXXXXX") || exit 1
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  REQ=$WORK/request.json
  printf '{"jobId":"%s"}\n' "$2" > "$REQ"
  job_get
  exit $?
fi

if [ "${0##*/}" = job.sh ]; then
  MODDIR=$1; JOB_ID=$2
  API_DIR=${0%/*}
  . "$API_DIR/config_io.sh"
  . "$API_DIR/backup.sh"
  JOB=$JOBS/$JOB_ID
  REQ=$JOB/request.json
  WORK=$(mktemp -d "$JOB/work.XXXXXXXXXX") || exit 1
  trap job_finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  attempts=0
  until lock_acquire; do attempts=$((attempts+1)); [ "$attempts" -lt 30 ] || exit 6; sleep 1; done
  job_state running null || exit 1
  read -r action < "$JOB/action" || exit 1
  case "$action" in
    diagnose|dtbo_flash|uninstall)
      lock_acquire || { printf 'API 正忙\n' >> "$JOB/output.log"; exit 6; }
      case "$action" in
        diagnose) sh "$MODDIR/diagnose.sh" >> "$JOB/output.log" 2>&1 ;;
        dtbo_flash) sh "$MODDIR/battery/scripts/dtbo.sh" flashlocal >> "$JOB/output.log" 2>&1 ;;
        uninstall) sh "$MODDIR/uninstall.sh" >> "$JOB/output.log" 2>&1 ;;
      esac
      exit $? ;;
    backup.full.export) full_export >> "$JOB/output.log" 2>&1; exit $? ;;
    backup.full.restore) full_restore >> "$JOB/output.log" 2>&1; exit $? ;;
    *) exit 3 ;;
  esac
fi
