#!/system/bin/sh
# diag_log.sh — 电池解容工具箱 · 连续诊断记录器
# 用法: diag_log.sh start|stop|status|tail [n]|list|clear|pack|_run
XBT=/data/adb/modules/HyperOS_XJ/battery
[ -f "$XBT/scripts/common.sh" ] && . "$XBT/scripts/common.sh" 2>/dev/null
DIR=$XBT/state/diag
PIDF=$DIR/pid
CURF=$DIR/current_path
NODEF=$DIR/tracked_nodes.txt
INT=2      # 采样间隔（秒）
HB=15      # 每 N 次采样输出一次完整快照（约 30s）；有变化则即时记录
mkdir -p "$DIR" 2>/dev/null

ts() { date '+%F %T'; }

# 递归收集需要跟踪的节点（glob + [ -f ]，规避 toybox find 对 sysfs 的 -type 失效）
scan_collect() {
  _d="$1"; _n="$2"
  [ "$_n" -le 0 ] && return
  for _p in "$_d"/*; do
    [ -e "$_p" ] || continue
    if [ -d "$_p" ]; then
      scan_collect "$_p" $((_n - 1))
    else
      case "$_p" in
        *curr*|*current*|*limit*|*thermal*|*constant_charge*) echo "$_p" ;;
      esac
    fi
  done
}

build_nodes() {
  : > "$NODEF"
  for _p in \
    /sys/class/xm_power/charger/charger_thermal/wired_chg_curr \
    /sys/class/xm_power/charger/charger_thermal/wired_chg_curr2 \
    /sys/class/xm_power/charger/charger_thermal/wireless_chg_curr \
    /sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit \
    /sys/class/xm_power/charger/charger_thermal/wireless_ctrl_limit \
    /sys/class/xm_power/charger/charger_thermal/wired_thermal_remove; do
    [ -e "$_p" ] && echo "$_p" >> "$NODEF"
  done
  scan_collect /sys/class/xm_power 4 >> "$NODEF"
  scan_collect /sys/class/power_supply 2 >> "$NODEF"
  sort -u "$NODEF" -o "$NODEF" 2>/dev/null
}

# 采样一次：输出 "键|值" 行（节点 + 电池/USB 关键字段 + 模块内部状态）
sample_state() {
  _o="$1"; : > "$_o"
  if [ -s "$NODEF" ]; then
    while IFS= read -r _p; do
      [ -n "$_p" ] || continue
      printf '%s|%s\n' "$_p" "$(cat "$_p" 2>/dev/null)" >> "$_o"
    done < "$NODEF"
  fi
  for _k in battery/status battery/capacity battery/voltage_now battery/current_now \
            battery/current_avg battery/temp \
            usb/online usb/voltage_now usb/current_now; do
    printf '%s|%s\n' "$_k" "$(cat /sys/class/power_supply/$_k 2>/dev/null)" >> "$_o"
  done
  printf '%s|%s\n' "MODULE/power_limit" "$(cfg_get power_limit inf)" >> "$_o"
  printf '%s|%s\n' "MODULE/power_mode_applied" "$(cat "$XBT/state/power_mode_applied" 2>/dev/null)" >> "$_o"
  printf '%s|%s\n' "MODULE/direct_control_active" "$(cat "$XBT/state/direct_control_active" 2>/dev/null)" >> "$_o"
}

# 对比两次采样（同顺序，用单次 awk 逐行比较）
diff_state() {
  awk 'NR==FNR{p[FNR]=$0; next} { if (p[FNR]!=$0) print "  "p[FNR]"   ==>   "$0 }' "$1" "$2"
}

dump_full() {
  echo "$(ts) [快照 $3]" >> "$2"
  while IFS='|' read -r _k _v; do
    [ -n "$_k" ] || continue
    echo "  $_k = $_v" >> "$2"
  done < "$1"
}

run_logger() {
  build_nodes
  _sess="$DIR/diag_$(date +%Y%m%d-%H%M%S).log"
  echo "$_sess" > "$CURF"
  {
    echo "=================================================================="
    echo " 电池解容工具箱 · 连续诊断记录"
    echo " 开始   : $(ts)"
    echo " 机型   : $(getprop ro.product.model) / $(getprop ro.product.device)  slot=$(getprop ro.boot.slot_suffix)"
    echo " 系统   : Android $(getprop ro.build.version.release)(SDK $(getprop ro.build.version.sdk)) ROM $(getprop ro.mi.os.version.incremental)"
    echo " 内核   : $(uname -r)"
    echo " 模块   : $(grep '^version=' $XBT/module.prop 2>/dev/null | cut -d= -f2)  power_limit=$(cfg_get power_limit inf)  cloud_guard=$(cfg_get cloud_guard 1)"
    echo " 采样   : 每 ${INT}s 一次；每 ${HB} 次一次完整快照；有变化/状态切换即时记录"
    echo " 节点数 : $(wc -l < "$NODEF" 2>/dev/null)"
    echo "------------------------------------------------------------------"
    echo " [跟踪节点清单]"
    if [ -s "$NODEF" ]; then
      while IFS= read -r _p; do
        [ -n "$_p" ] || continue
        if [ -w "$_p" ]; then _w=yes; else _w=no; fi
        echo "  $_p  [writable=$_w] = $(cat "$_p" 2>/dev/null)"
      done < "$NODEF"
    else
      echo "  (未发现可跟踪节点)"
    fi
    echo "------------------------------------------------------------------"
  } >> "$_sess"

  _prev="$DIR/prev.state"
  _cur="$DIR/cur.state"
  sample_state "$_prev"
  _pst=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
  _n=0
  trap 'echo "$(ts) === 记录结束（收到停止信号）===" >> "$_sess"; exit 0' TERM INT
  while true; do
    sleep "$INT"
    _n=$((_n + 1))
    sample_state "$_cur"

    _st=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    if [ "$_st" != "$_pst" ]; then
      echo "$(ts) [事件] 充电状态: ${_pst:-?} -> ${_st:-?}" >> "$_sess"
      dump_full "$_cur" "$_sess" "#$_n 状态切换"
      cp -f "$_cur" "$_prev"
      _pst="$_st"
      continue
    fi

    _ch=$(diff_state "$_prev" "$_cur")
    if [ -n "$_ch" ]; then
      echo "$(ts) [变化 #$_n]" >> "$_sess"
      echo "$_ch" >> "$_sess"
      cp -f "$_cur" "$_prev"
    elif [ $((_n % HB)) -eq 0 ]; then
      dump_full "$_cur" "$_sess" "#$_n 心跳"
    fi
  done
}

case "$1" in
  start)
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
      echo "诊断记录已在运行 (pid $(cat "$PIDF"))"
      echo "日志: $(cat "$CURF" 2>/dev/null)"
      exit 0
    fi
    nohup sh "$0" _run >/dev/null 2>&1 &
    echo $! > "$PIDF"
    sleep 1
    echo "诊断记录已开启 (pid $(cat "$PIDF"))"
    echo "日志: $(cat "$CURF" 2>/dev/null)"
    ;;
  stop)
    if [ -f "$PIDF" ]; then
      _pid=$(cat "$PIDF")
      if kill -0 "$_pid" 2>/dev/null; then kill "$_pid" 2>/dev/null; echo "已停止 (pid $_pid)"; else echo "进程已不在，清理 pid"; fi
      rm -f "$PIDF"
    else
      echo "当前未在运行"
    fi
    _c=$(cat "$CURF" 2>/dev/null); [ -n "$_c" ] && echo "本次日志: $_c"
    ;;
  status)
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
      echo "状态: 运行中 (pid $(cat "$PIDF"))"
    else
      echo "状态: 未运行"
    fi
    _c=$(cat "$CURF" 2>/dev/null)
    [ -n "$_c" ] && [ -f "$_c" ] && echo "当前日志: $_c ($(wc -l < "$_c") 行, $(wc -c < "$_c") 字节)"
    echo "历史日志: $(ls -1 "$DIR"/diag_*.log 2>/dev/null | wc -l) 个"
    ;;
  tail)
    _n="${2:-60}"
    _c=$(cat "$CURF" 2>/dev/null)
    if [ -f "$_c" ]; then tail -n "$_n" "$_c"; else echo "(暂无日志)"; fi
    ;;
  list)
    ls -1 "$DIR"/diag_*.log 2>/dev/null || echo "(暂无日志)"
    ;;
  clear)
    sh "$0" stop >/dev/null 2>&1
    rm -f "$DIR"/diag_*.log "$DIR"/cur.state "$DIR"/prev.state "$CURF" 2>/dev/null
    echo "已清空所有诊断日志"
    ;;
  pack)
    _stamp="$(date +%Y%m%d-%H%M%S)"
    _dst="/sdcard/Download/电池解容诊断_$_stamp"
    mkdir -p "$_dst" 2>/dev/null
    _ver=$(grep '^version=' $XBT/module.prop 2>/dev/null | cut -d= -f2)
    # 0) 采集时间与场景说明（v2.7：便于作者对齐时间线）
    {
      echo "电池解容工具箱 诊断包"
      echo "采集时间 : $(ts)"
      echo "机型     : $(getprop ro.product.model) / $(getprop ro.product.device)"
      echo "模块版本 : ${_ver:-未知}    ★★★ 请务必保留此行 ★★★"
      echo "开机时长 : $(cut -d. -f1 /proc/uptime 2>/dev/null) 秒"
      echo
      echo "------------------------------------------------------------"
      echo "【给用户的提示】如果你用的不是最新版，问题可能已经修复了。"
      echo "  当前模块版本: ${_ver:-未知}"
      echo "  请先确认已更新到作者发布的最新版，再复现一次："
      echo "  若最新版仍能复现 -> 发诊断包给作者（这份就是）；"
      echo "  若最新版已不复现 -> 说明是老版本的已知问题，更新即可。"
      echo "------------------------------------------------------------"
      echo
      echo "【请补充以下信息，能大幅加快定位】"
      echo "  1. 你选的是哪个充电档位？(全速/快充/中速/慢充)"
      echo "  2. 问题现象是什么？(掉功率到多少W / 不充电 / 温度高 / 显示异常)"
      echo "  3. 电量(%)、电池温度、用的什么充电头和数据线"
      echo "     * 若是「功率上不去」，请写明充电头型号与标称功率"
      echo "  4. 问题发生时有没有：亮屏/玩游戏/边充边用/刚插上充电器"
      echo "  5. 拔插充电器后是否恢复？"
    } > "$_dst/采集说明_请补充信息.txt" 2>/dev/null
    # 1) 运行主日志（完整）
    cp -f "${LOG:-/data/local/tmp/xt_toolbox.log}" "$_dst/运行主日志.log" 2>/dev/null
    # 2) 连续诊断采样日志
    cp -f "$DIR"/diag_*.log "$_dst"/ 2>/dev/null
    # 3) 内核日志尾部（v2.7：300 → 800 行，掉功率类问题需要更长回溯窗口）
    dmesg 2>/dev/null | tail -n 800 > "$_dst/dmesg_尾800行.txt" 2>/dev/null
    [ -s "$_dst/dmesg_尾800行.txt" ] || rm -f "$_dst/dmesg_尾800行.txt" 2>/dev/null
    # 3b) 内核日志·充电相关筛选（v2.7 新增：直接给出契约状态机足迹）
    dmesg 2>/dev/null | grep -aE 'mca_quick_charge|mca_strategy_quick|mca_charger_thermal|mca_strategy_fg|pd_|pps|typec|tcpm|charger|vbus|ibat|adp_volt' \
      > "$_dst/dmesg_充电相关筛选.txt" 2>/dev/null
    [ -s "$_dst/dmesg_充电相关筛选.txt" ] || rm -f "$_dst/dmesg_充电相关筛选.txt" 2>/dev/null
    # 3c) 内核日志·错误筛选
    dmesg 2>/dev/null | grep -aiE 'err|fail|error|abnormal|over.?temp|OVP|OCP|timeout|reject|reset|retry|denied' | tail -n 150 \
      > "$_dst/dmesg_错误筛选.txt" 2>/dev/null
    [ -s "$_dst/dmesg_错误筛选.txt" ] || rm -f "$_dst/dmesg_错误筛选.txt" 2>/dev/null
    # 4) 当前状态快照（diag.sh，已含契约现场/驱动评估/时间线/守护核验）
    {
      echo "电池解容工具箱 诊断日志包"
      echo "导出   : $(ts)"
      echo "机型   : $(getprop ro.product.model) / $(getprop ro.product.device)"
      echo "模块   : $(grep '^version=' $XBT/module.prop 2>/dev/null | cut -d= -f2)"
      echo
      echo "--- 当前状态快照（diag.sh）---"
      sh "$XBT/scripts/diag.sh" 2>/dev/null
    } > "$_dst/当前状态快照.txt"
    # 5) 节点原始值快照（v2.7 新增：便于离线比对，不必让用户再跑命令）
    {
      echo "--- 充电/温控节点原始值快照 $(ts) ---"
      for _p in /sys/class/xm_power/charger/charger_thermal/*; do
        [ -f "$_p" ] && echo "$(basename $_p) = $(cat "$_p" 2>/dev/null)"
      done
      echo
      echo "--- 适配器/电池 ---"
      for _p in /sys/class/power_supply/usb/voltage_now /sys/class/power_supply/usb/current_now \
                /sys/class/power_supply/usb/voltage_max /sys/class/power_supply/usb/current_max \
                /sys/class/power_supply/usb/input_current_limit /sys/class/power_supply/usb/online \
                /sys/class/power_supply/usb/type /sys/class/power_supply/usb/usb_type \
                /sys/class/power_supply/battery/status /sys/class/power_supply/battery/voltage_now \
                /sys/class/power_supply/battery/current_now /sys/class/power_supply/battery/temp \
                /sys/class/power_supply/battery/capacity /sys/class/power_supply/battery/cycle_count; do
        [ -e "$_p" ] && echo "$(basename $_p) = $(cat "$_p" 2>/dev/null)"
      done
      echo
      echo "--- 适配器能力（v2.7.5 新增：判断『充电头能给多少』）---"
      echo "说明: apdo_max = PD 适配器自报的最大功率(W)，这是充电头的上限，不是手机的限制。"
      echo "      若此值就是 65/45/33 等，说明充电头只声明了这么多 -> 换原装头才能更高。"
      echo "      若此值为空但在充电 -> 充电头不支持 PD 上报（可能是纯 PPS/私有协议）。"
      for _p in /sys/class/power_supply/usb/voltage_max /sys/class/power_supply/usb/current_max; do
        _v=$(cat "$_p" 2>/dev/null)
        case "$_v" in ''|*[!0-9]*) ;; *) echo "  $(basename $_p) = $_v";; esac
      done
      _ui=$(cat /sys/class/power_supply/usb/current_max 2>/dev/null)
      _uv=$(cat /sys/class/power_supply/usb/voltage_max 2>/dev/null)
      case "$_ui" in ''|*[!0-9]*) _ui=0 ;; esac
      case "$_uv" in ''|*[!0-9]*) _uv=0 ;; esac
      [ "$_ui" -gt 0 ] && [ "$_uv" -gt 0 ] && \
        echo "  推算上限 = $(( _uv / 1000000 )).$(( (_uv % 1000000) / 100000 ))V x $(( _ui / 1000000 )).$(( (_ui % 1000000) / 100000 ))A = 约 $(( _uv / 1000000 * _ui / 1000000 ))W"
      echo "  --- dmesg 里的 PD 源能力（apdo_max / keep_report_max）---"
      dmesg 2>/dev/null | grep -aE 'apdo_max|keep_report_max|pd_class_sysfs_show' | tail -n 6 | sed 's/^/    /'
      echo "  --- PD 类型变化 ---"
      dmesg 2>/dev/null | grep -aE 'update_usb_pd_type|real_type changed' | tail -n 6 | sed 's/^/    /'
      echo "  --- typec / PPS ---"
      for _p in /sys/class/typec/port0/power_role /sys/class/typec/port0/data_role \
                /sys/class/typec/port0/usb_power_delivery_revision; do
        [ -e "$_p" ] && echo "  $(basename $_p) = $(cat "$_p" 2>/dev/null)"
      done
      echo
      # ============ v2.7.7 新增：PPS / PD 协议专段 ============
      # 【为什么需要】公版PPS解锁（FreePPS）唯一的动作是写 pd_verifed=1。
      #   诊断如果不采这个节点，作者【无法判断】用户是否开了 PPS、
      #   以及他说的"官方头只有 PD / 功率上不去"到底是头的问题还是 PPS 的副作用。
      #   实测踩坑：开了 PPS + 用官方头（官方头走小米私有协议，不协商 PPS）
      #   → 报的是 PD，功率拿不满，用户以为是模块坏了。
      echo "--- ★ PPS / PD 协议现场（v2.7.7 新增）---"
      _pv1=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)
      _pv2=$(cat /sys/class/Charging_Adapter/pd_adapter/usbpd_verifed 2>/dev/null)
      echo "  pd_verifed (qcom-battery)          = [${_pv1:-无此节点}]"
      echo "  usbpd_verifed (Charging_Adapter)   = [${_pv2:-无此节点}]"
      echo "  real_type (charger_common)         = [$(cat /sys/class/xm_power/charger/charger_common/real_type 2>/dev/null)]"
      echo "  usb/real_type                      = [$(cat /sys/class/power_supply/usb/real_type 2>/dev/null)]"
      echo "  usb/type                           = [$(cat /sys/class/power_supply/usb/type 2>/dev/null)]"
      echo "  apdo_max (适配器自报最大功率 W)     = [$(cat /sys/class/xm_power/typec/apdo_max 2>/dev/null)]"
      echo "  adapter_svid (PD 认证标识)         = [$(cat /sys/class/xm_power/typec/strategy_pd_auth/adapter_svid 2>/dev/null)]"
      echo "  --- 公版PPS（FreePPS）运行状态 ---"
      echo "  settings freepps                   = [$(cfg_get freepps 0)]"
      echo "  运行时 free 文件                   = [$(cat /data/adb/modules/freepps/free 2>/dev/null)]  (1=锁定 / 0=暂停)"
      echo "  disable 文件                       = $([ -f /data/adb/modules/freepps/disable ] && echo '存在(模块被禁用)' || echo '无')"
      _fpc=0
      for _p in /proc/[0-9]*; do
        case "$(timeout 1 cat $_p/cmdline 2>/dev/null | tr '\0' ' ')" in
          *HyperOS_XJ/battery/bin/freepps*) _fpc=$((_fpc + 1)) ;;
        esac
      done
      echo "  freepps 进程数                     = $_fpc"
      echo "  --- 判读（重要）---"
      echo "  · pd_verifed=1 的含义：模块【伪造了「PD 已验证」】，让不支持小米金标协议的"
      echo "    第三方 PD/PPS 充电器不被限功率。它是 FreePPS 的唯一动作，与真实协议无关。"
      case "$_fpc" in
        0) if [ "$(cfg_get freepps 0)" = "1" ]; then
             echo "  ⚠ 配置已开但【进程未运行】→ pd_verifed 不会被还原/锁定，建议重开一次开关"
           else
             echo "  ✔ 进程未运行（配置为关，正常）"
           fi ;;
        *) if [ "$(cfg_get freepps 0)" = "1" ]; then
             echo "  ✔ 公版PPS已开启且进程在跑"
           else
             echo "  ⚠ 【配置为关但进程在跑】→ 请关一次再开，或重启；否则 pd_verifed 可能不一致"
           fi ;;
      esac
      case "$_pv1" in
        1) if [ "$(cfg_get freepps 0)" = "0" ]; then
             echo "  ⚠ pd_verifed 仍为 1 但 PPS 配置是关 → 可能【残留】（进程死掉时不会自动还原）"
             echo "     → 处理：重开一次 PPS 开关再关，或重启；否则官方头的 PD 判断会失真"
           fi ;;
      esac
      echo "  · 【什么时候该开 PPS】"
      echo "      - 第三方 PD/PPS 充电器（酷态科等）功率上不去 → 开"
      echo "      - 官方小米充电头 → 走小米私有协议，不协商公版 PPS"
      echo "        （官方 100W 以下的头可能被激活为 PPS 档位，但那是适配器行为，与开关无关）"
      echo "        → 不需要开；若已开且感觉功率异常，先关掉再对比"
      echo "  · 【官方头插上后的正常现象】real_type/usb_type 报 PD、apdo_max 是头自报值"
      echo "      —— 这不代表「模块判断错误」，是官方头本来就只走 PD/私有协议"
      echo
      echo "--- 模块 state 目录 ---"
      for _p in "$XBT"/state/*; do
        [ -f "$_p" ] && echo "$(basename $_p) = $(cat "$_p" 2>/dev/null | head -c 120 | tr '\n' ' ')"
      done
      echo
      echo "--- 配置（非注释行）---"
      grep -vE '^[[:space:]]*#' "$XBT/config/settings.conf" 2>/dev/null | grep -vE '^[[:space:]]*$'
    } > "$_dst/节点原始值快照.txt" 2>/dev/null
    # 6) v3.0.6：包内文件清单（防止人工二次压缩丢文件）
    #    【为什么加】作者收到过 3 个 zip 包，每个都只有 6 个文件，比模块产出的少一个
    #    『节点原始值快照.txt』—— 说明中间被解压后重新压缩过（文件管理器"压缩"）。
    #    丢了那个文件，作者就没法离线比对节点原始值，只能从 dmesg 反推，多花好几轮。
    #    这里在包里放一份清单，写明"本次实际打了哪些文件 + 每个多大"，
    #    压缩后少了哪个一眼就能看出来。
    #    注意：基础文件是 7 个，但 diag_*.log（连续诊断采样）只在开启过连续记录时才存在，
    #    所以清单必须按【实际内容】生成，不能写死数量。
    _base="采集说明_请补充信息.txt 运行主日志.log 当前状态快照.txt 节点原始值快照.txt dmesg_尾800行.txt dmesg_充电相关筛选.txt dmesg_错误筛选.txt"
    _dn=0
    for _b in $_base; do [ -f "$_dst/$_b" ] && _dn=$((_dn + 1)); done
    _elist=$(ls "$_dst" 2>/dev/null | grep -E '^diag_.*\.log$')
    _en=0
    [ -n "$_elist" ] && _en=$(echo "$_elist" | wc -l)
    {
      echo "电池解容工具箱 诊断包 · 文件清单（请勿删除本文件）"
      echo "生成时间 : $(ts)"
      echo "机型     : $(getprop ro.product.model) / $(getprop ro.product.device)"
      echo "模块版本 : ${_ver:-未知}"
      echo
      echo "★★ 请【直接把模块生成的 .tar.gz 原文件】发给作者 ★★"
      echo "   不要在手机上解压后再重新压缩 —— 实测人工重压会漏文件"
      echo "   （作者收到过只有 6 个文件的 zip，缺了『节点原始值快照.txt』）"
      echo
      echo "本次实际打包内容（共 $((_dn + _en + 1)) 个文件，含本清单）："
      for _b in $_base; do
        if [ -f "$_dst/$_b" ]; then
          echo "  ✔ $_b  ($(stat -c %s "$_dst/$_b" 2>/dev/null) B)"
        else
          echo "  ✘ $_b  ← 本次缺失（正常应存在，请把本清单一起发给作者）"
        fi
      done
      if [ -n "$_elist" ]; then
        for _e in $_elist; do
          echo "  ✔ $_e  (连续诊断采样, $(stat -c %s "$_dst/$_e" 2>/dev/null) B)"
        done
      else
        echo "  （无 diag_*.log —— 未开启过连续诊断记录，属正常）"
      fi
      echo
      echo "基础文件应为 7 个，另可带若干 diag_*.log。本次基础文件命中 $_dn/7 个。"
      if [ "$_dn" -lt 7 ]; then
        echo
        echo "⚠⚠ 基础文件不足 7 个 —— 生成阶段就有缺失，请把本清单一起发作者。"
      fi
    } > "$_dst/_文件清单_请勿删.txt" 2>/dev/null

    # 7) v3.0.6：自动打包成 tar.gz（三档回退）
    #    【v3.0.6 修复】v2.7.5 起就有三档回退，但旧代码把 tar 的 stderr 全吞了
    #    （2>/dev/null），失败时一律说「环境无 tar」——即使 tar 存在但执行失败
    #    （/sdcard 权限、中文名编码、空间不足）也这么说，排查时严重误导。
    #    现在保留真实错误，并区分「没有 tar」与「tar 执行失败」。
    _tgz="/sdcard/Download/电池解容诊断_$_stamp.tar.gz"
    _packed=0
    _how=""
    _err=""
    if command -v tar >/dev/null 2>&1; then
      _te=$(tar -czf "$_tgz" -C /sdcard/Download "电池解容诊断_$_stamp" 2>&1)
      if [ -s "$_tgz" ]; then
        _packed=1; _how="系统 tar"
      else
        _err="系统 tar 执行失败: ${_te:-无输出}"
      fi
    else
      _err="系统没有 tar 命令"
    fi
    if [ "$_packed" != "1" ] && [ -x /data/adb/ksu/bin/busybox ]; then
      _te=$(/data/adb/ksu/bin/busybox tar -czf "$_tgz" -C /sdcard/Download "电池解容诊断_$_stamp" 2>&1)
      if [ -s "$_tgz" ]; then
        _packed=1; _how="KernelSU busybox tar"; _err=""
      else
        _err="$_err ｜ ksu busybox tar 失败: ${_te:-无输出}"
      fi
    fi
    if [ "$_packed" != "1" ] && [ -x /data/adb/magisk/busybox ]; then
      _te=$(/data/adb/magisk/busybox tar -czf "$_tgz" -C /sdcard/Download "电池解容诊断_$_stamp" 2>&1)
      if [ -s "$_tgz" ]; then
        _packed=1; _how="Magisk busybox tar"; _err=""
      else
        _err="$_err ｜ magisk busybox tar 失败: ${_te:-无输出}"
      fi
    fi
    echo "已导出到: $_dst"
    if [ "$_packed" = "1" ]; then
      # 打包成功 -> 删掉散装目录，只留压缩包（避免用户发错）
      _tsz=$(stat -c %s "$_tgz" 2>/dev/null)
      _nf=$(ls "$_dst" 2>/dev/null | wc -l)
      rm -rf "$_dst" 2>/dev/null
      echo "已自动打包($_how): $_tgz  (${_tsz:-?} 字节, ${_nf:-?} 个文件)"
      echo "★ 直接把上面这个 .tar.gz 文件发给我即可（无需自己压缩）"
      echo "  （解压后应有 ${_nf:-?} 个文件，含 _文件清单_请勿删.txt；人工重压会丢文件）"
    else
      echo "⚠ 自动打包失败，已保留散装文件夹（数据不会丢）：$_dst"
      echo "  原因: $(echo "${_err:-未知}" | head -c 300)"
      echo "  → 请把【整个文件夹】压缩后发送（.tar.gz / .zip 都可以）"
      echo "  → 压缩后请对照文件夹内 _文件清单_请勿删.txt，确认文件齐全"
    fi
    echo
    echo "提示: 若能在【问题正在发生的那一刻】导出，诊断价值最高。"
    ;;
  _run)
    run_logger
    ;;
  *)
    echo "用法: sh diag_log.sh start|stop|status|tail [n]|list|clear|pack"
    ;;
esac