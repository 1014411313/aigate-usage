#!/system/bin/sh
# ============================================================
# 电池仅解容可改电压 - 用户自定义电压守护 v3.0.30
# ------------------------------------------------------------
# 功能：
#   term_v  关机电压（mV，2800~3500，空=关闭）
#   fv_v    满电电压（mV，4300~4600，空=关闭；不能超过系统 BAA 最高满充电压）
# 机制：
#   - 自动探测可写电压节点（满电优先 constant_charge_voltage）
#   - 单位自适应：µV（×1000）与 mV 自动识别（写后读回匹配 ±2% 容差）
#   - 30s 轮询守护：充电会话/系统覆盖时自动重写，防"不生效"
#   - 首次写入前记录原始值（state/volt_orig.txt），stop/卸载时还原
# 用法: volt_guard.sh start|stop|status
# ============================================================
XBT=${XBT:-/data/adb/modules/HyperOS_XJ/battery}
. $XBT/scripts/common.sh

PIDFILE=/data/local/tmp/xt_volt_guard.pid
ORIG=$XBT/state/volt_orig.txt

TERM_V=$(cfg_get term_v "")
FV_V=$(cfg_get fv_v "")

# v3.0.38 关机电压改为【软件检测关机】方案：
#   OS4 新平台无任何可写内核关机节点（诊断证实）→ 不再尝试写节点，
#   改为守护轮询电池电压（voltage_now），电压 ≤ term_v 时执行关机指令。
TERM_VOLT_NODES="
/sys/class/power_supply/battery/voltage_now
/sys/class/power_supply/bms/voltage_now
/sys/class/power_supply/main/voltage_now
/sys/class/power_supply/charger/voltage_now
/sys/class/power_supply/usb/voltage_now
"
# 满电电压候选节点（constant_charge_voltage 为系统充电截止权威节点，最优先）
# v3.00.39：移除 charge_control_limit —— 它是【电流限制节点】(mA, 如 xuanyuan
#   max=16)，不是电压节点。混入后：节点存在(可写) → 误判"存在但不可写"，
#   且新平台不进入载荷改写路径（用户真机日志证实）。只保留电压类候选。
FV_CANDS="
/sys/class/power_supply/battery/constant_charge_voltage
/sys/class/power_supply/battery/voltage_max
"

# ---- 数字匹配（读回 vs 期望，±2% 容差，兼容驱动取整/截断）----
_num() { echo "$1" | tr -cd '0-9'; }
_match() {
  _r=$(_num "$1"); _e="$2"
  case "$_r" in ''|0) return 1 ;; esac
  _d=$(( _r - _e )); [ "$_d" -lt 0 ] && _d=$(( -_d ))
  _lim=$(( _e / 50 ))   # 2%
  [ "$_d" -le "$_lim" ]
}

# ---- 写入一个节点（单位自适应）----
# 成功：echo "uv" 或 "mv"（识别到的单位）；失败：echo "" 返回 1
_write_voltage() {
  _n="$1"; _t="$2"
  [ -e "$_n" ] || return 1
  _perm=$(stat -c %A "$_n" 2>/dev/null)
  case "$_perm" in *w*) ;; *) return 1 ;; esac
  _tuv=$(( _t * 1000 ))
  # 先试 µV（constant_charge_voltage 等标准单位）
  echo "$_tuv" > "$_n" 2>/dev/null
  _r=$(cat "$_n" 2>/dev/null)
  if _match "$_r" "$_tuv"; then echo "uv"; return 0; fi
  # 再试 mV
  echo "$_t" > "$_n" 2>/dev/null
  _r=$(cat "$_n" 2>/dev/null)
  if _match "$_r" "$_t"; then echo "mv"; return 0; fi
  return 1
}

# ---- 记录原始值（仅首次，供还原）----
_save_orig() {  # $1=node $2=unit
  _n="$1"; _u="$2"
  [ -e "$_n" ] || return
  grep -qF "$_n|" "$ORIG" 2>/dev/null && return
  _o=$(cat "$_n" 2>/dev/null)
  case "$_o" in ''|*[!0-9]*) _o="" ;; esac
  mkdir -p "$XBT/state" 2>/dev/null
  echo "$_n|$_o|$_u" >> "$ORIG" 2>/dev/null
}

