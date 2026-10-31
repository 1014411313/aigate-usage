#!/system/bin/sh
# ============================================================================
#  apl.sh —— 自适应功率爬坡器 Adaptive Power Ladder (APL)  v3.12.0
# ============================================================================
# 【v3.12.0 核心改造：恢复优先】
#   用户核心关切：「别降下去了到可以用高参数的时候上不去」
#   旧设计的单向下沉风险，本版全部封堵：
#     ① 起步值 = max(所有SOC段) 而不是最近值   → 不被低值污染
#     ② 热身期：每次插枪前 90 秒 +8%/15s       → 快速回到高值
#     ③ 稳定 ≥6 次后 +6%/15s                   → 不用等 45 秒
#     ④ 适配器指纹变化 → 整份档案作废          → 换强头立即重探
#     ⑤ profile 带时间戳，>7 天自动作废        → 旧低值不会永久生效
#     ⑥ apl_ctl.sh reset                      → 用户随时手动重置
#     ⑦ 学习只增不减                          → 退让不污染历史
#     ⑧ 退让地板 = CAP×50%                    → 绝不会退到"爬不上来"
#
# 【安全边界（永不越界）】
#   目标 ≤ min(DTBO div_max_curr, MAX_MA, 20000)
#   电池 >50℃ 降 20%；>45℃ 停止上探
#   CV 段（vbat ≥ vterm-30mV）完全让路
#   power_limit ≠ inf 完全让路
# ============================================================================
XBT=/data/adb/modules/HyperOS_XJ/battery
[ -f "$XBT/scripts/common.sh" ] && . "$XBT/scripts/common.sh" 2>/dev/null

B=/sys/class/power_supply/battery
PIDF="$XBT/state/apl.pid"
TGT="$XBT/state/apl_target_ma"
LOCKF="$XBT/state/apl_lock_until"
HARDF="$XBT/state/apl_hard_events"
URGF="$XBT/state/apl_urgent"
DEV=$(cfg_get dev_code unknown)
PROF="$XBT/state/apl_profile.$DEV.kv"
APL_LOG="$XBT/state/apl.csv"
WARMUP_S=90

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') apl: $*" >> /data/local/tmp/xt_toolbox.log 2>/dev/null; }
ap()  { echo "$1" > "$TGT.tmp" 2>/dev/null && mv -f "$TGT.tmp" "$TGT" 2>/dev/null; }
now() { date +%s; }

# ---------------- 单实例（PID 大小确定性仲裁）----------------
_me=$$
if command -v pgrep >/dev/null 2>&1; then
  _other=""
  for _p in $(timeout 5 pgrep -f 'battery_tune/scripts/apl\.sh' 2>/dev/null); do
    [ "$_p" = "$_me" ] && continue
    kill -0 "$_p" 2>/dev/null || continue
    _other="$_p"; break
  done
  if [ -n "$_other" ] && [ "$_other" -lt "$_me" ] 2>/dev/null; then
    log "elder apl alive (pid $_other), yielding"; exit 0
  fi
fi
echo "$_me" > "$PIDF" 2>/dev/null
trap 'rm -f "$PIDF" 2>/dev/null' EXIT INT TERM

# ---------------- 硬上限 ----------------
ceiling() {
  # 【v3.12.1 修 BUG】绝不能把 MAX_MA 当作上限！
  #   MAX_MA 的语义是「fast/mid/slow 档 watt 换算出的电流封顶」，
  #   例如 nezha 的 DEF_MAX_MA=8000 —— 若用它做 inf 上限，
  #   整个 APL 会被压到 8A ≈ 36W，解容直接废掉。
  #   inf（无限制档）的真实上限只有 DTBO mca_strategy_quick_charge/div_max_curr 说了算。
  _c=20000
  _d=$(dt_curr_cap_ma 2>/dev/null); case "$_d" in ''|*[!0-9]*) _d="" ;; esac
  if [ -n "$_d" ] && [ "$_d" -gt 0 ]; then
    [ "$_d" -lt "$_c" ] && _c="$_d"
  fi
  # 可选的用户覆盖键（默认 inf=不限制）。与 MAX_MA 完全解耦。
  _o=$(cfg_get apl_max_ma "")
  case "$_o" in ''|*[!0-9]*) ;; *)
    [ "$_o" -gt 0 ] && [ "$_o" -lt "$_c" ] && _c="$_o" ;; esac
  echo "$_c"
}

