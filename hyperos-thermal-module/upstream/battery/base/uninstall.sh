#!/system/bin/sh
# 电池解容工具箱 - 卸载清理（v2.6.22 还原增强版：FreePPS 清理 / 进程 -9 强杀纠正 / cycle_guard 补漏）
# 还原策略：还原一切"被模块接管过的运行时可还原项"；DTBO 不自动回滚（由用户决定保留或从备份刷回）。
XBT=/data/adb/modules/battery_tune
BK=/sdcard/Download/xt_uninstall_backup_$(date +%Y%m%d_%H%M%S)

# v2.6.23：提前 source common.sh —— 后面要用 xbt_kill（pgrep 版安全进程管理）
# v2.7.5 【🔴 修复】：这一行原先写在文件末尾（第 62 行），而 xbt_kill 从第 45 行就开始用了。
#   管理器是 `sh uninstall.sh` 独立执行，不会预加载 common.sh
#   → 45~54 行全部 `xbt_kill: not found`（脚本无 set -e，继续跑完并打印 done）
#   → charge_guard / thermal_guard / cloud_guard / freepps（忽略 SIGTERM，最需要 -9）
#     / diag_log / fv_handler 全部继续运行到重启，
#     与用户可见声明"模块各守护进程（已全部停止，含 FreePPS 进程）"直接矛盾。
#   现在上移到使用点之前；并保留结尾的兜底 source（幂等，重复 source 无害）。
. $XBT/scripts/common.sh 2>/dev/null

# 0) 先备份关键状态（供用户/作者参考；也作为还原审计留痕）
mkdir -p "$BK" 2>/dev/null
cp -f "$XBT/config/settings.conf" "$BK/" 2>/dev/null
cp -f "$XBT/state/direct_current_defaults" "$BK/" 2>/dev/null
cp -f "$XBT/state/direct_control_defaults" "$BK/" 2>/dev/null
cp -f "$XBT/state/last_real_cycle.txt" "$BK/" 2>/dev/null
cp -f "$XBT/state/fv_default" "$BK/" 2>/dev/null
cp -f "$XBT/state/pss_initial" "$BK/" 2>/dev/null
cp -af "$XBT/state/cloud_quarantine" "$BK/" 2>/dev/null

cat > "$BK/还原说明.txt" 2>/dev/null <<'XEOF'
电池解容工具箱 · 卸载还原说明
============================
已自动还原：BAA挂载（已卸载并让系统重读原厂）、充电节点（电流/ctrl/温控，已按安装前快照写回）、
            smart_fv（已写回安装前值）、循环计数（如曾启用伪装）、云控隔离文件（已原样归还）、
            PSS低电锁容服务（已按安装前状态恢复）、模块各守护进程（已全部停止，含 FreePPS 进程）、
            FreePPS 整合（进程已停、数据目录已清、PD 验证节点已还原）。
不会自动回滚：DTBO 分区（解容镜像仍在设备里）。
  如需恢复原版 DTBO：
  ① 安装时的自动备份位于 /sdcard/Download/dtbo_backup/（dtbo_<槽位>_before_install_*.img）
  ② 重装本模块 →「DTBO 工具 → 从备份恢复/刷回」选择该镜像；或
  ③ 用 fastboot 刷入对应备份镜像。
建议：卸载后重启一次，让所有运行时节点彻底回到系统默认。
XEOF


# 1) 卸载 BAA bind mount（PID1 命名空间内），并让 batteryantiaging 重读原厂文件
sh $XBT/scripts/baa_ops.sh umount 2>/dev/null
setprop ctl.restart batteryantiaging 2>/dev/null

# 2) 停止 smart_fv 守护（含 inotifyd / 轮询子进程）
sh $XBT/scripts/fv_guard.sh stop 2>/dev/null
sh $XBT/scripts/cycle_guard.sh stop 2>/dev/null

# 3) 停止全部模块守护进程
# v2.6.23：全部改用 xbt_kill（内部走 pgrep）—— 直接扫 /proc 读 cmdline 在进程退出瞬间会永久阻塞
# v2.7.5：防御性兜底 —— 万一文件开头的 source 失败（common.sh 缺失等），这里再试一次，
#   并共用一个回退实现，保证"卸载时守护一定被停掉"这个承诺成立。
command -v xbt_kill >/dev/null 2>&1 || . $XBT/scripts/common.sh 2>/dev/null
if ! command -v xbt_kill >/dev/null 2>&1; then
  # 极简回退：不带存活复核的直接 kill（比留着守护进程跑更好）
  xbt_kill() { for _p in $(pgrep -f "$1" 2>/dev/null); do kill -9 "$_p" 2>/dev/null; done; }
