#!/system/bin/sh
# 电池解容工具箱 - 解容总开关
# 用法: unlock.sh status|on|off|sync|pss on|off|cycle [N|clear]
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh

show_status() {
  _u=$(cfg_get unlock 1)
  if [ "$_u" = "1" ]; then _us="开启"; else _us="关闭"; fi
  echo "解容开关 : $_us  (settings unlock=$_u)"
  echo "BAA挂载  : $(baa_state_cn)"
  echo "smart_fv : $(cat $FV_NODE 2>/dev/null)  [$(sh $XBT/scripts/fv_guard.sh status 2>/dev/null | head -n 1)]"
  echo "PSS服务  : $(pss_state)"
  echo "DTBO:"
  sh $XBT/scripts/dtbo.sh status 2>/dev/null | grep '^ *dtbo_' | sed 's/^/  /'
}

do_on() {
  cfg_set unlock 1
  log "unlock: ON"
  echo "-> 1/3 挂载 BAA 配置..."
  baa_refresh_src >/dev/null 2>>"$LOG"
  sh $XBT/scripts/baa_ops.sh mount
  _rc=$?
  _st=$(sh $XBT/scripts/baa_ops.sh check 2>/dev/null)
  if [ "$_st" = "active" ]; then echo "   OK: BAA已挂载(sha256+label校验通过) [$(baa_use_fmt)载荷]"
  elif [ "$_st" = "skipped" ]; then echo "   -: 系统BAA为空(魔改包特征)，已跳过挂载、保持系统原样"
  else echo "   ! mount返回码=$_rc,状态=$_st (也可重启后由service自动处理)"; fi
  echo "-> 2/3 启动 smart_fv 守护..."
  sh $XBT/scripts/fv_guard.sh start
  [ -n "$(cfg_get cycle_fake '')" ] && sh $XBT/scripts/cycle_guard.sh start
  echo "-> 3/3 低电量锁容服务(PSS)..."
  if [ "$(cfg_get pss_disable 1)" = "1" ]; then
    if [ "$(pss_state)" != "disabled" ]; then
      pm disable "$PSS" 2>/dev/null && { echo 1 > "$XBT/state/pss_disabled_by_module" 2>/dev/null; echo "   OK: 已禁用"; } || echo "   ! 禁用失败"
    else echo "   OK: 已是禁用状态"; fi
  else
    echo "   跳过(pss_disable=0，保留电池健康度显示)"
  fi
  setprop ctl.restart batteryantiaging 2>/dev/null && log "unlock: batteryantiaging restarted" || true
  echo
  echo "完成。建议重启手机以完全生效。"
}

do_off() {
  cfg_set unlock 0
  log "unlock: OFF"
  echo "-> 1/5 卸载 BAA 挂载..."
  # v2.7.13 修复：旧版不取返回码、无条件打印 OK —— umount 失败也被掩盖成成功。
  #   baa_ops.sh 在"当前 namespace 看不到挂载"时会走 no-op 且 exit 0，
  #   而缺 nsenter 的 ROM 上它会退化为当前 namespace → 关了但 BAA 仍挂载（"关了重启又开"的来源之一）。
  _uout=$(sh $XBT/scripts/baa_ops.sh umount 2>&1); _urc=$?
  _ust=$(sh $XBT/scripts/baa_ops.sh check 2>/dev/null)
  if [ "$_urc" = "0" ] && [ "$_ust" != "active" ]; then
    echo "   OK: BAA 已卸载 (状态=$_ust)"
  else
    echo "   ⚠ umount 返回码=$_urc，当前状态=$_ust"
    echo "$_uout" | tail -n 3 | sed 's/^/     /'
    echo "     若状态仍为 active，说明本 ROM 缺 nsenter 或挂载在别的 namespace；"
    echo "     重启后系统会自行读回官方配置。"
  fi

  echo "-> 2/5 关闭循环计数伪装..."
  # v2.7.13 关键修复（用户主诉「关了重启又自动开启」的根因）：
  #   旧版 do_off 只停 cycle_guard 进程，【不清 cycle_fake】。
  #   而 service.sh 开机只认 cycle_fake、不认 unlock →
  #   重启后循环伪装【自动复活】。
  _cf_before=$(cfg_get cycle_fake '')
  if [ -n "$_cf_before" ]; then
    cfg_set cycle_fake ''
    echo "   已清除 cycle_fake（原值 $_cf_before）→ 重启后不再伪装"
  else
    echo "   -: cycle_fake 本就为空，无需清除"
  fi

  echo "-> 3/5 停止守护进程..."
  sh $XBT/scripts/fv_guard.sh stop
  sh $XBT/scripts/cycle_guard.sh stop 2>/dev/null
  # v2.7.13：charge_guard 原本没有任何停止入口（全仓 grep 零命中），
  #   关掉解容后它仍以 1 秒周期写 wired_chg_curr 等节点 → 用户以为"关了"，实际还在控制。
  _cg_stop=$(sh $XBT/scripts/charge_guard.sh stop 2>&1); _cs_rc=$?
  if [ "$_cs_rc" = "0" ]; then
    echo "   OK: charge_guard 已停止"
  else
    echo "   ⚠ charge_guard 停止失败: $(echo "$_cg_stop" | tail -n 1)"
  fi

  echo "-> 4/5 恢复节点为系统默认..."
  # 解容关闭 = 不再由模块改写功率节点，交回内核/系统自行决定
  _restore=$(sh $XBT/scripts/power_limit.sh restore 2>&1); _rr=$?
  if [ "$_rr" = "0" ]; then echo "   OK: 已交回系统默认档位"; else echo "   ⚠ 恢复返回码=$_rr: $(echo "$_restore" | tail -n 1)"; fi

  echo "-> 5/5 恢复低电量锁容服务（如曾被本模块禁用）"
  # v2.9.10：关闭解容 = 恢复原厂行为。若 PSS 是本模块禁用的（有标记），必须还原，
  #   否则「电池健康度」会一直不显示（真机实测：PSS 禁用 → securitycenter.remote 不启动
  #   → BatteryHealthUtils 不运行 → 健康度无数据）。
  if [ "$(cat "$XBT/state/pss_disabled_by_module" 2>/dev/null)" = "1" ]; then
    pm enable "$PSS" 2>/dev/null
    cfg_set pss_disable 0 2>/dev/null
    rm -f "$XBT/state/pss_disabled_by_module" 2>/dev/null
    echo "   OK: 已重新启用 PowerSaveService（电池健康度恢复显示）"
  else
    echo "   -: PSS 未被本模块禁用，保持原状（当前 $(pss_state)）"
  fi

  echo "-> 恢复完成"
  echo "   dtbo 分区内容未改动；如需彻底恢复请用 DTBO 工具刷回原版。"
  echo
  echo "完成。建议重启手机以完全恢复官方充电策略。"
  echo "（重启后不会再自动开启：unlock=$(cfg_get unlock 0)、cycle_fake=$(cfg_get cycle_fake '(空)')）"
}