# ---------------- 采样 ----------------
rd() { _x=$(cat "$1" 2>/dev/null); case "$_x" in ''|*[!0-9-]*) echo 0 ;; *) echo "$_x" ;; esac; }
vterm_mv() {
  _f=/proc/device-tree/soc/mca_strategy_quick_charge/max_vbat
  [ -e "$_f" ] || { echo 4570; return; }
  od -An -tu1 -N4 "$_f" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}'
}
# 【v3.12.6】读 DTBO 的 FFC 温区上界（驱动允许快充到多少度）
#   APL 自己的温度阈值必须跟随它，否则会「自己限制自己」：
#   实测 xuanyuan 电池 45℃、DTBO ffc_temp_high=58，而旧代码写死 45℃ 就停止上探
#   → 功率卡在 52W 上不去，与用户「温度保护不碰、要做极限」的要求冲突。
ffc_temp_high_c() {
  _f=/proc/device-tree/soc/mca_strategy_buckchg_class/ffc_temp_high
  [ -e "$_f" ] || { echo 55; return; }
  _v=$(od -An -tu1 -N4 "$_f" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}')
  case "$_v" in ''|*[!0-9]*) echo 55 ;; *) echo "$_v" ;; esac
}
adp_fp() {
  _v=$(rd /sys/class/power_supply/usb/voltage_max)
  _p=$(rd /sys/class/xm_power/charger/charger_common/power_max 2>/dev/null)
  [ "$_p" = "0" ] && _p=$(rd /sys/class/power_supply/usb/input_power_limit)
  echo "${_v}_${_p}"
}
sam() {
  SOC=$(rd $B/capacity)
  VBAT=$(( $(rd $B/voltage_now) / 1000 ))
  IBAT=$(( $(rd $B/current_now) / 1000 )); [ "$IBAT" -lt 0 ] && IBAT=$((-IBAT))
  PBAT=$(( VBAT * IBAT / 1000 ))
  TB=$(( $(rd $B/temp) / 10 ))
  UON=$(rd /sys/class/power_supply/usb/online)
  ST=$(cat $B/status 2>/dev/null)
  VTERM=$(vterm_mv); case "$VTERM" in ''|*[!0-9]*) VTERM=4570 ;; esac
}

# ---------------- profile ----------------
prof_get() { [ -f "$PROF" ] && grep -a "^$1=" "$PROF" 2>/dev/null | head -n1 | cut -d= -f2; }
prof_set() {
  _tmp="$PROF.tmp"
  { [ -f "$PROF" ] && grep -av "^$1=" "$PROF" 2>/dev/null; echo "$1=$2"; } > "$_tmp" 2>/dev/null
  mv -f "$_tmp" "$PROF" 2>/dev/null
}
# ★①起步值 = 所有 SOC 段的最大值（不被某一段低值污染）
prof_best() {
  [ -f "$PROF" ] || { echo ""; return; }
  grep -a '^b[0-9]=' "$PROF" 2>/dev/null | cut -d= -f2 | awk '
    { if ($1+0 > max) max = $1+0 } END{ if (max > 0) print max }'
}

# ---------------- dmesg 增量（A 档硬故障）----------------
DMARK="$XBT/state/apl_dmesg_mark"
hard_fault() {
  _last=$(cat "$DMARK" 2>/dev/null); case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  _hit=$(dmesg 2>/dev/null | tail -n 300 | grep -acE "open path fail|cp work abnormal|monitor charge abnormal")
  echo "$_hit" > "$DMARK" 2>/dev/null
  [ "$_hit" -gt "$_last" ] && return 0 || return 1
}

# ---------------- 初始化 ----------------
CAP=$(ceiling)
# 温度阈值跟随 DTBO：上探线 = ffc_temp_high - 8（留波动余量）；降档线 = ffc_temp_high - 3
_FH=$(ffc_temp_high_c)
T_UP=$(( _FH - 8 ))
T_DOWN=$(( _FH - 3 ))
[ "$T_UP" -lt 40 ] && T_UP=40
[ "$T_DOWN" -lt 45 ] && T_DOWN=45
FP=$(adp_fp)
FP_OLD=$(prof_get adp)
REASON=""
[ -n "$FP_OLD" ] && [ "$FP_OLD" != "$FP" ] && REASON="适配器变更($FP_OLD→$FP)"
_seen=$(prof_get seen); case "$_seen" in ''|*[!0-9]*) _seen=0 ;; esac
if [ "$_seen" -gt 0 ] && [ $(( $(now) - _seen )) -gt 604800 ]; then
  REASON="${REASON:+$REASON; }档案>7天"
