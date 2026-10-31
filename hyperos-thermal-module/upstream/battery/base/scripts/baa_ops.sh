#!/system/bin/sh
# BAA 挂载控制（自动进入 PID1 mount namespace 执行）
# 用法: baa_ops.sh mount|umount|check

XBT=/data/adb/modules/battery_tune

if [ "${XBT_IN_PID1:-0}" != "1" ]; then
  # 优先进入 PID1 mount namespace —— 只有 init 及其子进程才能"看到"这里的 bind mount。
  # 若设备缺少 nsenter（部分精简/魔改 ROM），退化为在当前命名空间挂载（尽力而为），
  # 并设置 XBT_NO_NSENTER 以便 mount 分支记录诊断信息。
  for _ns in /system/bin/nsenter /system/xbin/nsenter \
             /data/adb/ksu/bin/nsenter /data/adb/magisk/nsenter; do
    if [ -x "$_ns" ]; then
      exec "$_ns" -t 1 -m -- /system/bin/env XBT_IN_PID1=1 /system/bin/sh "$0" "$@"
    fi
  done
  export XBT_IN_PID1=1 XBT_NO_NSENTER=1
fi

. $XBT/scripts/common.sh

MODE="$1"

case "$MODE" in
  mount)
    [ "$XBT_NO_NSENTER" = "1" ] && log "baa_ops: WARN nsenter not found, mounting in current namespace"
    [ -f "$BAA_SRC" ] || { log "baa_ops: src missing ($BAA_SRC)"; exit 1; }
    [ -f "$BAA_TGT" ] || { log "baa_ops: target missing ($BAA_TGT not present / odm not mounted?)"; exit 2; }
    # 空文件防护（魔改包会把 BAA 掏空）：源/目标为空则不挂载——不把系统配置挂成空、也不做无意义覆盖
    _ssz=$(stat -c %s "$BAA_SRC" 2>/dev/null)
    case "$_ssz" in ''|*[!0-9]*) _ssz=0 ;; esac
    if [ "$_ssz" -le 8 ]; then
      log "baa_ops: src empty (${_ssz}B) -> skip mount (protect target)"
      exit 1
    fi
    _tsz=$(stat -c %s "$BAA_TGT" 2>/dev/null)
    case "$_tsz" in ''|*[!0-9]*) _tsz=0 ;; esac
    if [ "$_tsz" -le 8 ]; then
      # ===== v3.9.9【修 bug】旧行为：目标为空就 exit 0 跳过挂载 =====
      # 【实测故障】annibale / haotian 两台 15 系列，用户刷的是「官改/魔改包」，
      #   /odm/etc/charger/BAA_config_<dev>.json 被掏空成 1 字节。
      #   模块判定「系统BAA为空」→ 跳过挂载 → 系统无 BAA 配置 →
      #   驱动回落到内置兜底阶梯 → charge_interface 出现
      #      ichg_limit = buck eff_client:volt_thermal_limit 4500  (4.5A)
      #      iin_limit  = buck eff_client:volt_limit 3000          (3A)
      #   ⇒ 4.5A × 4.34V ≈ 19.5W，正好是用户反馈的「60% 后掉到 20W、67% 后锁死」。
      # 【为什么旧行为是错的】「不干预」在系统本来就有配置时是保守正确的；
      #   但系统配置为空时，「不干预」= 让驱动用兜底限流，反而更差。
      #   空文件的语义是「这台 ROM 没有 BAA 约束」，写入我们的解容配置是纯增益。
      # 【新行为】仍然挂载，只是额外记一条日志便于排障。
      log "baa_ops: target is EMPTY (${_tsz}B, ROM BAA-less) -> mounting module BAA anyway (v3.9.9: empty target means no system constraint, our config is a strict improvement)"
    fi
    if grep -F " $BAA_TGT " /proc/mounts >/dev/null 2>&1; then
      umount "$BAA_TGT" 2>>"$LOG"
    fi
    _org=$(stat -c '%C' "$BAA_TGT" 2>/dev/null)
    _use="${_org:-$BAA_LABEL}"
    chcon "$_use" "$BAA_SRC" 2>>"$LOG"
    chmod 0644 "$BAA_SRC" 2>>"$LOG"
    if mount -o bind "$BAA_SRC" "$BAA_TGT" 2>>"$LOG"; then
      _s=$(hash_of "$BAA_SRC"); _t=$(hash_of "$BAA_TGT"); _l=$(stat -c '%C' "$BAA_TGT" 2>/dev/null)
      if [ "$_s" = "$_t" ] && [ "$_l" = "$_use" ]; then
        log "baa_ops: mount OK (sha256+label verified)"
        exit 0
      else
        umount "$BAA_TGT" 2>>"$LOG"
        log "baa_ops: mount verify FAILED, rolled back"
        exit 3
      fi
    else
      log "baa_ops: mount FAILED"
      exit 4
    fi
    ;;
  umount)
    if grep -F " $BAA_TGT " /proc/mounts >/dev/null 2>&1; then
      umount "$BAA_TGT" 2>>"$LOG" && log "baa_ops: umounted" || log "baa_ops: umount failed"
    else
      log "baa_ops: umount no-op (not mounted)"
    fi
    exit 0
    ;;
  check)
    baa_state
    ;;
  *)
    echo "usage: $0 mount|umount|check"; exit 9
    ;;
esac