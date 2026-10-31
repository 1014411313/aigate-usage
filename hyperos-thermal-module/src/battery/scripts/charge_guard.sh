#!/system/bin/sh
# charge_guard.sh v2.1.1 - Scene 同源四路原生节点功率守护 + 闭环反馈限流（非inf档：读电池电流动态贴目标）
# 用法: charge_guard.sh once|watch|status
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh

BAT=/sys/class/power_supply/battery
ONCE="$1"
LAST_ST=""
LAST_KEY=""
LAST_MISSING=""
LAST_VOLT=""
TICKS=0

# ============================================================================
# 【v2.7.8 核心】全局限流写入间隔 —— 唯一可靠的防锯齿手段
# ============================================================================
# 【为什么必须做这一层】
#   v2.7.5 起我们用 inf_settle_ts 做"60 秒节流"，但那个文件会被【5 处清旗】删掉：
#     :离开inf档  :进入限流档  :开机  :charger event  →  删了之后再写就"立即通过"。
#   于是节流等于形同虚设：任何"切档/拔插/状态跳变"都能绕过 60 秒下限。
#
# 【两个真实触发场景】
#   ① 温控抖动：thermal_guard 触发→set slow（清旗）→ 恢复→set inf（立即写）；
#      温度在阈值附近来回 → 反复写 → 每次写都让 PMIC 重新协商 PD 契约 → 锯齿。
#   ② ★ ≥80% 电量：电池在 Charging ↔ Full 之间反复跳变（CV 段充满-停充-回落-补充，
#      周期 1~2 分钟）。:478 的 charger event 判据把这种跳变也当"拔插"处理 →
#      每次都清旗 → 每次都能立即写 → 反复重协商。
#      **这就是"低电量没事、80% 以上功率反而低且有波形"的机制。**
#
# 【做法】用一个【谁都不删】的时间戳做全局最小间隔。它只在卸载时清理。
#   任何写入路径（inf 安顿 / 兜底自纠正）都必须先通过这一关。
#   默认 60 秒；可用 settings 的 cg_min_write_gap 覆盖（排障用，改小会更激进）。
# ============================================================================
CG_GAP_DEFAULT=60

# cg_last_write_ts —— 上次"真正写电流节点"的时间戳（持久，跨事件不清）
CG_LAST_TS="$XBT/state/cg_last_write_ts"

# cg_gap_ok —— 返回 0 表示"距上次写入已超过最小间隔，允许写"
cg_gap_ok() {
  # ===== v3.11.0【APL 紧急通道】=====
  # APL 判定 A 档硬故障（open path fail / cp work abnormal）时写 state/apl_urgent，
  # 允许本次写节点绕过 60 秒全局限流，否则「立即退让」会被拖到最多 60 秒后才生效，
  # 波浪图会持续一整轮。
  # 该标志是【一次性】的：读到这里就删，保证只放行一次写入。
  if [ -f "$XBT/state/apl_urgent" ]; then
    rm -f "$XBT/state/apl_urgent" 2>/dev/null
    log "charge_guard: APL 紧急通道放行（绕过 cg_min_write_gap）"
    return 0
  fi
  _gap=$(cfg_get cg_min_write_gap "$CG_GAP_DEFAULT")
  case "$_gap" in ''|*[!0-9]*) _gap=$CG_GAP_DEFAULT ;; esac
  [ "$_gap" -gt 0 ] 2>/dev/null || _gap=$CG_GAP_DEFAULT
  _lw=$(cat "$CG_LAST_TS" 2>/dev/null)
  case "$_lw" in ''|*[!0-9]*) _lw=0 ;; esac
  [ "$_lw" = "0" ] && return 0          # 从未写过 → 放行
  # 【v2.7.8 实测修正】防"未来时间戳"与【Android shell 32 位溢出】
  #   实测：mksh/toybox 的 $(( )) 是 32 位算术。
  #     _now=1791262969, _lw=99999999999999 → $((_now - _lw)) 得到【正数 1514815738】
  #     （本应是负数）→ `-ge 60` 成立 → 绕过限流。
  #   触发条件：系统时间被回拨（NTP 校正 / 用户改时间 / 刷机后时间跳变）
  #   或时间戳文件损坏。不加保护会静默退化为"无节流"。
  #   做法：先比大小（纯字符串/算术比较都比减法安全），时间戳在未来就视为无效 → 清掉并放行。
  _now=$(date +%s)
  if [ "$_lw" -gt "$_now" ] 2>/dev/null; then
    rm -f "$CG_LAST_TS" 2>/dev/null
    return 0
  fi
  # 再做溢出保护：间隔只可能是"小的正数"，超过 1 年(31536000s)说明计数异常 → 视为过期
  _diff=$((_now - _lw))
  case "$_diff" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_diff" -ge "$_gap" ] && return 0
  return 1                              # 还在间隔内 → 拒绝
}

# cg_note_write —— 记录"刚刚写了电流节点"
cg_note_write() {
  date +%s > "$CG_LAST_TS" 2>/dev/null
}

# cg_gap_left —— 输出距离下次可写还有多少秒（日志用）
cg_gap_left() {
  _gap=$(cfg_get cg_min_write_gap "$CG_GAP_DEFAULT")
  case "$_gap" in ''|*[!0-9]*) _gap=$CG_GAP_DEFAULT ;; esac
  _lw=$(cat "$CG_LAST_TS" 2>/dev/null)
  case "$_lw" in ''|*[!0-9]*) _lw=0 ;; esac
  [ "$_lw" = "0" ] && { echo 0; return; }
  _now=$(date +%s)
  # 与 cg_gap_ok 同源保护：未来时间戳/32 位溢出都视为"可写"
  [ "$_lw" -gt "$_now" ] 2>/dev/null && { echo 0; return; }
  _diff=$((_now - _lw))
  case "$_diff" in ''|*[!0-9]*) echo 0; return ;; esac
  _d=$((_gap - _diff))
  [ "$_d" -lt 0 ] && _d=0
  echo "$_d"
}

# ---- 充电状态中文标注（v2.6.22l：给「实测」记录加充/放电标注，避免误读）----
chg_state_cn() {
  case "$(cat "$BAT/status" 2>/dev/null)" in
    Full) echo "已充满" ;;
    *Charging*) echo "充电中" ;;
    Discharging) echo "放电中" ;;
    *) echo "未充电" ;;
  esac
}