fi
# 3a) FreePPS（Rust 进程，忽略 SIGTERM，必须 -9；且最先杀，防 cloud_guard 保活复拉）
xbt_kill 'battery_tune/bin/freepps' 'battery_tune/bin/freepps'
xbt_kill '^freepps$' 'freepps'
# 3b) 其余守护（含 cloud_guard watch / charge / thermal / cycle / diag）
# 注：tr 周期清理已挂进 charge_guard 主循环（非独立进程），杀 charge_guard 即随之结束
xbt_kill 'battery_tune/scripts/charge_guard\.sh'   'battery_tune/scripts/charge_guard.sh'
xbt_kill 'battery_tune/scripts/thermal_guard\.sh'  'battery_tune/scripts/thermal_guard.sh'
xbt_kill 'battery_tune/scripts/cycle_guard\.sh'    'battery_tune/scripts/cycle_guard.sh'
xbt_kill 'battery_tune/scripts/cloud_guard\.sh'    'battery_tune/scripts/cloud_guard.sh'
xbt_kill 'battery_tune/scripts/diag_log\.sh'       'battery_tune/scripts/diag_log.sh'
xbt_kill 'battery_tune/scripts/fv_guard\.sh'       'battery_tune/scripts/fv_guard.sh'
xbt_kill 'battery_tune/scripts/fv_handler\.sh'     'battery_tune/scripts/fv_handler.sh'
rm -f /data/local/tmp/xt_fv_guard.pid /data/local/tmp/xt_cycle_guard.pid /data/local/tmp/xt_thermal_guard.pid 2>/dev/null
rm -f $XBT/state/thermal_restore_active 2>/dev/null
# v2.7.8：清理"全局限流写入间隔"状态（这是 v2.7.8 新增的持久节流时间戳；
#   它在运行期【刻意不被任何清旗路径删除】，只在卸载时清，避免残留影响重装后的首写）
rm -f $XBT/state/cg_last_write_ts $XBT/state/cg_gap_log_ts 2>/dev/null
# v2.7.12：清理 inf 安顿相关的全部持久状态。
#   inf_settled / inf_settle_ts / inf_settle_fail 是 v2.7.5~ 的安顿旗与节流；
#   inf_selfcheck_ts 是 v2.7.6 的 300 秒自纠正时间戳；
#   inf_node_capped 是 v2.7.12 新增的"本机型该列物理到不了 10A"标记。
#   ★ 必须一起清：若只清 part，重装后可能继承"已安顿"旗 → 首次插枪不补写。
rm -f $XBT/state/inf_settled $XBT/state/inf_settle_ts $XBT/state/inf_settle_fail \
      $XBT/state/inf_selfcheck_ts $XBT/state/inf_node_capped 2>/dev/null
# FreePPS 整合：还原验证节点 + 清理【我们自己建的】数据目录
# ===== v2.9.3 【🔴 跨模块破坏修复】=====
# 【旧行为】`rm -rf /data/adb/modules/freepps`
#   本意：清理本模块在 freepps 目录下放的状态文件（free）。
# 【为什么危险】如果用户【单独装了真正的 FreePPS 模块】，
#   /data/adb/modules/freepps 就是那个模块的家 —— 这条命令会把它【整个删掉】
#   （module.prop / 脚本 / bin 全部）。用户重启后模块消失，且完全不会怀疑到卸载头上
#   （因为上面那段"还原说明"还写着"已自动还原"）。
# 【新行为】先判断是不是真模块，再决定删什么。
FP_DIR=/data/adb/modules/freepps
if [ -d "$FP_DIR" ]; then
  if [ -f "$FP_DIR/post-fs-data.sh" ] || [ -f "$FP_DIR/service.sh" ] || [ -f "$FP_DIR/module.prop" ]; then
    rm -f "$FP_DIR/free" 2>/dev/null
    log "uninstall: REAL FreePPS module detected -> kept intact (removed only our 'free' flag)"
  else
    rm -f "$FP_DIR/free" 2>/dev/null
    rmdir "$FP_DIR" 2>/dev/null
    log "uninstall: removed our own freepps state dir"
  fi