# ---- 应用单类电压（遍历候选节点，第一个成功即用）----
_apply_term() {
  _t="$TERM_V"
  case "$_t" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_t" -ge 2800 ] && [ "$_t" -le 3500 ] || { log "volt: term_v=$_t 越界(2800~3500)，忽略"; return 1; }
  # v3.0.38 软件关机方案：找可读电压节点，守护轮询检测，达到阈值由模块执行关机指令
  for _n in $TERM_VOLT_NODES; do
    [ -r "$_n" ] || continue
    _v=$(cat "$_n" 2>/dev/null | tr -d ' \n')
    case "$_v" in ''|*[!0-9]*) continue ;; esac
    [ "$_v" -gt 100000 ] || continue   # >0.1V 才视为有效读数（voltage_now 单位 µV）
    echo "$_n" > "$XBT/state/volt_term_node" 2>/dev/null
    echo "soft" > "$XBT/state/volt_term_mode" 2>/dev/null
    log "volt: 关机电压（模块执行关机）启用 阈值=${_t}mV 检测节点=$_n"
    return 0
  done
  log "volt: 未找到可读电压节点（term_v=$_t 关机方案无法启用）"
  return 1
}

# ---- v3.0.38 关机检测：电压 ≤ term_v 时由模块执行关机指令 ----
# 复用 volt_guard 守护（无新增进程）；充电中/无效读数不触发
_check_term_shutdown() {
  [ -n "$TERM_V" ] || return 0
  [ -f "$XBT/state/volt_term_mode" ] || return 0
  _n=$(cat "$XBT/state/volt_term_node" 2>/dev/null)
  [ -n "$_n" ] && [ -r "$_n" ] || return 0
  _v=$(cat "$_n" 2>/dev/null | tr -d ' \n')
  case "$_v" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_v" -gt 100000 ] || return 0
  _vmv=$(( _v / 1000 ))
  [ "$_vmv" -gt "$TERM_V" ] && return 0
  # 充电中不触发（充电时电压读数必然高于阈值，防御异常）
  _st=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
  case "$_st" in *Charging*) log "volt: 电压 ${_vmv}mV ≤ ${TERM_V}mV 但充电中，跳过"; return 0 ;; esac
  log "volt: ⚠⚠ 电压 ${_vmv}mV ≤ 关机阈值 ${TERM_V}mV，模块执行关机！"
  if command -v reboot >/dev/null 2>&1; then
    reboot -p 2>/dev/null && return 0
  fi
  if command -v svc >/dev/null 2>&1; then
    svc power shutdown 2>/dev/null && return 0
  fi
  log "volt: 关机指令执行失败（reboot -p / svc power shutdown 均不可用）"
  return 0
}