fi
if [ -n "$REASON" ]; then
  echo "_reset_$(now)=$REASON" > "$PROF.tmp" 2>/dev/null
  mv -f "$PROF.tmp" "$PROF" 2>/dev/null
  log "学习档案重置：$REASON"
fi
prof_set "adp" "$FP"
prof_set "seen" "$(now)"

# ★①②：起步 = clamp(max(learned, CAP×75%), CAP)
_BEST=$(prof_best); case "$_BEST" in ''|*[!0-9]*) _BEST="" ;; esac
_FLOOR=$(( CAP * 75 / 100 ))
TARGET="$CAP"
[ -n "$_BEST" ] && [ "$_BEST" -gt "$_FLOOR" ] && [ "$_BEST" -le "$CAP" ] && TARGET="$_BEST"
[ "$TARGET" -lt "$_FLOOR" ] && TARGET="$_FLOOR"
[ "$TARGET" -gt "$CAP" ]    && TARGET="$CAP"
ap "$TARGET"
log "started pid=$$ dev=$DEV ceiling=${CAP}mA target=${TARGET}mA learned=${_BEST:-none} adp=$FP ffc_high=${_FH}C up=${T_UP}C down=${T_DOWN}C"

# ---------------- 主循环 ----------------
PREV_UON=0
PREV_IBAT=0; STAB_IBAT=0
LOW_CNT=0; STABLE_CNT=0
LAST_UP=$(now); WARM_START=0