fi
# ===== v2.9.4 修复：pd_verifed 要还原【两个】节点 =====
# 【旧 bug】这里只写了 /sys/class/qcom-battery/pd_verifed，但模块自己的标准还原路径
#   （scripts/freepps.sh 的 restore）明确处理【两个】节点：
#     /sys/class/qcom-battery/pd_verifed
#     /sys/class/Charging_Adapter/pd_adapter/usbpd_verifed
#   → 卸载后 usbpd_verifed 可能永久停在模块写入的 1（伪造的"PD 已验证"标记残留），
#     影响系统对充电器 PD 能力的判定。
# 【修法】显式遍历两个节点。注意【不调用】freepps.sh restore —— 它内部的 ensure_dir
#   会 mkdir -p /data/adb/modules/freepps 并写 free，把上面刚清理的目录又重建出来。
for _pv in /sys/class/qcom-battery/pd_verifed \
           /sys/class/Charging_Adapter/pd_adapter/usbpd_verifed \
           /sys/class/power_supply/usb/pd_verifed; do
  [ -e "$_pv" ] || continue
  chmod 664 "$_pv" 2>/dev/null
  if echo 0 > "$_pv" 2>/dev/null; then
    log "uninstall: $(basename "$_pv") -> 0"
  else
    log "uninstall: WARN $(basename "$_pv") write failed"
  fi
done

# 4) 还原模块接管前的充电节点值（电流快照 + 温控/ctrl 快照）
. $XBT/scripts/common.sh
restore_current_limit 2>/dev/null
restore_control_limit 2>/dev/null

# ===== v2.9.4 【P0 修复】污染快照识别 + 温控总闸强制归零 =====
# 【真问题】direct_control_defaults 是"安装前原值快照"，但旧版本（≤v2.7.12）
#   在【写完 thermal_remove=1 之后】才抓快照 → 把模块自己写的 1 当成了"原值"存下来。
#   v2.9.3 起把快照时机提前了，但快照写入是"已存在则跳过"（common.sh 的
#   snapshot_control_limit 里 `grep -qF ... && continue`）→ **已有的污染文件修不回来**，
#   而升级迁移（customize.sh 的 state 白名单）会把它原样带过来。
# 【后果】卸载时 restore_control_limit 把 1 写回 → 温控总闸永久停在"绕过驱动温控表"，
#   DT 温控保护被解除，而还原说明文件还写"已自动还原" → 用户完全无感。
# 【判据】驱动原厂默认 = 0（service.sh 有作者实机记录）。1 只可能是模块自己写的。
#   故：只要当前值是 1（无论快照说什么）就归 0 —— 污染快照与新快照都安全。
_th_done=0
for _th in /sys/class/xm_power/charger/charger_thermal/wired_thermal_remove \
           /sys/class/xm_power/charger/charger_thermal/wireless_thermal_remove; do
  [ -e "$_th" ] || continue
  _cur=$(cat "$_th" 2>/dev/null)
  if [ "$_cur" = "1" ]; then
    chmod 664 "$_th" 2>/dev/null
    if echo 0 > "$_th" 2>/dev/null; then
      log "uninstall: $(basename "$_th") 1 -> 0 (release DT bypass)"
      _th_done=1
    else
      log "uninstall: WARN $(basename "$_th") write 0 failed (still=$_cur)"
    fi
  fi
done
if [ -s "$XBT/state/direct_control_defaults" ]; then
  if grep -qE 'thermal_remove\|1$' "$XBT/state/direct_control_defaults" 2>/dev/null; then
    cp -f "$XBT/state/direct_control_defaults" "$XBT/state/direct_control_defaults.polluted" 2>/dev/null
    log "uninstall: DETECTED polluted snapshot (thermal_remove|1) -> released to 0 (evidence .polluted)"
  fi
  [ "$_th_done" = "1" ] || log "uninstall: thermal_remove already 0 (snapshot kept as-is)"
else
  log "uninstall: no control snapshot -> thermal_remove forced 0"
fi