# ---- 强制覆盖 BAA vterm 上限（fv_force=1 时启用）----
# 原理：模块挂载的 BAA 载荷就是模块自己的文件 → 把所有 vterm 改成用户设定值
#   → 重新加密 → 重挂载。antiaging 按新载荷 vterm 停充，上限被真正覆盖。
# 边界：硬件 OVP（如小米17 ovp-aligned 4550/4580）是物理层保护，超过 OVP 的
#   目标电压仍会被硬件拦截（无害但不生效）——如实提示，不承诺。
_apply_fv_force() {
  _t="$FV_V"
  # v1.0.0 修复：首次应用前锁定【原厂 vterm 上限】——旧版 get_vterm_max 从
  #   模块内置载荷读上限，而强改载荷时该文件被同步改写 → 上限被污染（用户真机
  #   原厂 4570 变 4600）→ 超限不警告、系统充电策略(delta_fv)不跟进 → 充不满、
  #   FG 容量学习锁死 charge_full。锁定后 get_vterm_max 恒返回原厂值。
  if [ ! -s "$XBT/state/fv_vterm_orig" ]; then
    _vo=$(get_vterm_max 2>/dev/null)
    case "$_vo" in ''|*[!0-9]*) ;; *) echo "$_vo" > "$XBT/state/fv_vterm_orig" 2>/dev/null ;; esac
  fi
  _vo=$(cat "$XBT/state/fv_vterm_orig" 2>/dev/null); case "$_vo" in ''|*[!0-9]*) _vo="" ;; esac
  if [ -n "$_vo" ] && [ "$_t" -gt "$_vo" ] 2>/dev/null; then
    log "volt: ⚠ fv_v=$_t 超出原厂 vterm 上限 ${_vo}mV —— 系统充电策略可能不跟进，可能导致充不满、FG 容量学习锁死；如容量异常请改回 ≤${_vo}"
  fi
  # v3.00.41 幂等保护：守护 30s 轮询每次都会走到这里，若上次已应用相同值
  #   则直接跳过（纯 awk 加密手机端 1~6 分钟，重复执行会每 30s 卡顿一次）。
  #   v1.0.0 修正验证口径：不再用 get_vterm_max（修后=原厂上限，与设定值比较无意义），
  #   改验【应用明文缓存 vterm==设定 且 挂载 active】——防「标记在但载荷被覆盖/未挂上」。
  if [ -f "$XBT/state/fv_force_applied" ]; then
    _applied=$(cat "$XBT/state/fv_force_applied" 2>/dev/null)
    if [ "$_applied" = "$_t" ]; then
      _pv=""
      [ -f "$XBT/state/fv_force_plain.json" ] && \
        _pv=$(grep -oE '"vterm"[[:space:]]*:[[:space:]]*[0-9]+' "$XBT/state/fv_force_plain.json" 2>/dev/null \
              | grep -oE '[0-9]+$' | sort -n | tail -n 1)
      _bs=$(baa_state 2>/dev/null)
      if [ -n "$_pv" ] && [ "$_pv" = "$_t" ] && [ "$_bs" = "active" ]; then
        return 0
      fi
      rm -f "$XBT/state/fv_force_applied" 2>/dev/null
      log "volt: 载荷验证不一致（明文=${_pv:-空}/挂载=${_bs:-空}），重新应用"
    fi
  fi
  # v3.00.41 失败退避：上次加密/挂载失败后 600s 内不重试
  #   （否则失败一次后每 30s 轮询都会重跑 6 分钟加密）
  if [ -f "$XBT/state/fv_force_fail" ]; then
    _ft=$(cat "$XBT/state/fv_force_fail" 2>/dev/null)
    case "$_ft" in ''|*[!0-9]*) _ft=0 ;; esac
    _now=$(date +%s 2>/dev/null); case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
    if [ "$_now" -gt 0 ] && [ $((_now - _ft)) -lt 600 ]; then
      log "volt: 上次载荷加密/挂载失败，600s 内不重试（自动重试于 $((600 - (_now - _ft)))s 后）"
      return 1
    fi
    rm -f "$XBT/state/fv_force_fail" 2>/dev/null
  fi
  _plain="$XBT/baa/modes/normal_plain.json"
  [ -f "$_plain" ] || _plain="$XBT/baa/modes/normal_nocloud_plain.json"
  [ -f "$_plain" ] || { log "volt: force 需要 BAA 明文载荷，本机无载荷，无法覆盖"; return 1; }
  # v3.00.40：文件存在即可（-x 会因部分环境执行位丢失/解压差异误判"缺少"），
  # 调用统一走 sh（不依赖执行位）；openssl 做多路径探测（小米 ROM 常缺）
  # v3.00.41：无 openssl 时自动降级到纯 awk AES 加密（baa_crypt_awk.sh，
  #   仅依赖 base64/od/awk，Android 系统全自带，零外部依赖）
  _cb="$XBT/tools/baa_crypt.sh"
  [ -f "$_cb" ] || { log "volt: 缺少 baa_crypt.sh，无法覆盖（模块 tools/ 目录不完整？）"; return 1; }
  _ossl=""
  command -v openssl >/dev/null 2>&1 && _ossl=$(command -v openssl)
  [ -n "$_ossl" ] || for _o in /system/bin/openssl /system/xbin/openssl /data/adb/magisk/openssl /data/adb/ksu/bin/openssl /data/adb/twrp/openssl; do
    [ -x "$_o" ] && { _ossl="$_o"; break; }
  done
  if [ -n "$_ossl" ]; then
    export PATH="$(dirname "$_ossl"):$PATH"
    _enc="sh $XBT/tools/baa_crypt.sh"
  else
    _cawk="$XBT/tools/baa_crypt_awk.sh"
    [ -f "$_cawk" ] || { log "volt: 无 openssl 且缺少 baa_crypt_awk.sh，无法重新加密载荷（满电电压载荷改写不可用）"; return 1; }
    log "volt: 手机端无 openssl，使用纯 awk AES 加密（baa_crypt_awk.sh，零依赖）"
    _enc="sh $XBT/tools/baa_crypt_awk.sh"
  fi
  # 备份原载荷（仅首次）
  _bk="$XBT/state/fv_force_backup"
  if [ ! -d "$_bk" ]; then
    mkdir -p "$_bk" 2>/dev/null
    for _f in normal.json normal_nocloud.json normal_plain.json normal_nocloud_plain.json; do
      cp -f "$XBT/baa/modes/$_f" "$_bk/$_f" 2>/dev/null
    done
  fi
  # 替换所有 vterm -> 用户设定值，重新加密
  _tmp="$XBT/state/fv_force_plain.json"
  sed 's/"vterm"[[:space:]]*:[[:space:]]*[0-9][0-9]*/"vterm": '"$_t"'/g' "$_plain" > "$_tmp" 2>/dev/null || { log "volt: 载荷 vterm 替换失败"; return 1; }
  # v3.00.41：加密加超时保护（toybox awk 实测 88s~6min+，上限 600s 防永久卡死），
  #   失败写退避标记 + 清理半成品，避免下轮轮询反复重跑
  log "volt: 开始重新加密载荷（$([ -n "$_ossl" ] && echo openssl || echo 纯awkAES)，手机端可能需 1~6 分钟，请稍候）"
  timeout 600 $_enc encrypt "$_tmp" -o "$XBT/baa/modes/normal.json" >/dev/null 2>&1
  _rc=$?
  if [ "$_rc" != "0" ] || [ ! -s "$XBT/baa/modes/normal.json" ]; then
    echo "$(date +%s 2>/dev/null)" > "$XBT/state/fv_force_fail" 2>/dev/null
    rm -f "$XBT/state/fv_force_plain.json" "$XBT/state/fv_force_applied" 2>/dev/null
    log "volt: 载荷加密失败/超时（rc=$_rc），已记录退避，10 分钟后自动重试"
    return 1
  fi
  cp -f "$XBT/baa/modes/normal.json" "$XBT/baa/modes/normal_nocloud.json" 2>/dev/null
  cp -f "$_tmp" "$XBT/baa/modes/normal_plain.json" 2>/dev/null
  cp -f "$_tmp" "$XBT/baa/modes/normal_nocloud_plain.json" 2>/dev/null
  # 重挂载（先刷新 BAA_SRC，再 mount；已挂载会先 umount 再挂新载荷）
  # v3.00.41：mount 加 30s 超时保护（nsenter/内核挂载偶发卡住）
  baa_refresh_src >/dev/null 2>&1
  timeout 30 sh "$XBT/scripts/baa_ops.sh" mount >>"$LOG" 2>&1
  _rc=$?
  if [ "$_rc" != "0" ]; then
    echo "$(date +%s 2>/dev/null)" > "$XBT/state/fv_force_fail" 2>/dev/null
    rm -f "$XBT/state/fv_force_applied" 2>/dev/null
    log "volt: 载荷重挂载失败/超时（rc=$_rc），已记录退避，10 分钟后自动重试"
    return 1
  fi
  echo "$_t" > "$XBT/state/fv_force_applied" 2>/dev/null
  rm -f "$XBT/state/fv_force_fail" 2>/dev/null
  log "volt: ⚠ 已强制覆盖 BAA vterm 上限 -> $_t mV（载荷重生成并重挂载；注意硬件 OVP 限制）"
  return 0
}