# ---- 闭环反馈限流（v2.1.1）----
# 非 inf 档：读电池实时电流，动态调节写入节点的电流值，使"电池电流"贴住档位目标
#   （系统步进会"顶高"节点：实测低值可压住、中值被顶；本闭环自动找"能压住的位置"）
CL_FILE="$XBT/state/closed_loop"
closed_loop_ma() {
  _tier="$1"
  _want=$(tier_target_ma "$_tier")
  case "$_want" in ''|*[!0-9]*) echo ""; return ;; esac
  # ★v3.9.4【严重 bug 修复】inf 档（= 无限制档）绝不能走闭环反馈！
  #   【实测故障】nezha / v3.9.3：wired_chg_curr 被写成 500000µA(500mA)，
  #     而目标 20000mA → 实际功率只剩 9.5W，持续 5 分钟不恢复。
  #   【机制】闭环在某个瞬间看到电池电流偏高 → ×80% 往下砍 → 砍进地板；
  #     之后每 2 秒只 +10%，从 500 爬回 20000 要 74 秒以上，
  #     期间还会被再次砍下去 → 永远上不来。
  #   【修法】inf 档语义就是"不限流"，直接返回目标值，完全不参与闭环微调。
  case "$_tier" in
    inf|INF|Inf|max|MAX)
      echo "${_tier}|${_want}" > "$CL_FILE" 2>/dev/null
      echo "$_want"
      return ;;
  esac
  _cache=$(cat "$CL_FILE" 2>/dev/null)
  # ★v3.9.0 修 bug：Android mksh 里 ${var%%|*} 的裸 | 会被当作模式运算符，
  #   实测 `${S%%|*}` 与 `${S##*|}` 都返回【空串】，导致缓存永远读不回来：
  #     _ct/_cn 恒为空 → 下面 [ "$_ct" = "$_tier" ] 永远不成立 → 每拍强制 _cn=_want
  #   ⇒ 闭环的 ±15% 自适应从来没生效过，一直退化成"固定写目标值"。
  #   修法：把模式里的 | 加双引号（实测 ${S%%"|"*} 正常）。
  #   （实测命令见 diag.sh F 段附近注释，或复现脚本：echo "/a|B" 后取 %%|* 得空）
  _ct=${_cache%%"|"*}
  _cn=${_cache#*"|"}
  case "$_cn" in ''|*[!0-9]*) _cn="$_want" ;; esac
  [ "$_ct" = "$_tier" ] || _cn="$_want"
  _i=$(cat "$BAT/current_now" 2>/dev/null)
  case "$_i" in ''|*[!0-9-]*) echo "$_cn"; return ;; esac
  # v2.7.4：未插枪时电池电流是【放电电流】，拿它做反馈会误判成"电流超标"而把 _cn 一路砍到
  #   地板（400mA）；下次插枪后要按 +10%/2s 慢慢爬回来（10W 档约 35~40 秒低功率）。
  #   未充电时直接返回目标值并重置缓存，插枪即以正确值起步。
  _st=$(cat "$BAT/status" 2>/dev/null)
  if [ "$_st" = "Discharging" ] || [ "$_st" = "Not charging" ]; then
    echo "${_tier}|${_want}" > "$CL_FILE" 2>/dev/null
    echo "$_want"
    return
  fi
  _i=${_i#-}
  _i=$((_i / 1000))
  # ★v3.9.4：偏离过大时【直接跳回目标】，不再爬升
  #   原来只有 +10%/2s，被砍狠了要几十秒才恢复，用户看到的就是"掉下去上不来"。
  #   _cn < _want/2 → 一次性置回 _want（下一拍若仍偏高再按 -20% 收敛）。
  if [ "$_cn" -lt $((_want / 2)) ]; then
    _cn="$_want"
  fi
  if [ $((TICKS % 2)) -eq 0 ]; then
    _hi=$((_want * 115 / 100))
    _lo=$((_want * 85 / 100))
    if [ "$_i" -gt "$_hi" ]; then
      _cn=$((_cn * 80 / 100))
    elif [ "$_i" -lt "$_lo" ]; then
      _cn=$((_cn * 110 / 100))
    fi
  fi
  # v2.7.4：封顶/地板原先在 even-tick 块【内】—— 目标调小时，奇拍会把上一拍的旧缓存
  #   （可能比新目标大一倍）原样写进节点，下一拍才压回。移到块外每拍都钳一次。
  [ "$_cn" -gt "$_want" ] && _cn="$_want"
  _floor=$((_want * 25 / 100))
  [ "$_floor" -lt 400 ] && _floor=400
  [ "$_cn" -lt "$_floor" ] && _cn="$_floor"
  echo "${_tier}|${_cn}" > "$CL_FILE" 2>/dev/null
  echo "$_cn"
}