# 4b) 还原 smart_fv（卸载还原用；由 fv_guard 首次启动时记录）
# ===== v2.9.5 【修复】快照值可能被模块自己污染 =====
# 【smart_fv 是什么】满充降压量(mV)：30~40 = 厂商的电池抗老化保护（少充一点）；
#   0 = 不降压 = 解容（= 本模块的目的）。所以"运行期把它压 0"是正确的功能。
# 【真问题】旧实现的快照 `cat $FV_NODE` 发生在【BAA 挂载之后】——
#   此时载荷已把节点写成 0 → 快照记下 0 → 卸载时把这 0 写回 →
#   **原厂的 30/40 降压保护永久丢失**，而说明文件还写"已自动还原"。
#   customize.sh 的 state 迁移白名单含 fv_default → 污染跨版本永久携带。
# 【修法】识别污染（快照=0，而原厂实测 13/14 机型为 30/40）→ 还原到原厂档位 40。
#   并保留证据副本。原厂值依据：模块自带 stock_BAA_config_*.json 实测
#   xuanyuan/haotian/dada/... = value[30,40]、bixi/onyx = [40]、songyuan/pandora 未改。
_fvd=$(cat "$XBT/state/fv_default" 2>/dev/null)
_fvsrc=$(cat "$XBT/state/fv_default_src" 2>/dev/null)
case "$_fvd" in
  ''|*[!0-9]*) ;;
  *)
    # 污染判据（覆盖三种来源）：
    #   · src=stock  → 从原厂载荷读来的权威值，trusted（但 stock 若真是 0 也保留）
    #   · src=table  → 内置原厂档位表（40），trusted
    #   · src 缺失   → 【旧版本 ≤v2.9.4 写的文件，没有 src 标记】→ 一律按可疑处理
    #   · 值为 0 且 src≠stock → 污染
    if [ "$_fvd" = "0" ] && [ "$_fvsrc" != "stock" ]; then
      cp -f "$XBT/state/fv_default" "$XBT/state/fv_default.polluted" 2>/dev/null
      log "uninstall: DETECTED polluted fv_default=0 (src=${_fvsrc:-legacy-none}) -> restoring factory 40mV (evidence .polluted)"
      _fvd=40
      _fvsrc="repaired"
    fi
    if [ -e "$FV_NODE" ]; then
      if echo "$_fvd" > "$FV_NODE" 2>/dev/null; then
        log "uninstall: smart_fv restored -> $_fvd (source=${_fvsrc:-?})"
      else
        log "uninstall: WARN smart_fv restore failed (target=$_fvd)"
      fi
    fi
    ;;
esac

# 5) 还原循环计数（写回真实值）
# v2.7.5 【X2 修复】：设置侧同时写 cyclecount 与 battery/cycle_count 两个节点，
#   还原侧原先只写第一个 → 第二个会一直停在伪装值直到重启（cycle_guard 已 stop，
#   没人纠正），用户在系统设置里看到的仍是假值。现两个都还原。
#
# ===== v2.9.5 【修复三处】=====
# 【问题 1 · 门控错误】旧代码 `if [ -z "$_cf" ]; then 跳过`——用户执行过
#   `unlock off`（它会清空 cycle_fake）之后，伪装值仍留在节点上，但还原被整段跳过
#   → 系统里永久显示假循环数。→ 去掉门控：还原与否应由"节点上有没有假值"决定，
#   而不是由"配置里还有没有 cycle_fake"决定。
# 【问题 2 · 取值陈旧】旧代码把 `last_real_cycle.txt` 当作真值。但该文件的更新条件是
#   `_old == _cf`（伪装中且文件值等于伪装值才更新），实测它【冻结在 601】而
#   真实值（qmax_cyclecount）已涨到 623 → 卸载会把真实值【下调 22 次】。
#   → 改为优先读【实时】qmax_cyclecount（`$CYCLE_REAL_NODE`，模块从不写它，是权威值）。
# 【问题 3 · 可能下调】旧代码 `_cur != _rr` 就直接写，不比较大小 → 可能把真值改小。
#   → 取 {实时 qmax, 文件真值, 两个节点现有值} 的【最大值】作为还原目标，
#     并只在"当前值 < 目标"或"当前值 == 伪装值"时才写。
#   ★ 安全原则：宁可不写，也绝不把真实循环数往下改。
_cycle_target() {
  _t=""
  for _s in "$(cat "$CYCLE_REAL_NODE" 2>/dev/null)" \
            "$(cat "$CYCLE_REAL_FILE" 2>/dev/null)" \
            "$(cat "${CYCLE_NODE:-/sys/class/xm_power/fg_master/cyclecount}" 2>/dev/null)" \
            "$(cat "${CYCLE_NODE2:-/sys/class/power_supply/battery/cycle_count}" 2>/dev/null)"; do
    case "$_s" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$_t" ] || [ "$_s" -gt "$_t" ] 2>/dev/null; then _t="$_s"; fi
  done
  echo "$_t"
}
_cf=$(cfg_get cycle_fake "")
_tgt=$(_cycle_target)
if [ -z "$_tgt" ]; then
  log "uninstall: cycle restore skipped (no usable real value found)"