_restore_force() {
  [ -f "$XBT/state/fv_force_applied" ] || return 0
  _bk="$XBT/state/fv_force_backup"
  [ -d "$_bk" ] || return 0
  for _f in normal.json normal_nocloud.json normal_plain.json normal_nocloud_plain.json; do
    [ -f "$_bk/$_f" ] && cp -f "$_bk/$_f" "$XBT/baa/modes/$_f" 2>/dev/null
  done
  baa_refresh_src >/dev/null 2>&1
  timeout 30 sh "$XBT/scripts/baa_ops.sh" mount >>"$LOG" 2>&1
  rm -f "$XBT/state/fv_force_applied" "$XBT/state/fv_force_plain.json" "$XBT/state/fv_force_fail" 2>/dev/null
  log "volt: 已还原 BAA vterm 上限（恢复原载荷）"
}

_apply_fv() {
  _t="$FV_V"
  case "$_t" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_t" -ge 4300 ] && [ "$_t" -le 4600 ] || { log "volt: fv_v=$_t 越界(4300~4600)，忽略"; return 1; }
  # 系统 BAA 最高满充电压上限检查：
  #   设值 > 载荷 vterm 上限 → fv_force=1 则强制覆盖载荷上限；否则拒绝（不假装生效）
  _mx=$(get_vterm_max)
  case "$_mx" in
    ''|0|*[!0-9]*) _mx=0 ;;
  esac
  if [ "$_mx" -gt 0 ] && [ "$_t" -gt "$_mx" ]; then
    if [ "$(cfg_get fv_force 0)" = "1" ]; then
      _apply_fv_force
      return $?
    fi
    log "volt: ⚠ fv_v=$_t 超过系统最高满充电压 ${_mx}mV（未开启强制覆盖，不会生效）"
    return 1
  fi
  # 老平台：CCV 类节点存在 → 写节点（不动载荷）
  # v3.00.41 复检：非 CCV 候选（如 battery/voltage_max）可能是适配器输入上限
  #   （xuanyuan 实测 = 9000000µV=9V）——存在但非电池满充电压，写必然失败且
  #   误判"节点存在"→ 永远进不了新平台载荷改写路径。过滤：值须在 4.0~5.0V
  #   （µV 4000000~5000000 或 mV 4000~5000）才算有效满充候选。
  _has_any=0
  for _n in $FV_CANDS; do
    [ -e "$_n" ] || continue
    case "$_n" in
      *constant_charge_voltage*)
        : ;;  # CCV 权威节点：存在即候选
      *)
        _cv=$(cat "$_n" 2>/dev/null | tr -d ' \n')
        case "$_cv" in ''|*[!0-9]*) _cv=0 ;; esac
        # µV 4.0~5.0V 或 mV 4000~5000 才算有效满充候选，否则是适配器/输入上限
        if { [ "$_cv" -ge 4000000 ] && [ "$_cv" -le 5000000 ]; } || \
           { [ "$_cv" -ge 4000 ] && [ "$_cv" -le 5000 ]; }; then
          :
        else
          log "volt: $_n 值=${_cv} 非电池满充范围(4.0~5.0V)，跳过"
          continue
        fi
        ;;
    esac
    _has_any=1
    _u=$(_write_voltage "$_n" "$_t")
    [ -n "$_u" ] || continue
    _save_orig "$_n" "$_u"
    echo "$_n|$_u" > "$XBT/state/volt_fv_node" 2>/dev/null
    log "volt: fv_v 应用 -> $_n ($_u, $_t)"
    return 0
  done
  # v3.0.37 新平台（小米 15/17 等 OS4 机型，如 xuanyuan 诊断证实）：
  #   无 constant_charge_voltage / voltage_max 类节点 → 满电电压唯一权威是
  #   BAA 载荷 vterm → 改写载荷 vterm=设定值并重挂载（上调/下调都走此路径，真正生效）
  if [ "$_has_any" = "1" ]; then
    # v1.0.0：节流（用户真机 30s 轮询每轮都刷"节点均不可写"刷爆日志）
    # v1.0.1：节点存在但写失败 →【继续走载荷改写路径】——
    #   v3.00.39 起此处直接 return 1 导致 K70(vermeer) 等机型
    #   voltage_max=4.51V 被当"满充候选"→ 写失败后永远走不到载荷改写，
    #   fv_v 从不生效（用户真机 diag_1026 证实：无 fv_force_applied/无失败标记，
    #   状态永远"应用执行中"但什么都没做）。节点写失败与"无节点"同样应载荷改写。
    _lt=$(cat "$XBT/state/volt_nodefail" 2>/dev/null)
    case "$_lt" in ''|*[!0-9]*) _lt=0 ;; esac
    _nw=$(date +%s)
    if [ $((_nw - _lt)) -gt 600 ]; then
      log "volt: 满电电压节点存在但均不可写（fv_v=$_t 未生效，继续走载荷改写路径）"
      echo "$_nw" > "$XBT/state/volt_nodefail" 2>/dev/null
    fi
  fi
  # v1.0.1：节点写失败与"无节点"统一 fallthrough 到载荷改写（不再 return 1 放弃）
  # v3.00.39：设定值恰好 = 系统 vterm 上限 → 等于默认值，无需改写载荷
  if [ "$_mx" -gt 0 ] && [ "$_t" -eq "$_mx" ]; then
    log "volt: fv_v=$_t 等于系统最高满充电压 ${_mx}mV（默认值，无需改写载荷）"
    return 0
  fi
  log "volt: 无 constant_charge_voltage 类节点（新平台），改写 BAA 载荷 vterm=$_t mV"
  _apply_fv_force
  return $?
}