do_sync() {
  log "unlock: SYNC"
  echo "-> 重同步 BAA挂载..."
  baa_refresh_src >/dev/null 2>>"$LOG"
  sh $XBT/scripts/baa_ops.sh mount
  echo "-> 重启 smart_fv 守护..."
  sh $XBT/scripts/fv_guard.sh stop >/dev/null
  sh $XBT/scripts/fv_guard.sh start
  [ -n "$(cfg_get cycle_fake '')" ] && sh $XBT/scripts/cycle_guard.sh start >/dev/null 2>&1
  echo "OK"
}

do_pss() {
  # v2.9.10：CLI 开关必须【同时写配置】，否则重启后 service.sh 会按旧配置覆盖回去
  case "$1" in
    on)
      pm enable "$PSS" 2>/dev/null
      cfg_set pss_disable 0 2>/dev/null
      rm -f "$XBT/state/pss_disabled_by_module" 2>/dev/null
      echo "PSS now: $(pss_state)  (pss_disable=0，重启后保持；电池健康度可显示)"
      ;;
    off)
      pm disable "$PSS" 2>/dev/null
      cfg_set pss_disable 1 2>/dev/null
      echo 1 > "$XBT/state/pss_disabled_by_module" 2>/dev/null
      echo "PSS now: $(pss_state)  (pss_disable=1，重启后保持；⚠ 电池健康度将不显示)"
      ;;
    *) echo "用法: unlock.sh pss on|off" ;;
  esac
}