else
  log "uninstall: cycle real target = $_tgt (qmax=$(cat "$CYCLE_REAL_NODE" 2>/dev/null) file=$(cat "$CYCLE_REAL_FILE" 2>/dev/null) fake_cfg=${_cf:-none})"
  for _cn in "${CYCLE_NODE:-/sys/class/xm_power/fg_master/cyclecount}" \
             "${CYCLE_NODE2:-/sys/class/power_supply/battery/cycle_count}"; do
    [ -e "$_cn" ] || continue
    _cur=$(cat "$_cn" 2>/dev/null)
    case "$_cur" in ''|*[!0-9]*) continue ;; esac
    if [ "$_cur" = "$_tgt" ]; then
      continue                                   # 已是真值，不动
    fi
    if [ -n "$_cf" ] && [ "$_cur" = "$_cf" ]; then
      :                                          # 是伪装值 → 必须还原
    elif [ "$_cur" -gt "$_tgt" ] 2>/dev/null; then
      log "uninstall: $(basename "$_cn") kept at $_cur (> target $_tgt, never downgrade)"
      continue                                   # 比真值还大 → 不动，绝不降级
    fi
    chmod 666 "$_cn" 2>/dev/null
    if echo "$_tgt" > "$_cn" 2>/dev/null; then
      log "uninstall: $(basename "$_cn") $_cur -> $_tgt"
    else
      log "uninstall: $(basename "$_cn") restore FAILED (readonly?)"
    fi
  done
fi