_apply_all() {
  _r1=0; _r2=0
  # v3.0.38：先做关机检测（电压 ≤ 阈值 → 模块执行关机），再应用/维持配置
  _check_term_shutdown
  [ -n "$TERM_V" ] && _apply_term; _r1=$?
  [ -n "$FV_V" ] && _apply_fv; _r2=$?
  [ "$_r1" = "0" ] || [ "$_r2" = "0" ]
}

# ---- 还原原始值（stop/卸载时）----
_restore() {
  # v3.0.38：软关机方案无写入节点，仅清理检测模式标记
  rm -f "$XBT/state/volt_term_mode" 2>/dev/null
  [ -f "$ORIG" ] || return 0
  while IFS='|' read -r _n _o _u; do
    [ -e "$_n" ] || continue
    case "$_o" in
      ''|*[!0-9]*) log "volt: $_n 无有效原始值，跳过还原" ;;
      *)
        if [ "$_u" = "uv" ]; then _w=$(( _o / 1000 )); else _w="$_o"; fi
        # 直接写回原始原文（避免单位换算二次失真）
        echo "$_o" > "$_n" 2>/dev/null && log "volt: 还原 $_n -> $_o"
        ;;
    esac
  done < "$ORIG"
}

# ---- 守护循环（30s 轮询，防系统覆盖）----
_spawn() {
  echo $$ > "$PIDFILE" 2>/dev/null   # 自己写 PIDFILE（v3.0.36：修复 start 阻塞卡死）
  _apply_all
  while true; do
    sleep 30
    _apply_all
  done
}