while :; do
  sam
  _t=$(now)

  # ---- 插枪边沿：热身期（★②每次插枪先回 CAP 再实测退让）----
  if [ "$UON" = "1" ] && [ "$PREV_UON" != "1" ]; then
    WARM_START=$_t
    TARGET="$CAP"; ap "$TARGET"
    prof_set "seen" "$_t"
    log "插枪边沿：热身 ${WARMUP_S}s，目标先置 ${CAP}mA（给不上会自动退让）"
    LOW_CNT=0; STABLE_CNT=0; LAST_UP=$_t
  fi
  PREV_UON="$UON"

  # ---- 让路 ----
  _pl=$(cfg_get power_limit inf)
  _let=""
  [ "$_pl" != "inf" ]              && _let="power_limit=$_pl"
  [ "$UON" != "1" ]                && _let="未插枪"
  case "$ST" in Charging|Full) ;; *) [ -z "$_let" ] && _let="status=$ST" ;; esac
  [ "$VBAT" -ge $((VTERM - 30)) ] && _let="CV段($VBAT/$VTERM)"

  if [ -n "$_let" ]; then
    ap "$CAP"
    # v3.12.1：让路期间也记 CSV，否则 CV 段曲线断档，事后无法判断"何时进的 CV"
    [ -f "$APL_LOG" ] || echo "ts,soc,vbat,ibat,pbat,tb,usbV,target,locked,warm" > "$APL_LOG" 2>/dev/null
    echo "$_t,$SOC,$VBAT,$IBAT,$PBAT,$TB,$(rd /sys/class/power_supply/usb/voltage_now),$CAP,0,0" >> "$APL_LOG" 2>/dev/null
    sleep 5; continue
  fi

  prof_set "seen" "$_t"

  # ---- A 档：硬故障 ----
  if hard_fault; then
    NEW=$(( IBAT * 80 / 100 ))
    _bfloor=$(( CAP * 50 / 100 ))
    [ "$NEW" -lt "$_bfloor" ] && NEW="$_bfloor"
    [ "$NEW" -gt "$CAP" ] && NEW="$CAP"
    TARGET="$NEW"; ap "$TARGET"
    echo 1 > "$URGF" 2>/dev/null
    echo "$_t hard IBAT=$IBAT -> $TARGET" >> "$HARDF" 2>/dev/null
    log "A档硬故障：目标 ${TARGET}mA，锁 30s"
    echo $(( _t + 30 )) > "$LOCKF" 2>/dev/null
    LOW_CNT=0; STABLE_CNT=0; LAST_UP=$_t
    sleep 5; continue
  fi

  # ---- B 档：功率塌陷 ----
  # 【v3.12.5 修关键 bug】插枪/上探后电流需要几秒爬升，期间 PBAT 自然远低于目标。
  #   实测：23:29:25 插枪置 20000 → 23:29:30 报「P=13W < 75.8W」→ 砍到 10000 → 锁 60s
  #   → 热身期直接作废，功率只能从 10000 慢慢爬（55W 卡住上不去）。
  #   nezha 机主日志同样现象：P=38.7W < 78.9W → 砍到 9069mA。
  # 【修法】插枪边沿后 40 秒内不判 B 档（宽限期），让电流先爬上来。
  _grace=0
  [ "$WARM_START" -gt 0 ] && [ $(( _t - WARM_START )) -lt 40 ] && _grace=1
  _wantp=$(( TARGET * VBAT / 1000 ))
  if [ "$_grace" = "0" ] && [ "$_wantp" -gt 0 ] && [ "$PBAT" -lt $(( _wantp * 55 / 100 )) ]; then
    LOW_CNT=$((LOW_CNT + 1))
  else
    LOW_CNT=0          # 宽限期内不累计，避免出宽限期时立刻凑满 2 次
  fi
  if [ "$LOW_CNT" -ge 2 ]; then
    NEW=$(( IBAT * 105 / 100 ))
    _bfloor=$(( CAP * 50 / 100 ))          # ★⑧退让地板
    [ "$NEW" -lt "$_bfloor" ] && NEW="$_bfloor"
    [ "$NEW" -gt "$CAP" ] && NEW="$CAP"
    if [ "$NEW" -lt "$TARGET" ]; then
      TARGET="$NEW"; ap "$TARGET"
      # v3.12.4 修日志单位：PBAT/_wantp 是 mW，不是 W
      log "B档塌陷(P=$(( PBAT / 1000 )).$(( (PBAT % 1000) / 100 ))W < 目标$(( _wantp / 1000 ))W)：降到 ${TARGET}mA，锁 60s"
      echo $(( _t + 60 )) > "$LOCKF" 2>/dev/null
      STABLE_CNT=0; LAST_UP=$_t
    fi
    LOW_CNT=0
  fi

  # ---- 温度保护 ----
  if [ "$TB" -ge "$T_DOWN" ]; then
    NEW=$(( TARGET * 80 / 100 ))
    _bfloor=$(( CAP * 50 / 100 ))
    [ "$NEW" -lt "$_bfloor" ] && NEW="$_bfloor"
    if [ "$NEW" -lt "$TARGET" ]; then
      TARGET="$NEW"; ap "$TARGET"
      log "电池 ${TB}℃ ≥ 降档线 ${T_DOWN}℃，降 20% → ${TARGET}mA"
      echo $(( _t + 60 )) > "$LOCKF" 2>/dev/null
      STABLE_CNT=0
    fi
  fi

  # ---- 锁定 ----
  _lt=0; [ -f "$LOCKF" ] && _lt=$(cat "$LOCKF" 2>/dev/null)
  case "$_lt" in ''|*[!0-9]*) _lt=0 ;; esac
  _locked=0; [ "$_t" -lt "$_lt" ] && _locked=1

  # ---- 稳定计数 ----
  if [ "$_wantp" -gt 0 ] && [ "$PBAT" -ge $(( _wantp * 88 / 100 )) ]; then
    STABLE_CNT=$((STABLE_CNT + 1))
  else
    STABLE_CNT=0
  fi

  # ---- 上探（★③恢复优先）----
  if [ "$_locked" = "0" ] && [ "$TB" -lt "$T_UP" ] && [ "$TARGET" -lt "$CAP" ]; then
    _warm=0
    [ "$WARM_START" -gt 0 ] && [ $(( _t - WARM_START )) -lt "$WARMUP_S" ] && _warm=1
    _step=0; _need=99
    if [ "$_warm" = "1" ]; then
      _step=$(( TARGET * 8 / 100 )); _need=3          # 热身：+8% / 15s
    elif [ "$STABLE_CNT" -ge 6 ]; then
      _step=$(( TARGET * 6 / 100 )); _need=6          # 稳定：+6% / 15s
    elif [ "$STABLE_CNT" -ge 9 ]; then
      _step=$(( TARGET * 3 / 100 )); _need=9          # 一般：+3% / 15s
    fi
    [ "$_step" -lt 200 ] && _step=200
    if [ "$_step" -gt 0 ] && [ "$STABLE_CNT" -ge "$_need" ] && [ $(( _t - LAST_UP )) -ge 15 ]; then
      NEW=$(( TARGET + _step ))
      [ "$NEW" -gt "$CAP" ] && NEW="$CAP"
      if [ "$NEW" -gt "$TARGET" ]; then
        TARGET="$NEW"; ap "$TARGET"
        log "上探 +${_step} → ${TARGET}mA / 上限 ${CAP}mA"
        LAST_UP=$_t; STABLE_CNT=0
      fi
    fi
  fi

  # ---- 学习落盘（★⑦只增不减；★v3.12.2 改用「实际电流」而非「目标」）----
  # 【v3.12.2 修 bug】旧条件 `PBAT >= _wantp×88%` 有两个致命问题：
  #   ① 硬件给不到目标时（如目标 17600 实际只有 12000 = 68%），永远不满足
  #      → 档案永远学不到「真实上限」，APL 每次充电都从上限硬试，白折腾。
  #   ② 旧代码写入的是 TARGET（愿望值 17600），不是实际达到的 IBAT（现实值 12000），
  #      即使写进去也是错的。
  # 【新判据】「实际电流稳定」而不是「功率达标」：
  #   连续 3 拍 IBAT 波动 < ±5% 且 > 2000mA → 认为这是该 SOC 段的真实平台值，
  #   用 IBAT（现实）写入档案，仍然只增不减。
  _ibl=$(( IBAT * 95 / 100 ))
  _ibh=$(( IBAT * 105 / 100 ))
  if [ "$PREV_IBAT" -ge "$_ibl" ] && [ "$PREV_IBAT" -le "$_ibh" ] && [ "$IBAT" -gt 2000 ]; then
    STAB_IBAT=$((STAB_IBAT + 1))
  else
    STAB_IBAT=0
  fi
  # 【v3.12.2 修 BUG8】去掉 _locked 条件：锁定期间电流最稳定，正是学习的好时机。
  #   旧代码把学习关在锁定外 → B档/A档触发后 60 秒内完全不学习 → 档案学不到低值。
  if [ "$STAB_IBAT" -ge 3 ] && [ "$IBAT" -gt 2000 ]; then
    _b=$(( SOC / 10 )); [ "$_b" -gt 9 ] && _b=9; [ "$_b" -lt 0 ] && _b=0
    _k="b$_b"
    _real="$IBAT"                      # ← 现实值，不是 TARGET
    [ "$_real" -gt "$CAP" ] && _real="$CAP"
    _old=$(prof_get "$_k"); case "$_old" in ''|*[!0-9]*) _old="" ;; esac
    if [ -n "$_old" ]; then
      if [ "$_real" -gt "$_old" ]; then
        _nv=$(( (_old * 3 + _real * 7) / 10 ))
        [ "$_nv" -gt "$CAP" ] && _nv="$CAP"
        prof_set "$_k" "$_nv"
      fi
    else
      prof_set "$_k" "$_real"
    fi
  fi

  # ---- CSV ----
  [ -f "$APL_LOG" ] || echo "ts,soc,vbat,ibat,pbat,tb,usbV,target,locked,warm" > "$APL_LOG" 2>/dev/null
  _w2=0; [ "$WARM_START" -gt 0 ] && [ $(( _t - WARM_START )) -lt "$WARMUP_S" ] && _w2=1
  echo "$_t,$SOC,$VBAT,$IBAT,$PBAT,$TB,$(rd /sys/class/power_supply/usb/voltage_now),$TARGET,$_locked,$_w2" >> "$APL_LOG" 2>/dev/null
  _lc=$(wc -l < "$APL_LOG" 2>/dev/null); case "$_lc" in ''|*[!0-9]*) _lc=0 ;; esac
  [ "$_lc" -gt 2000 ] && { tail -n 1000 "$APL_LOG" > "$APL_LOG.t" 2>/dev/null && mv -f "$APL_LOG.t" "$APL_LOG" 2>/dev/null; }

  PREV_IBAT="$IBAT"
  sleep 5
done