# 6) 归还云端"隔离区"文件（按来源记录原位归还；无记录则回落到两个云端目录）
# v2.6.23：_sources.log 的键已由「秒级时间戳」改为「隔离文件名」
#   旧版用秒级时间戳作键，同一秒隔离多个文件时 grep|tail -1 恒取最后一条 → 互相覆盖丢文件
QD="$XBT/state/cloud_quarantine"
if [ -d "$QD" ]; then
  for f in "$QD"/*; do
    [ -e "$f" ] || continue
    _b=$(basename "$f")
    case "$_b" in _sources.log) continue ;; esac
    # 新格式：按隔离文件名精确匹配；旧格式：回退用时间戳前缀（兼容历史隔离区）
    _src=$(grep -F "${_b}|" "$QD/_sources.log" 2>/dev/null | tail -n 1 | cut -d'|' -f2-)
    if [ -z "$_src" ]; then
      _ts=${_b%%__*}
      _src=$(grep -F "${_ts}|" "$QD/_sources.log" 2>/dev/null | tail -n 1 | cut -d'|' -f2-)
    fi
    # 真正的原始文件名：去掉 `<ts>__` 或 `<ts>__<n>__` 前缀
    _orig=$(echo "$_b" | sed -E 's/^[0-9]{8}_[0-9]{6}__([0-9]+__)?//')
    if [ -n "$_src" ] && [ -d "$(dirname "$_src")" ] && [ ! -e "$_src" ]; then
      mv "$f" "$_src" 2>/dev/null && { log "uninstall: cloud file returned -> $_src"; continue; }
    fi
    for d in /mnt/vendor/persist/charger/batteryantiaging/cloud_config \
             /data/vendor/batteryantiaging/cloud_config; do
      if [ -d "$d" ]; then
        mv "$f" "$d/$_orig" 2>/dev/null && { log "uninstall: cloud file returned -> $d/$_orig"; break; }
      fi
    done
  done
fi

# 7) 恢复低电量锁容服务（v2.9.10 修正）
# ===== 【旧版 bug】只看 pss_initial，导致 PSS 永久禁用 =====
#   旧逻辑：pss_initial=disabled → 保持不动。
#   但 pss_initial 可能是"旧版先禁用、之后才拍快照"的【污染值】——
#   于是卸载后 PSS 永久保持禁用 → **电池健康度永久不显示**。
#   这正是社区需要第三方脚本（BatteryScope）来修的原因。
# ===== 【v2.9.10 新逻辑】三态判定 =====
#   ① pss_disabled_by_module=1  → 模块亲手禁的 → 必定还原为启用
#   ② pss_initial=enabled/缺失  → 说明安装前是启用 → 还原为启用
#   ③ pss_initial=disabled 且无标记 → 安装前就禁用（用户自主）→ 保持不动
#   （真机实测依据见 service.sh 的 PSS 段注释：禁用 PSS 会让
#     com.miui.securitycenter.remote 不启动 → BatteryHealthUtils 不运行 → 健康度无数据）
_pss_made=$(cat "$XBT/state/pss_disabled_by_module" 2>/dev/null)
_pi=$(cat "$XBT/state/pss_initial" 2>/dev/null)
PSS_RESTORE=com.miui.securitycenter/com.miui.powercenter.provider.PowerSaveService
if [ "$_pss_made" = "1" ]; then
  pm enable "$PSS_RESTORE" 2>/dev/null
  log "uninstall: PSS re-enabled (was disabled by module -> restores battery health UI)"
  echo "enabled" > "$XBT/state/pss_initial" 2>/dev/null
elif [ "$_pi" = "disabled" ]; then
  log "uninstall: PSS kept as-is (was disabled before install, not by module)"
else
  pm enable "$PSS_RESTORE" 2>/dev/null
  log "uninstall: PSS re-enabled -> battery health UI restored"
fi

# ===== v2.10.1 / v2.10.4：DTBO —— 只检测 + 报告，【不自动刷写】=====
# 【为什么不自动还原】（作者定调 + 真机取证）
#   ① 同一机型不同系统版本的 DTBO 本来就不同，但【跨版本通用】
#      → "还原到安装前那个精确版本"不是刚需；用户真正要的是"回到原厂"，
#        而原厂镜像用户自己就有（fastboot 刷整包，或第一条 before_install 备份）。
#   ② 备份是 dd 整个分区 → 文件大小恒等于分区大小 → 无法用大小判断血统。
#   ③ "备份内容 ≠ 当前模块镜像"也【不能】证明它是原厂：
#        v2.9.x 解容 xuanyuan = d65d27b4…     v2.10.x 解容 = a027a6b1…
#      旧版魔改同样 "≠ 当前版本" → 误判会把设备刷成"上一版的魔改 DTBO"。
#   ④ 刷 DTBO 是整个模块唯一可能变砖的操作，绝不该在卸载时自动执行。
#   ⇒ 卸载只做两件事：检测当前槽是不是本模块镜像 + 打印备份清单与手动命令
#     （见第 9 节「卸载残留报告」）。要还原请用户自己执行：
#        su -c 'sh /data/adb/modules/battery_tune/scripts/dtbo.sh list'
#        su -c 'sh /data/adb/modules/battery_tune/scripts/dtbo.sh flash <备份>'
#     然后重启 —— 保留人的判断，比任何自动判据都可靠。
_bkdir=$(cfg_get backup_dir "/sdcard/Download/dtbo_backup")
# ---- 无条件检测：当前槽是否仍是本模块镜像（写进残留报告，v2.10.3 新增）----
#   ★ 这一步【不写任何东西】，只读分区做 sha 比对，卸载时一定要有结论。
_dtbo_state="无法判断（dev_code/镜像缺失）"
_dtbo_slot=""
_devc0=$(cfg_get dev_code "")
_mine0="$XBT/dtbo/${_devc0}.img"
if [ -n "$_devc0" ] && [ -f "$_mine0" ]; then
  _msz0=$(stat -c %s "$_mine0" 2>/dev/null)
  _pad0=/data/local/tmp/dtbo_uninst_pad0.img
  _dtbo_state="非本模块镜像（原厂/他版，无需处理）"
  for _s0 in a b; do
    _p0=/dev/block/by-name/dtbo_$_s0
    [ -e "$_p0" ] || continue
    _dsz0=$(blockdev --getsize64 "$_p0" 2>/dev/null)
    [ -n "$_dsz0" ] || continue
    _mh0=""
    if [ "$_msz0" = "$_dsz0" ]; then
      _mh0=$(sha256sum "$_mine0" 2>/dev/null | awk '{print $1}')
    elif [ -n "$_msz0" ] && [ "$_msz0" -lt "$_dsz0" ] 2>/dev/null; then
      if cp -f "$_mine0" "$_pad0" 2>/dev/null && truncate -s "$_dsz0" "$_pad0" 2>/dev/null; then
        _mh0=$(sha256sum "$_pad0" 2>/dev/null | awk '{print $1}')
      fi
    fi
    _c0=$(dd if="$_p0" bs=1M 2>/dev/null | sha256sum | awk '{print $1}')
    if [ -n "$_mh0" ] && [ "$_c0" = "$_mh0" ]; then
      _dtbo_state="仍是解容版（模块写的，未还原）"
      _dtbo_slot="$_s0"
      log "uninstall: DTBO 检测 —— slot $_s0 仍是本模块镜像"
      break
    fi
  done
  rm -f "$_pad0" 2>/dev/null
fi


log "uninstall: done (state backup at $BK)"
cp -f /data/local/tmp/xt_toolbox.log "$BK/xt_toolbox.log" 2>/dev/null
cp -f /data/local/tmp/xt_toolbox.log.rot "$BK/xt_toolbox.log.rot" 2>/dev/null

# 8) 清理日志与临时文件（日志已备份到 $BK）
# ===== v2.10.1：补齐所有 /data/local/tmp 残留（审计发现的 5 处缺口）=====
#   xt_charge_guard.pid / xt_cloud_guard.pid / xt_diag_log.pid —— 守护 pid 文件，
#     安装时由 customize.sh 清，卸载时【原先不清】→ 重装可能读到陈旧 pid。
#   dtbo_pad.img —— dtbo.sh 补齐镜像时用的临时文件（最大 25MB）。
#   xt_dtbo_list.txt —— menu.sh 的临时列表。
rm -f /data/local/tmp/xt_toolbox.log /data/local/tmp/xt_toolbox.log.rot 2>/dev/null
rm -f /data/local/tmp/xt_restore_list.txt /data/local/tmp/dtbo_pad_install.img 2>/dev/null
rm -f /data/local/tmp/dtbo_pad.img /data/local/tmp/xt_dtbo_list.txt 2>/dev/null
rm -f /data/local/tmp/xt_charge_guard.pid /data/local/tmp/xt_cloud_guard.pid \
      /data/local/tmp/xt_diag_log.pid 2>/dev/null
rm -f /sdcard/xt_toolbox.log 2>/dev/null

# 9) 卸载残留报告（给用户/作者看清"还剩什么"）
{
  echo ""
  echo "===== 卸载残留检查 ====="
  echo "[DTBO] $_dtbo_state"
  if [ -n "$_dtbo_slot" ]; then
    echo "       槽位: dtbo_$_dtbo_slot"
    echo "       ⚠ DTBO 是唯一需要重启才生效的项；要还原原厂请手动执行："
    echo "         su -c 'sh /data/adb/modules/battery_tune/scripts/dtbo.sh list'"
    echo "         su -c 'sh /data/adb/modules/battery_tune/scripts/dtbo.sh flash <备份文件>'"
    echo "         （备份命名 dtbo_<槽>_before_install_<时间>.img，在 $_bkdir）"
    echo "       ⚠ 注意：备份里【较早的那份】才是原厂；较晚的可能是上一版模块的魔改镜像。"
    echo "         判断方法：文件里模块镜像长度(616593B)之后若全为零 = 那次刷入是补零写"
    echo "         的魔改镜像；有非零数据 = 完整原厂镜像。"
  fi
  echo "[BAA]  $(sh $XBT/scripts/baa_ops.sh check 2>/dev/null | head -n 1)"
  echo "[节点] pd_verifed=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)"
  echo "       verified=$(cat /sys/class/xm_power/typec/strategy_pd_auth/verified 2>/dev/null)"
  echo "       fake_pps_ptf=$(cat /sys/class/xm_power/charger/quick_charge/fake_pps_ptf 2>/dev/null)"
  echo "       wired_thermal_remove=$(cat /sys/class/xm_power/charger/charger_thermal/wired_thermal_remove 2>/dev/null)"
  echo "       smart_fv=$(cat /sys/class/xm_power/charger/smart_charge/smart_fv 2>/dev/null)"
  echo "[PSS]  $(pm list packages -d 2>/dev/null | grep -c PowerSaveService) 个 PowerSaveService 仍被禁用"
  echo "[文件] /data/adb/modules/freepps: $( [ -d /data/adb/modules/freepps ] && echo 存在 || echo 已清 )"
  echo "[提示] 建议重启一次，让所有运行时节点彻底回到系统默认"
} >> "$BK/卸载残留.txt" 2>/dev/null
cat "$BK/卸载残留.txt" 2>/dev/null

exit 0