do_cycle() {
  _v="$1"
  if [ -z "$_v" ]; then
    echo "系统当前值: $(cat $CYCLE_NODE 2>/dev/null)"
    echo "开机维持值(cycle_fake): $(cfg_get cycle_fake '(空=不干预)')"
    echo "真实循环值(权威)  : $(cycle_real_read)   [来源 $(basename $CYCLE_REAL_NODE)]"
    echo "真实值记录文件    : $(cat $CYCLE_REAL_FILE 2>/dev/null || echo '(未记录)')"
    echo "其它节点交叉核对:"
    echo "  battery/cycle_count  = $(cat $CYCLE_NODE2 2>/dev/null)"
    echo "  qmax_cyclecount      = $(cat $CYCLE_REAL_NODE 2>/dev/null)"
    echo "循环守护  : $(sh $XBT/scripts/cycle_guard.sh status 2>/dev/null)"
  elif [ "$_v" = "clear" ]; then
    # v2.7：清除伪装并恢复到【真实】循环值
    #   旧版只从 last_real_cycle.txt 取，而该文件此前可能从未写入或被污染
    #   → 现在从 qmax_cyclecount 直接读权威真实值
    _rv=$(cycle_real_read)
    _rec=$(cat $CYCLE_REAL_FILE 2>/dev/null)
    case "$_rec" in ''|*[!0-9]*) _rec="" ;; esac
    cfg_set cycle_fake ""
    sh $XBT/scripts/cycle_guard.sh stop >/dev/null 2>&1
    if [ -n "$_rv" ]; then
      # 记录文件若为空或与真实值不一致（被伪装污染），一并纠正
      if [ "$_rec" != "$_rv" ]; then
        mkdir -p $XBT/state 2>/dev/null
        echo "$_rv" > $CYCLE_REAL_FILE 2>/dev/null
      fi
      chmod 666 $CYCLE_NODE 2>/dev/null
      echo "$_rv" > $CYCLE_NODE 2>/dev/null
      # v2.7.5 【X2 修复】：伪装时【两个节点都写】，清除时却只写回一个
      #   → battery/cycle_count 会一直停在伪装值直到重启（cycle_guard 已被 stop，
      #     没人纠正它），用户在系统设置里看到的仍是假值。这里两个都还原。
      if [ -n "$CYCLE_NODE2" ] && [ "$CYCLE_NODE2" != "$CYCLE_NODE" ]; then
        chmod 666 "$CYCLE_NODE2" 2>/dev/null
        echo "$_rv" > "$CYCLE_NODE2" 2>/dev/null
      fi
      _now=$(cat $CYCLE_NODE 2>/dev/null)
      _now2=$(cat "$CYCLE_NODE2" 2>/dev/null)
      echo "已清除循环伪装，并恢复真实值: $_rv（节点=$_now / 第二节点=$_now2）"
      log "cycle: cleared, restored real=$_rv (node=$_now node2=$_now2)"
    else
      echo "已清除循环伪装设置（未能读到真实值，重启后由 FG 自动恢复）"
    fi
  else
    case "$_v" in
      *[!0-9]*) echo "数值无效: $_v"; return 1 ;;
    esac
    # v2.7：拒绝 0 —— 实测 FG 把 0 当无效值，会立即写回真实循环数
    #   （xuanyuan 实测：写 0 后节点变 614）。若允许，配置=0 而节点=真实值，二者永久矛盾，
    #   后续 clear 还会把真实值恢复成 614。1~9999 均可正常伪装。
    if [ "$_v" = "0" ]; then
      echo "数值无效: 0（FG 不接受 0，会立刻写回真实值）"
      echo "  循环伪装请填 1 ~ 9999；要取消伪装请用「清除」（unlock.sh cycle clear）"
      return 1
    fi
    # v2.7.5 【修复范围校验】：原来的 `????*` 模式是【反的】——
    #   `????*` 匹配"≥4 个字符"，于是 1000~9999 全被拒（与上一行注释"1~9999 均可"矛盾），
    #   而 10000 以上（5+ 字符）反而被放行。现改为真正的 1~9999 区间校验。
    case "$_v" in
      [1-9]) ;;
      [1-9][0-9]) ;;
      [1-9][0-9][0-9]) ;;
      [1-9][0-9][0-9][0-9]) ;;
      *) echo "数值超出范围（1~9999）: $_v"; return 1 ;;
    esac
    # v2.7 关键修复：**先捕获真实值**，再写伪装值
    #   旧版直接覆盖节点，导致真实循环数永久丢失（用户反馈的根因）
    _rv=$(cycle_real_read)
    _rec=$(cat $CYCLE_REAL_FILE 2>/dev/null)
    case "$_rec" in ''|*[!0-9]*) _rec="" ;; esac
    if [ -n "$_rv" ] && [ "$_rec" != "$_rv" ]; then
      mkdir -p $XBT/state 2>/dev/null
      echo "$_rv" > $CYCLE_REAL_FILE 2>/dev/null
      log "cycle: real value captured before disguise: $_rv (prev record=[$_rec])"
    fi
    cfg_set cycle_fake "$_v"
    chmod 666 $CYCLE_NODE 2>/dev/null
    echo "$_v" > $CYCLE_NODE 2>/dev/null
    # 同步第二个节点（若可写）
    [ -e "$CYCLE_NODE2" ] && { chmod 666 "$CYCLE_NODE2" 2>/dev/null; echo "$_v" > "$CYCLE_NODE2" 2>/dev/null; }
    sh $XBT/scripts/cycle_guard.sh start >/dev/null 2>&1
    _now=$(cat $CYCLE_NODE 2>/dev/null)
    echo "已设置循环伪装值: $_v（当前节点=$_now）"
    if [ -n "$_rv" ]; then
      echo "真实循环值已记录: $_rv（关闭伪装或点「清除」可恢复）"
    else
      echo "! 未能读到真实循环值，请先关闭伪装并重启后重新设置，以免丢失原始值"
    fi
  fi
}

case "$1" in
  status) show_status ;;
  on) do_on ;;
  off) do_off ;;
  sync) do_sync ;;
  pss) do_pss "$2" ;;
  cycle) do_cycle "$2" ;;
  *) echo "用法: unlock.sh status|on|off|sync|pss on|off|cycle [N|clear]"; exit 9 ;;
esac