apply_once() {
  # ===== v2.9.4 【死代码清理】=====
  # 旧实现：若 state/thermal_restore_active 存在则让 charge_guard 【永久静默】
  #   （apply_once 第一行就 return，用户选的档位完全不生效）。
  #   但全仓【没有任何地方写这个文件】（v2.7.4 的审计已指出它是历史遗留死开关，
  #   只有读 + 删），因此这里每秒做一次 stat、必要时 rm+log —— 纯空转。
  #   机制本身也已被档位驱动的 thermal_target() 取代（thermal_guard 靠改档位生效，
  #   不再需要"静默 charge_guard"）。
  #   【保留防御性自愈】万一旧版残留该文件，仍然清掉，但不再每 tick 检查：
  #   只在启动时由 service.sh / thermal_guard.sh 的既有 rm 语句清理。
  _sra="$XBT/state/thermal_restore_active"
  if [ -f "$_sra" ]; then
    rm -f "$_sra" 2>/dev/null
    log "charge_guard: removed stale thermal_restore_active (dead switch)"
  fi
  # v2.6.23：就绪判据改用「可写电流节点」而非「ctrl 阶梯节点」。
  #   common.sh 明确为非 mca_charger_thermal 内核/定制 ROM 准备了电池原生回退节点
  #   （constant_charge_current_max 等），并在 service.sh:110 也按电流节点判定可用；
  #   旧判据只认 ctrl_limit 节点，导致这类设备上守护每秒空转、永不施加限流（与 service.sh 自相矛盾）。
  #   单电流模式下 ctrl 节点本就写 0 且非必需，电流节点才是真正的执行手段。
  _cur_nodes=$(direct_current_nodes)
  if [ -z "$_cur_nodes" ]; then
    [ "$LAST_MISSING" = "1" ] || log "charge_guard: no writable current node"
    LAST_MISSING=1
    echo 0 > "$XBT/state/direct_control_active" 2>/dev/null
    return 1
  fi
  LAST_MISSING=0
  snapshot_current_limit
  snapshot_control_limit

  _mode=$(power_now)
  TICKS=$((TICKS + 1))
  _cl_active=""
  if [ "$POWER_MECH" = "curr" ] && [ "$_mode" != "inf" ] && [ "$(cfg_get closed_loop 1)" = "1" ]; then
    _cl_active=1
  fi

  # 【v2.7.5 关键】只要处于限流档，就清除 inf 的"已安顿"标志。
  #   必须放在【早退分支之前】—— 因为限流档稳态会走下面 139-144 的早退路径，
  #   若把清除放在"正在写节点"的分支里就永远执行不到（实测回归：切到 slow 后标志仍在
  #   → 切回 inf 时判定"已安顿"→ 不再补写 → 卡在 2400000µA 低功率）。
  #   放在这里保证"任何一轮处于限流档都会清标志"，成本只是一次文件存在性检查。
  #   v2.7.6：同时清 inf_settle_ts（补写节流时间戳）—— 否则切回 inf 时若 60 秒
  #   节流窗口还没过，会先卡在低功率最多 60 秒（v2.7.4 注释里提过同样的坑）。
  #   写法刻意保持朴素（不用 `{ }` 分组跟 && 组合，那个在部分 POSIX sh 上行为不确定）
  if [ "$_mode" != "inf" ]; then
    if [ -f "$XBT/state/inf_settled" ] || [ -f "$XBT/state/inf_settle_ts" ]; then
      rm -f "$XBT/state/inf_settled" "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" "$XBT/state/inf_settle_fail" 2>/dev/null
    fi
  fi

  if [ "$_cl_active" != "1" ] &&
    [ "$(cat "$XBT/state/power_mode_applied" 2>/dev/null)" = "$_mode" ] &&
    direct_tier_is_applied "$_mode"; then
    echo 1 > "$XBT/state/direct_control_active" 2>/dev/null
    return 0
  fi

  # v2.5.9 churn 监测：同档位尚未生效 → 需要重写。连续多次说明系统在抢节点。
  if [ "$(cat "$XBT/state/power_mode_applied" 2>/dev/null)" = "$_mode" ]; then
    _rs=$(cat "$XBT/state/rewrite_streak" 2>/dev/null)
    case "$_rs" in ''|*[!0-9]*) _rs=0 ;; esac
    _rs=$((_rs + 1))
    echo "$_rs" > "$XBT/state/rewrite_streak" 2>/dev/null
    case "$_rs" in
      5|20|60)
        # 单电流模式（curr）下逐秒重压是设计行为，不算 churn；仅旧 ctrl 机制保留告警
        [ "$POWER_MECH" = "curr" ] || log "charge_guard: WARN 档位 $(power_label) 连续重写 ${_rs} 次未稳定，可能有其它进程在改写节点(ctrl/thermal/curr)"
        ;;
    esac
  else
    echo 0 > "$XBT/state/rewrite_streak" 2>/dev/null
  fi

  _ok=""
  if [ "$_cl_active" = "1" ]; then
    # 闭环反馈限流：写入"自适应节点值"而非固定目标
    _v=$(closed_loop_ma "$_mode")
    case "$_v" in
      ''|*[!0-9]*) ;;
      *)
        # ===== v2.9.8【回退 v2.9.4 的节流 —— 它带来的危害大于收益】=====
        # 【背景】v2.7.4 这里是无条件 `direct_set_current_ma "$_v" 0`（每拍必写），
        #   用户反馈该版"功率限制没啥问题"。v2.9.4 为了"防 PD 重协商"加了
        #   ① TARGET 比对（_prev == _v 就跳过）② cg_gap_ok 60 秒全局限流。
        # 【实测证据 —— 闸门会被系统顶回】
        #   · 设 slow → 节点=2200000 th=0（正确）
        #   · T+2s → 节点被顶回 4300000；T+3s → **th 被顶回 1**（限流被静默解除）
        #   · 旧的 `_prev == _v` 只看"上次写的目标值"（TARGET 行），不看节点当下值
        #     → 系统顶回后仍判"已生效" → 加上 60 秒节流 → **一分钟才纠正一次**
        #     → 限流 97% 的时间处于失效态 → 用户报"怎么调都是最高功率"
        # 【实测证据 —— 节流想防的抖动根本不存在】
        #   手动每 1 秒强制写节点连续 12 次，实测：
        #     vbus 19487~19537 mV（波动 50mV）· ibus 3013~3118 mA（3.5%）
        #     real_type 全程 PD_PPS 不变 → **没有任何 PD 重协商抖动**
        #   ⇒ 节流保护的是一个不存在的风险，却把限流的自纠正能力砍掉了。
        # 【本版做法】恢复 v2.7.4 的"每拍写入"：`direct_set_current_ma` 一次同时写
        #   电流节点 + 闸门节点，闸门被顶回能在下一拍（≤2 秒）内纠正。
        #   保留 rewrite_streak 的 churn 监测（它只是记数，不影响写入）。
        if direct_set_current_ma "$_v" 0; then
          echo "$_mode" > "$XBT/state/power_mech_tier" 2>/dev/null
          echo 0 > "$XBT/state/rewrite_streak" 2>/dev/null
          case $((TICKS % 60)) in
            1)
              _mw=$(awk -v v="$(read_voltage_uv)" -v i="$(cat "$BAT/current_now" 2>/dev/null)" 'BEGIN{ if(i<0)i=-i; printf "%.1f", v*i/1e12 }')
              log "closed_loop: tier=$_mode node=$_v 实测=${_mw}W ($(chg_state_cn))"
              ;;
          esac
          _ok=1
        else
          if direct_set_tier "$_mode"; then
            _ok=1
          fi
        fi
        ;;
    esac
  else
    if [ "$_mode" = "inf" ]; then
      # ===== v2.7.3 关键修复：inf（全速）模式下【不写电流节点】=====
      # 【为什么】inf 的语义是"不做限流"。旧实现仍每秒把 wired_chg_curr 写成 20000 mA，
      #   而每次写该节点都会让 PMIC 重新协商 PD/PPS 契约 —— 适配器侧出现电压/电流抖动，
      #   表现为功率在 10~48W 之间来回锯齿（用户反馈"低电量时功率忽高忽低"，
      #   诊断包 dmesg 实测 vbus 4778~4957 mV、ibus 403~1594 mA 全在跳，chg_en=[0][term_recharge]）。
      #   inf 下模块真正该做的只有两件事：解除 DT 温控表（thermal_remove=1）+ 清 ctrl_limit=0。
      #   电流节点交给系统自己的快充算法去调（它本来就会随 SOC/温度步进）。
      #   顺带这也让 inf 档幂等 —— 不再需要"逐秒重压"，CPU/IO 开销也降下来。
      _th1=$([ "$(thermal_target)" = "1" ] && echo 1 || echo 0)

      # ---- (A) 闸门节点：只在"不对"时写 ----
      # 【v2.7.4 修正】补写电流节点**不能**绑在 _need 上（审计发现）：
      #   haotian/dada 上 wired_ctrl_limit 由系统每秒自行改写（本仓 common.sh 注释实测 0/11 跳），
      #   而 inf 的闸门判据恰要求 ctrl==0 → _need 每秒都是 1 → 若把补写放在 _need 分支里，
      #   就会每秒写一次 20A → **刚修掉的 PD 锯齿原样回来**。
      #   反之若无 thermal 节点则 _need 恒 0 → 补写永不执行 → 从限流档切回 inf 永久卡低功率。
      #   所以两件事必须解耦：闸门按需写；补写按"档位边沿"只做一次。
      _need=0
      for _p in $(direct_thermal_remove_nodes); do
        [ -e "$_p" ] || continue
        [ "$(cat "$_p" 2>/dev/null)" = "$_th1" ] || _need=1
      done
      for _p in $(direct_limit_nodes); do
        [ -e "$_p" ] || continue
        [ "$(cat "$_p" 2>/dev/null)" = "0" ] || _need=1
      done
      if [ "$_need" = "1" ]; then
        for _p in $(direct_thermal_remove_nodes); do
          [ -e "$_p" ] || continue
          chmod 664 "$_p" 2>/dev/null
          echo "$_th1" > "$_p" 2>/dev/null
        done
        for _p in $(direct_limit_nodes); do
          [ -e "$_p" ] || continue
          chmod 664 "$_p" 2>/dev/null
          echo 0 > "$_p" 2>/dev/null
        done
      fi

      # ---- (B) 电流节点：每次「进入 inf」只安顿一次，之后绝不再写 ----
      # 【v2.7.5 修复 —— 这是"充电功率 0W↔50W 锯齿"的真因】
      #   旧判据是「节点值 < 10A 就补写」，但这是错的：
      #     wired_chg_curr = 官方温控表的 9v_in/5v_in 列（适配器输入侧），
      #     **快充时系统本来就把这一列压在 500~6000mA**（官方 dtsi：9v_ichg 最大 3000mA，
      #     大电流走充电泵 div1/2/4）。所以"节点<10A"永远成立 → 反复补写 20000mA。
      #   更糟的是旧代码第 257 行「节点≥10A 就清节流时间戳」：
      #     写入后节点瞬间是 20000（≥10A）→ 时间戳被删 → 下一轮又能写 → **节流形同虚设**。
      #   实测证据（本机 xuanyuan v2.7.4 日志）：
      #     12:50:26 / 12:51:11 / 12:51:24 / 12:52:25 / 12:55:37 / 12:57:39 …… 共 59 次
      #     最短间隔 13 秒（60 秒节流完全失效）→ 每次写都触发 PMIC 重新协商 PD 契约
      #     → 用户功率图呈 0W↔50W 锯齿（周期约 40~50 秒）。
      #
      # 【新判据】用持久标志 state/inf_settled 做"进入 inf 的一次性安顿"：
      #   · 标志不存在 + 节点低  → 写一次并把标志置位（这就是"从限流档切回全速"的场景）
      #   · 标志已存在          → 绝不再写（稳态中节点高低由系统自决）
      #   · 离开 inf 档         → 清除标志，让下次进入还能安顿一次
      #   这样"从限流档切回全速会卡低功率"和"反复重写导致 PD 重协商"两个问题同时解决。
      #
      # 【v2.7.6 修复 —— v2.7.5 的"一次性安顿"会永久卡低功率】
      #   v2.7.5 有两个漏洞（实测确认）：
      #     ① 节点恰好 ≥10A 时走 else 分支【没写任何东西就标记已安顿】，
      #        之后系统把节点压下去 → 标志已存在 → 永久不补写。
      #     ② direct_set_current_ma 写入失败或被驱动顶回时【同样标记已安顿】。
      #   而 v2.7.4 靠「节点≥10A 就 rm state/inf_fix_ts」形成了几乎无节流的
      #   自纠正回路，所以不会卡住 —— 这就是用户反馈"2.7.5 之后功率没以前高"的根因。
      #   【本版做法】保留"防锯齿"，但恢复"自纠正"：
      #     · 只有【写入后回读确认节点确实被抬高】才落 inf_settled 标志；
      #     · 没写成/被顶回 → 不落标志，下一轮（带 60 秒节流）重试；
      #     · 节流时间戳每次真正尝试写入就更新 —— 所以最多 60 秒一次，
      #       不会回到 v2.7.4 那种 13 秒一次的 PD 重协商锯齿。
      _settled="$XBT/state/inf_settled"
      _settle_ts="$XBT/state/inf_settle_ts"
      # ★v3.9.6：已判定「本机型该节点不可控」（inf_node_capped）时，整段写入直接跳过。
      #   原条件只挡 inf_settled，而 inf_settled 会被「离开inf档/拔插/热回退/状变」等 5 处清旗；
      #   清掉后又会重新走「写3次→判失败→落旗」的循环。这里把 inf_node_capped 提为硬闸，
      #   任何清旗路径都不会再触发无效写入（thermal_remove=1 那一路不受影响，仍正常维护）。
      if [ "$_th1" = "1" ] && [ ! -f "$_settled" ] && [ ! -f "$XBT/state/inf_node_capped" ]; then
        _cur_ma=$(direct_node_read_ma_all 2>/dev/null)
        case "$_cur_ma" in ''|*[!0-9]*) _cur_ma=0 ;; esac
        # 未充电时不做安顿：此刻驱动给的默认值（xuanyuan 实测 22A）不代表插枪后能保持，
        #   写进去也会被插枪时的 PD 重协商清掉 —— 若此刻落旗就会永久卡住（v2.7.5 的坑）。
        case "$(cat "$BAT/status" 2>/dev/null)" in
          *Charging*|Full)
            if [ "$_cur_ma" -ge 10000 ]; then
              # 节点本就处于可用上限（如驱动默认 22A）→ 无需写任何东西。
              #   注意：这里【不算失败】。加 60 秒节流更新，配合周期性自纠正，
              #   万一之后被压下去也能自愈 —— 但绝不像 v2.7.5 那样"陈旧落旗后永久不写"。
              date +%s > "$_settle_ts" 2>/dev/null
            else
              # ---- 节点确实被压在低位 → 补写 ----
              # 【v2.7.8】两道闸：① cg_gap_ok 全局限流（谁都不清，唯一可靠下限）
              #                  ② inf_settle_ts 会话内节流（保留，语义更细）
              #   旧版只靠 ②，而 ② 的时间戳会被清旗路径删掉 → 等于没有下限保护。
              #   现在 ① 是硬下限：无论切档/拔插/状态跳变清了多少旗，
              #   两次真实写入之间都至少隔 cg_min_write_gap 秒（默认 60）。
              _last=$(cat "$_settle_ts" 2>/dev/null)
              case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
              _now=$(date +%s)
              if cg_gap_ok; then
                if [ $((_now - _last)) -ge 60 ]; then
                  _fm=$(tier_target_ma inf)
                  case "$_fm" in ''|*[!0-9]*) _fm=20000 ;; esac
                  direct_set_current_ma "$_fm" "$_th1" >/dev/null 2>&1
                  cg_note_write
                  echo "$_now" > "$_settle_ts" 2>/dev/null
                  _after=$(direct_node_read_ma_all 2>/dev/null)
                  case "$_after" in ''|*[!0-9]*) _after=0 ;; esac
                  _fc="$XBT/state/inf_settle_fail"
                  _fn=$(cat "$_fc" 2>/dev/null)
                  case "$_fn" in ''|*[!0-9]*) _fn=0 ;; esac
                  # 成功判据：写入后节点达到"可用上限"（≥10A）即算安顿完成。
                  #   · 写入被拒绝(0) / 被顶回低位 → 判失败，60 秒后重试（自纠正）
                  #   · 回读略低于目标（量化/裁剪，如 20000→19700）→ 仍算成功，不会刷屏
                  if [ "$_after" -ge 10000 ]; then
                    rm -f "$_fc" 2>/dev/null
                    rm -f "$XBT/state/inf_override_cnt" 2>/dev/null   # ★v3.9.6 成功安顿→重置"被接管"计数
                    echo "$_now" > "$_settled" 2>/dev/null
                    log "charge_guard: inf 安顿成功 (节点 $_cur_ma -> $_after mA，进入稳态后不再写)"
                  else
                    _fn=$((_fn + 1))
                    echo "$_fn" > "$_fc" 2>/dev/null
                    if [ "$_fn" -ge 3 ]; then
                      # 连试 3 次都抬不到 10A → 该机型的电流节点物理上限就低于 10A
                      #   （common.sh 的 constant_charge_current_max 回退路径，上限 1.6~3A；
                      #     或本机型该列是【适配器输入侧 9v_in/5v_in】，快充时本就 500~8000mA，
                      #     大电流走充电泵 div1/2/4 —— 实测 xuanyuan 充电中该列 500~8000mA）。
                      #   继续每 60 秒重写毫无意义且会持续触发 PD 重协商 + 刷日志 —— 落旗停手。
                      #
                      # 【v2.7.12 修复】必须同时写【机型标记】inf_node_capped，
                      #   否则下面的 300 秒自纠正会把 inf_settled 清掉 → 又走一遍
                      #   "写入 3 次失败 → 落旗" → 每 5 分钟触发一次 PD 重协商。
                      #   实测就是这样：日志里反复出现"自纠正→安顿成功(节点 500→17600)"
                      #   与"自纠正→安顿未生效"，白白制造 60 秒周期抖动。
                      echo "$_now" > "$_settled" 2>/dev/null
                      echo "$_after" > "$XBT/state/inf_node_capped" 2>/dev/null
                      log "charge_guard: inf 该机型电流节点上限 ${_after}mA(<10A)，已安顿(不再重试)"
                    else
                      log "charge_guard: inf 安顿未生效 (节点 $_cur_ma -> $_after mA)，60 秒后重试($_fn/3)"
                    fi
                  fi
                fi
              fi
            fi
            ;;
        esac
      fi

      # ---- 【v2.7.6 兜底】周期性自纠正：防 inf_settled 陈旧落旗导致永久低功率 ----
      #   【为什么需要】inf_settled 是【持久文件】，跨重启存在。旧版只在"离开 inf 档"时清旗，
      #   因此以下场景会永久卡住（都不需要异常操作）：
      #     · 拔插充电器 / PD 重协商把节点压到低位
      #     · 电池 ≥50℃ 热回退（闸门 1→0→1），降回后节点未被补写
      #     · 落旗时刻恰好没插枪
      #   本兜底每 300 秒只读复核一次：仅在【充电中 + 闸门已开 + 节点确实被压在低位 + 已落旗】
      #   时才清旗，让下一轮走正常的"节流写入 + 回读确认"路径。
      #   300 秒一次 = 把 v2.7.4 的 13 秒锯齿降级为 5 分钟一次，且只在真的坏掉时才触发。
      #   （此处已在 inf 分支内 —— 能走到这里说明 _mode 就是 inf，无需再判）
      if [ -f "$XBT/state/inf_settled" ]; then
        _sc_ts="$XBT/state/inf_selfcheck_ts"
        _sc_last=$(cat "$_sc_ts" 2>/dev/null)
        case "$_sc_last" in ''|*[!0-9]*) _sc_last=0 ;; esac
        _sc_now=$(date +%s)
        if [ $((_sc_now - _sc_last)) -ge 300 ]; then
          echo "$_sc_now" > "$_sc_ts" 2>/dev/null
          # 【v2.7.12 修复】已判定"本机型该列物理到不了 10A"时，自纠正必须停手，
          #   否则：清旗 → 下一轮又写 3 次失败 → 落旗 → 300 秒后再清旗 …… 死循环，
          #   每 5 分钟白白触发一次 PD 重协商（实测日志里反复出现的
          #   "自纠正 → 安顿成功/安顿未生效"就是这个循环）。
          if [ ! -f "$XBT/state/inf_node_capped" ]; then
            case "$(cat "$BAT/status" 2>/dev/null)" in
              *Charging*)
                if [ "$(cat "$XBT/state/direct_control_active" 2>/dev/null)" = "1" ]; then
                  _sc_ma=$(direct_node_read_ma_all 2>/dev/null)
                  case "$_sc_ma" in ''|*[!0-9]*) _sc_ma=0 ;; esac
                  if [ "$_sc_ma" -lt 10000 ]; then
                    # ★v3.9.6【判据修正】原来只看"写完回读≥10A 就算安顿成功"，
                    #   xuanyuan 实测：写完回读 17600 → 判成功落旗 → 系统几秒后把它压到
                    #   1000~8000 → 300 秒后这里看到节点低 → 清旗重写 → 每 5 分钟循环一次，
                    #   纯无效功（实测该节点值不限制实际电池电流：节点 1000mA 时电池仍 8.2A）。
                    #   现在统计「被系统接管」次数：连续 2 次 → 判定本机型该节点不可控，
                    #   落 inf_node_capped 彻底停手（复用现有"不再重试"机制，无新代码路径）。
                    #   thermal_remove=1（真正有效的那一项）不受影响。
                    _oc="$XBT/state/inf_override_cnt"
                    _ocn=$(cat "$_oc" 2>/dev/null)
                    case "$_ocn" in ''|*[!0-9]*) _ocn=0 ;; esac
                    _ocn=$((_ocn + 1))
                    echo "$_ocn" > "$_oc" 2>/dev/null
                    if [ "$_ocn" -ge 2 ]; then
                      echo "$_sc_ma" > "$XBT/state/inf_node_capped" 2>/dev/null
                      log "charge_guard: inf 节点被系统反复接管(${_ocn}次，当前${_sc_ma}mA) —— 判定本机型该节点不可控，本次开机停止后续写入（实测不影响实际充电电流）"
                    else
                      rm -f "$XBT/state/inf_settled" 2>/dev/null
                      log "charge_guard: inf 自纠正 —— 已落旗但节点仅 ${_sc_ma}mA，清旗重试补写($_ocn/2)"
                    fi
                  fi
                fi
                ;;
            esac
          fi
        fi
      fi

      # ---- 【v2.7.8】全局限流状态回显：让日志能一眼看出"距上次写还有多久" ----
      #   排障时最重要的一句话：功率低到底是"该写被节流挡住"，还是"写了没用"。
      #   每 300 秒最多打一行，且只在"确实被节流挡住"时打。
      if [ ! -f "$XBT/state/inf_settled" ]; then
        if ! cg_gap_ok; then
          _gl_ts="$XBT/state/cg_gap_log_ts"
          _gl_last=$(cat "$_gl_ts" 2>/dev/null)
          case "$_gl_last" in ''|*[!0-9]*) _gl_last=0 ;; esac
          _gl_now=$(date +%s)
          if [ $((_gl_now - _gl_last)) -ge 300 ]; then
            echo "$_gl_now" > "$_gl_ts" 2>/dev/null
            _gl_gap=$(cfg_get cg_min_write_gap "$CG_GAP_DEFAULT")
            case "$_gl_gap" in ''|*[!0-9]*) _gl_gap=$CG_GAP_DEFAULT ;; esac
            _gl_left=$(cg_gap_left)
            log "charge_guard: inf 补写被全局限流挡住（间隔 ${_gl_gap}s，还需 ${_gl_left}s）—— 静默等待，不做 PD 重协商"
          fi
        fi
      fi

      echo 1 > "$XBT/state/direct_control_active" 2>/dev/null
      echo "inf" > "$XBT/state/power_mode_applied" 2>/dev/null
      # v2.7.4：inf 稳态不给 rewrite_streak 累加（它表示"系统在抢节点"，inf 下无意义）
      echo 0 > "$XBT/state/rewrite_streak" 2>/dev/null
      LAST_KEY="inf"
      return 0
    fi
    # 进入限流档：清除"已安顿"标志与节流时间戳 —— 下次切回全速必须能【立即】再安顿一次
    rm -f "$XBT/state/inf_settled" "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" "$XBT/state/inf_settle_fail" 2>/dev/null
    if direct_set_tier "$_mode"; then
      _ok=1
    fi
  fi
  if [ "$_ok" = "1" ]; then
    echo 1 > "$XBT/state/direct_control_active" 2>/dev/null
    echo "$_mode" > "$XBT/state/power_mode_applied" 2>/dev/null
    if [ "$_mode" != "$LAST_KEY" ]; then
      _mw=$(awk -v v="$(read_voltage_uv)" -v i="$(cat "$BAT/current_now" 2>/dev/null)" 'BEGIN{ if(i<0)i=-i; printf "%.1f", v*i/1e12 }')
      log "charge_guard: tier=$(power_label) th=$(cat "$DIRECT_WIRED_THERMAL_REMOVE" 2>/dev/null) ctrl=$(cat "$DIRECT_WIRED_CTRL" 2>/dev/null) curr=$(cat "$DIRECT_WIRED" 2>/dev/null) 实测=${_mw}W ($(chg_state_cn))"
    fi
    LAST_KEY="$_mode"
    return 0
  fi

  echo 0 > "$XBT/state/direct_control_active" 2>/dev/null
  log "charge_guard: tier write failed mode=$_mode"
  return 1
}