_volt_alive() {
  _p="$1"
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_p" 2>/dev/null || return 1
  _cl=$(timeout 1 cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')
  case "$_cl" in *volt_guard*) return 0 ;; esac
  return 1
}

start_guard() {
  # 未配置任何电压 → 不启动（等价于关闭）
  if [ -z "$TERM_V" ] && [ -z "$FV_V" ]; then
    log "volt: 未配置电压（term_v/fv_v 均为空），不启动"
    echo "not configured"
    return 0
  fi
  # v3.00.41 软停止：只 kill 旧守护、不还原载荷——
  #   否则 WebUI 每次点「应用」（即使值没变）都会触发 stop_guard 的 _restore_force
  #   还原载荷 + 重新加密 1~6 分钟，期间 status 显示"未生效"（用户 11:27:59 截图）。
  #   配置未变时新守护的 _apply_fv_force 幂等检查直接跳过 → 立即保持生效。
  _p=$(cat "$PIDFILE" 2>/dev/null)
  case "$_p" in ''|*[!0-9]*) : ;; *) kill -9 "$_p" 2>/dev/null ;; esac
  rm -f "$PIDFILE" 2>/dev/null
  _sum="volt: 守护启动 term_v=${TERM_V:-关}(mV) fv_v=${FV_V:-关}(mV) fv_force=$(cfg_get fv_force 0)（生效验证: sh volt_guard.sh status）"
  # v3.0.36：必须后台化（&）—— 之前 setsid/前台执行 _spawn 死循环，
  #   调用方 shR 永远等不到返回 → WebUI 一直"执行中"、其他功能排队卡死
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$XBT/scripts/volt_guard.sh" _spawn >/dev/null 2>&1 &
  else
    sh "$XBT/scripts/volt_guard.sh" _spawn >/dev/null 2>&1 &
  fi
  _t=0
  while [ "$_t" -lt 6 ]; do
    sleep 1; _t=$((_t+1))
    _p=$(cat "$PIDFILE" 2>/dev/null)
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    if _volt_alive "$_p"; then
      log "$_sum (pid $_p)"
      echo "started (pid $_p)"
      return 0
    fi
  done
  log "$_sum (守护进程已拉起)"
  echo "started"
  return 0
}

stop_guard() {
  if [ -f "$PIDFILE" ]; then
    _p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null
    rm -f "$PIDFILE"
  fi
  _restore
  _restore_force
  log "volt: stopped (restored)"
  echo "stopped"
}

# 验证节点当前值是否与设定值匹配（±2% 容差，与 _match 同标准）
_volt_verify() {
  _node="$1"; _unit="$2"; _want="$3"
  _cur=$(cat "$_node" 2>/dev/null | tr -d ' \n')
  case "$_cur" in ''|*[!0-9]*|0) return 1 ;; esac
  if [ "$_unit" = "uv" ]; then _cmp=$(( _cur / 1000 )); else _cmp=$_cur; fi
  _d=$(( _cmp - _want )); [ "${_d#-}" -le "$(( _want / 50 ))" ]
}

status_guard() {
  _tv=${TERM_V:-}; _fv=${FV_V:-}
  echo "term_v=${_tv:-关} | fv_v=${_fv:-关} | fv_force=$(cfg_get fv_force 0)"
  # 关机电压：开关 / 设定值 / 软件检测生效验证（v3.0.38：模块执行关机方案）
  if [ -n "$_tv" ]; then
    if [ -f "$XBT/state/volt_term_mode" ]; then
      _tn=$(cat "$XBT/state/volt_term_node" 2>/dev/null)
      _cur=$(cat "$_tn" 2>/dev/null | tr -d ' \n')
      case "$_cur" in ''|*[!0-9]*) _cur=0 ;; esac
      _vmv=$(( _cur / 1000 ))
      echo "【关机电压】已开启 阈值=${_tv}mV($((_tv/1000)).$((_tv%1000/100))V) 当前=${_vmv}mV ✓ 检测中（模块执行关机）"
    else
      echo "【关机电压】已开启 阈值=${_tv}mV ✗ 未找到可读电压节点（关机方案未启用）"
    fi
  else
    echo "【关机电压】未开启（默认行为）"
  fi
  # 满电电压：开关 / 设定值 / 生效验证（节点写入 或 新平台载荷改写）
  if [ -n "$_fv" ]; then
    _fn=$(cat "$XBT/state/volt_fv_node" 2>/dev/null)
    if [ -n "$_fn" ]; then
      _nd=${_fn%%|*}; _unit=${_fn##*|}
      _cur=$(cat "$_nd" 2>/dev/null | tr -d ' \n')
      if _volt_verify "$_nd" "$_unit" "$_fv"; then
        echo "【满电电压】已开启 设定=${_fv}mV($((_fv/1000)).$((_fv%1000/100))V) 节点:${_nd}=${_cur}(${_unit}) ✓ 生效"
      else
        echo "【满电电压】已开启 设定=${_fv}mV 节点:${_nd}=${_cur:-空} ✗ 未生效（节点值不匹配/被覆盖）"
      fi
    elif [ -f "$XBT/state/fv_force_applied" ]; then
      _fa=$(cat "$XBT/state/fv_force_applied" 2>/dev/null)
      _vmx=$(get_vterm_max 2>/dev/null)
      case "$_vmx" in ''|*[!0-9]*) _vmx=0 ;; esac
      if [ "$_vmx" -gt 0 ] && [ "$_fa" -gt "$_vmx" ] 2>/dev/null; then
        echo "【满电电压】已开启 设定=${_fv}mV($((_fv/1000)).$((_fv%1000/100))V) ⚠ 载荷已改写 vterm=${_fa}mV 超原厂上限 ${_vmx}mV（充电策略可能不跟进；若容量学习锁死请改回 ≤${_vmx}）"
      else
        echo "【满电电压】已开启 设定=${_fv}mV($((_fv/1000)).$((_fv%1000/100))V) ✓ 生效（改写 BAA 载荷 vterm=${_fa}mV）"
      fi
    else
      # v1.0.1：当前 ROM 无 BAA 载荷 → 如实提示不可用（不再显示误导的"应用执行中"）
      if [ -f "$XBT/state/no_baa" ]; then
        echo "【满电电压】已开启 设定=${_fv}mV($((_fv/1000)).$((_fv%1000/100))V) ✗ 当前 ROM 无 BAA 载荷（此机型电压改写不可用，恢复默认充电策略）"
      else
      # v3.00.41：区分「应用执行中」与「未生效」——载荷加密/重挂载约 1~6 分钟
      _vmx=$(get_vterm_max 2>/dev/null)
      if [ -n "$_vmx" ] && [ "$_vmx" != "$_fv" ]; then
        echo "【满电电压】已开启 设定=${_fv}mV($((_fv/1000)).$((_fv%1000/100))V) ⏳ 应用执行中（载荷加密/重挂载，约 1~6 分钟）"
      else
        echo "【满电电压】已开启 设定=${_fv}mV ✗ 未生效（未找到可写节点）"
      fi
      fi
    fi
  else
    echo "【满电电压】未开启（默认用 BAA 原值）"
  fi
  _fa=$(cat "$XBT/state/fv_force_applied" 2>/dev/null)
  [ -n "$_fa" ] && echo "⚠ 强制覆盖: 已改写载荷 vterm=${_fa}mV"
  if [ -f "$XBT/state/fv_force_fail" ]; then
    _ft=$(cat "$XBT/state/fv_force_fail" 2>/dev/null); case "$_ft" in ''|*[!0-9]*) _ft=0 ;; esac
    _now=$(date +%s 2>/dev/null); case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
    [ "$_now" -gt 0 ] && [ $((_now - _ft)) -lt 600 ] && echo "⚠ 载荷加密/挂载最近失败，退避中（10 分钟后自动重试）"
  fi
  _mx=$(get_vterm_max)
  [ -n "$_mx" ] && echo "系统最高满充电压(vterm): ${_mx}mV"
  if [ -f "$PIDFILE" ] && _volt_alive "$(cat "$PIDFILE" 2>/dev/null)"; then
    echo "守护: running (pid $(cat "$PIDFILE"))"
  else
    echo "守护: not running"
  fi
}

case "$1" in
  start) start_guard ;;
  _spawn) _spawn ;;
  stop) stop_guard ;;
  # 仅还原被强制改写过的 BAA 载荷，保留 fv_v/term_v 配置与守护（供 WebUI 关闭
  # 「强制覆盖原厂上限」时调用）
  restore_force) _restore_force ;;
  status) status_guard ;;
  *) echo "usage: $0 start|stop|status"; exit 9 ;;
esac