show_status() {
  _mode=$(power_now)
  _v=$(read_voltage_uv)
  _i=$(cat "$BAT/current_now" 2>/dev/null)
  _st=$(cat "$BAT/status" 2>/dev/null)
  _tmp=$(cat "$BAT/temp" 2>/dev/null)
  _soc=$(cat "$BAT/capacity" 2>/dev/null)

  echo "充电模式 : $(power_label)"
  if [ -n "$_v" ] && [ -n "$_i" ]; then
    awk -v v="$_v" -v i="$_i" -v st="$(chg_state_cn)" 'BEGIN{ if(i<0)i=-i; printf "实测功率 : %.1f W (%s)\n", v*i/1e12, st}'
  fi
  if [ -n "$(direct_limit_nodes)" ]; then
    echo "内核旋钮 : thermal_remove=$(cat "$DIRECT_WIRED_THERMAL_REMOVE" 2>/dev/null) · ctrl_limit=$(cat "$DIRECT_WIRED_CTRL" 2>/dev/null)"
    echo "模式说明 : $(power_hint)"
  else
    echo "内核旋钮 : 未发现可写节点（需本机型内核支持）"
  fi
  printf "电池状态 : %s" "${_st:-未知}"
  [ -n "$_soc" ] && printf " · %s%%" "$_soc"
  if [ -n "$_tmp" ]; then
    awk -v t="$_tmp" 'BEGIN{printf " · %.1f°C", t/10}'
  fi
  echo
}

log "charge_guard: started (pid $$, once=$ONCE, v2.1.1, $(grep '^version=' $XBT/module.prop 2>/dev/null | cut -d= -f2), dev=$(cfg_get dev_code ''))"
case "$ONCE" in
  status)
    show_status
    exit 0
    ;;
  once)
    apply_once
    exit $?
    ;;
  stop)
    # ===== v2.7.13 新增：停止入口 =====
    # 【为什么必须加】旧版全仓没有任何"停止 charge_guard"的路径
    #   （grep 'charge_guard\.sh (stop|watch)' 零命中；主循环也不检查任何开关）。
    #   后果：用户关掉「电池解容」后，charge_guard 仍以 1 秒周期写 wired_chg_curr /
    #   wired_thermal_remove 等节点 → 用户以为"关了"，实际模块还在控制充电。
    # 实现：杀掉所有【长驻实例】（无参数调用），保留 once/status 短命调用不受影响。
    _n=0
    if command -v pgrep >/dev/null 2>&1; then
      for _p in $(timeout 5 pgrep -f 'HyperOS_XJ/battery/scripts/charge_guard\.sh' 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        _cl=$(timeout 1 cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')
        case "$_cl" in
          *charge_guard.sh\ status*|*charge_guard.sh\ once*|*charge_guard.sh\ stop*) continue ;;
        esac
        kill -TERM "$_p" 2>/dev/null && _n=$((_n + 1))
      done
      sleep 0.6
      # 复核：仍存活的强杀
      for _p in $(timeout 5 pgrep -f 'HyperOS_XJ/battery/scripts/charge_guard\.sh' 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        _cl=$(timeout 1 cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')
        case "$_cl" in
          *charge_guard.sh\ status*|*charge_guard.sh\ once*|*charge_guard.sh\ stop*) continue ;;
        esac
        kill -9 "$_p" 2>/dev/null
      done
    fi
    # 清掉"已安顿"类标志，避免下次启动时误判为已生效
    rm -f "$XBT/state/inf_settled" "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" 2>/dev/null
    log "charge_guard: stop -> killed $_n instance(s)"
    echo "charge_guard: 已停止 $_n 个长驻实例"
    exit 0
    ;;
esac

# ===== v2.7.3：长驻模式单实例锁（v2.7.4 加存活复核）=====
# 两个 charge_guard 同时跑 = 每秒各写一次充电节点 → 双重 PD 重协商 → 功率抖动加剧。
# service.sh 启动前会先 xbt_kill 旧实例，但【运行时手工重启/脚本重复调用】会累积。
#
# 【v2.7.4 关键修正】旧写法"看到别的 pid 就退出"有竞态（thermal_guard.sh 实测 T2/T3 复现过）：
#   service.sh 是 `xbt_kill` 之后【立刻】setsid 起新实例。若被 kill 的旧实例正卡在 sysfs/PMIC
#   写入（D 状态，模块自己记录过 /proc 读会永久阻塞），它尚未完全消失 → 新实例看到它 → 自杀
#   → **本次开机完全没有 charge_guard**（档位限流静默失效，只在日志留一行）。
#   修法与 thermal_guard 一致：先给旧实例 1.5 秒退场机会，并用 `kill -0` 复核存活，
#   只有确认它真的还活着才让位。
if command -v pgrep >/dev/null 2>&1; then
  _me=$$
  _other=""
  for _w in 1 2 3; do
    _other=""
    for _p in $(timeout 5 pgrep -f 'HyperOS_XJ/battery/scripts/charge_guard\.sh' 2>/dev/null); do
      [ "$_p" = "$_me" ] && continue
      kill -0 "$_p" 2>/dev/null || continue
      _cl=$(timeout 1 cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')
      # 只认"无参数的长驻实例"（带 once/status 参数的短命调用不算）
      case "$_cl" in
        *charge_guard.sh\ status*|*charge_guard.sh\ once*) ;;
        *charge_guard.sh*) _other="$_p" ;;
      esac
      [ -n "$_other" ] && break
    done
    [ -z "$_other" ] && break
    sleep 0.5
  done
  # ===== v3.12.1【修竞态】旧逻辑：谁看到别人就退出 =====
  #   若 A、B 同时启动（service.sh + 手工重启 / 升级脚本并发），
  #   A 看到 B 就 exit，B 看到 A 也 exit → **两个都死了** → 本次开机完全没有 charge_guard
  #   → 档位限流静默失效（用户只看到日志里一行 "yield"）。
  #   这与 v3.9.8 在 thermal_guard.sh 修的是同一个 bug，当时漏改了 charge_guard。
  # 【新逻辑】按 PID 大小确定性仲裁：PID 小的（先起的）胜出，大的让位。
  if [ -n "$_other" ] && [ "$_other" -lt "$_me" ] 2>/dev/null; then
    log "charge_guard: elder instance alive (pid $_other < $_me), yield self=$_me"
    exit 0
  elif [ -n "$_other" ]; then
    log "charge_guard: self=$_me takes over (younger $ _other=$_other will yield)"
  fi
fi

# 【v2.7.6】开机清理：inf 的"已安顿"标志是【跨重启持久】文件，但它描述的是"本充电会话内
#   已把节点安顿好"。重启后驱动会重置节点（实测 xuanyuan 重启后 wired_chg_curr 为驱动默认值），
#   留着旧标志 → inf 档开机即"自认已安顿"→ 永不补写 → 永久低功率。
#   这里在进入主循环前无条件清一次，保证每次开机都能重新安顿。
rm -f "$XBT/state/inf_settled" "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" "$XBT/state/inf_settle_fail" 2>/dev/null

# 【v3.9.5】写入 PID 文件，供 guard_watchdog.sh 判活。
#   看护脚本【只做 kill -0 <pid>】，完全不读 /proc/<pid>/cmdline ——
#   从根上避免 v3.4.0 那个「tr 裸读 proc cmdline 遇 ESRCH 死循环烧满单核」的 bug。
#   （旧版 guard_watchdog.sh:40 用 `tr '\0' ' ' < /proc/$_p/cmdline`，
#     pgrep -f 命中短命 fork 子 shell 后目标被回收 → 内核返回 -ESRCH →
#     toybox tr 只在 read()==0 退出，-1 时死循环重读 → 单核 100% + 看守卡死。
#     当时是删脚本了事，自愈功能也一起没了。本版改用 PID 文件彻底规避。）
mkdir -p "$XBT/state" 2>/dev/null
echo $$ > "$XBT/state/cg.pid" 2>/dev/null
date +%s > "$XBT/state/cg_started_ts" 2>/dev/null

while true; do
  apply_once
  # v2.9.10：每 15 拍（约 30 秒）检查一次 PSS 动态模式。
  #   仅在 pss_disable=1 且 pss_low_soc>0 时才真正动作（默认 pss_low_soc=0 → 空转）。
  #   它只读写 state/pss_dynamic 与 pm，不调昂贵的 dumpsys，开销可忽略。
  case $((TICKS % 15)) in 1) pss_guard_tick ;; esac
  # v3.0.1-xyexp-mix：每 300 拍（约 5 分钟）清一次卡死的 tr。
  #   挂在主循环而不是独立 subshell —— uninstall/stop 能随 charge_guard 一起结束，
  #   不会留后台孤儿（v3.4.4 的写法只在开机跑，运行期会复发）。
  case $((TICKS % 300)) in 1) xbt_clean_stuck_tr ;; esac
  _st=$(cat "$BAT/status" 2>/dev/null)
  # ★v3.8.5【自激震荡修复】统计 Discharging 持续的时长
  #   【现象】匹配 PPS 100W 充电器时，功率反复"上去-掉下来-再上去"。
  #   【机制】模块"inf 安顿"写 wired_chg_curr（17.6A/22A）→ 驱动回 chg_en:[0][vbat_ovp]
  #           （或 sw_cv_stop）→ 电流被砍到 100mA → battery/status 闪成 Discharging
  #           → 下面 _evt_real 判据看到 "上次是 Discharging" 就当【真拔插】→ 清 inf_settled
  #           → 60 秒后再写一次 → 再触发 OVP → 闭环震荡。
  #   实测 xuanyuan：10:57:08 写 → vbat_ovp → 10:58:04 清旗 → 10:58:11 又写。
  #   【修法】真拔枪时 Discharging 会持续几十秒以上；OVP/JEITA 抖动只有 1~2 秒。
  #           只有 Discharging 持续 ≥ DISC_MIN 秒（默认 5）才算真拔插事件。
  _now_t=$(date +%s)
  case "$_now_t" in ''|*[!0-9]*) _now_t=0 ;; esac
  if [ "$_st" = "Discharging" ]; then
    [ -z "$DISC_SINCE" ] && DISC_SINCE=$_now_t
    DISC_DUR=0
  elif [ -n "$DISC_SINCE" ]; then
    DISC_DUR=$((_now_t - DISC_SINCE))
  else
    DISC_DUR=-1                     # 上一轮不在放电（或首轮）
  fi
  if [ -n "$_st" ] && [ "$_st" != "Discharging" ] && [ "$_st" != "$LAST_ST" ]; then
    # 【v2.7.8 关键修正】区分"真拔插"与"CV 段抖动"
    #   【问题】旧判据把任何非 Discharging 的状态变化都当"拔插/重协商"处理并清旗。
    #     但 ≥80% 电量时电池会在 Charging ↔ Full 之间反复跳变（CV 段充满→停充→
    #     电压回落→补充，周期约 1~2 分钟）。每次跳变都清旗 → 每轮都能"立即写"
    #     → 每次写都让 PMIC 重新协商 PD 契约 → 功率塌陷再爬升 = 用户看到的波形。
    #     **这解释了"低电量没事、80% 以上反而有波形且功率低"。**
    #   【修法】只在以下情况清旗（真拔插/真重协商信号）：
    #     · 上一次是 Discharging 且【持续 ≥5 秒】（拔了又插）
    #     · 或本次是 Charging/Full 且状态跨度大
    #     Charging ↔ Full 之间的跳变【不清旗】—— 它不需要重新安顿节点，
    #     节点值在 CV 段本来就该由系统自决。
    DISC_MIN=$(cfg_get cg_disc_min_sec 5)
    case "$DISC_MIN" in ''|*[!0-9]*) DISC_MIN=5 ;; esac
    _evt_real=1
    case "$LAST_ST" in
      '') _evt_real=1 ;;                # 首轮
      Discharging)
        # ★只有放电持续够久才算真拔枪；OVP/JEITA 的 1~2 秒抖动不算
        if [ "$DISC_DUR" -ge "$DISC_MIN" ] 2>/dev/null || [ "$DISC_DUR" -lt 0 ] 2>/dev/null; then
          _evt_real=1
        else
          _evt_real=0
          log "charge_guard: 忽略短促状态抖动 (Discharging 仅 ${DISC_DUR}s < ${DISC_MIN}s) —— 判为 OVP/JEITA 抖动，不清安顿旗"
        fi
        ;;
      *)
        # 从一个"在充"状态到另一个"在充"状态（Charging↔Full）→ 抖动，不算真事件
        _evt_real=0
        ;;
    esac
    if [ "$_evt_real" = "1" ]; then
      log "charge_guard: charger event ($LAST_ST -> $_st), target=$(power_label)"
      # 【v2.7.6】充电状态变化 = 可能是拔插/PD 重协商，节点极可能被驱动重写。
      #   清掉 inf 的"已安顿"标志、节流时间戳、自检时间戳与失败计数 →
      #   下一轮重新"写入 + 回读确认"，否则旧标志会让模块永久不再补写
      #   （v2.7.5 的"inf 档功率上不去"）。失败计数必须一起清，
      #   否则陈旧的 3 次计数会让下一轮直接误判"该机型上限不足"而放弃。
      #   （拔枪本身不会写成"已安顿"：安顿路径要求 status 为 Charging/Full。）
      #   ★ 注意：cg_last_write_ts【不清】—— 那是全局限流下限，
      #     清了就等于"拔插可以绕过最小写入间隔"，锯齿会从这里回来。
      rm -f "$XBT/state/inf_settled" "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" "$XBT/state/inf_settle_fail" 2>/dev/null
    fi
  fi
  # 状态已切离 Discharging → 本次放电时长用完即弃，为重下一次充电做准备
  [ "$_st" != "Discharging" ] && DISC_SINCE=""
  LAST_ST="$_st"
  sleep 1
done