#!/system/bin/sh
# 电池解容工具箱 公共函数库

XBT=/data/adb/modules/HyperOS_XJ/battery
CONF=$XBT/config/settings.conf
LOG=/data/local/tmp/xt_toolbox.log
# 机型代号: 安装时由 customize.sh 写入 (xuanyuan|dada|haotian|nezha|myron|annibale|bixi|onyx|popsicle|miro|songyuan|warsaw|pudding|pandora|byron)；缺失时回退 xuanyuan
DEV_CODE=$(grep -E '^dev_code=' "$CONF" 2>/dev/null | tail -n 1 | cut -d= -f2-)
case "$DEV_CODE" in
  xuanyuan) DEV_NAME="小米15 Ultra" ;;
  dada)     DEV_NAME="小米15" ;;
  haotian)  DEV_NAME="小米15 Pro" ;;
  nezha)    DEV_NAME="小米17 Ultra" ;;
  myron)    DEV_NAME="Redmi K90 Pro Max" ;;
  annibale) DEV_NAME="Redmi K90" ;;
  bixi) DEV_NAME="小米 MIX Flip2" ;;
  onyx) DEV_NAME="Redmi Turbo 4 Pro" ;;
  popsicle) DEV_NAME="小米17 Pro Max" ;;
  miro)     DEV_NAME="Redmi K80 Pro" ;;
  songyuan) DEV_NAME="Redmi K100 Pro Max" ;;
  warsaw)   DEV_NAME="Redmi K90 Ultra" ;;
  pudding) DEV_NAME="小米17" ;;
  pandora) DEV_NAME="小米17 Pro" ;;
  byron)    DEV_NAME="小米17 Max" ;;
  *)
    # ===== 安全兜底 =====
    # 【旧行为】未知机型 → DEV_CODE=xuanyuan，这是【危险】的：
    #   customize.sh 会把 getprop ro.product.device 原样写进 dev_code，
    #   未知机型装上后会被当成 xuanyuan → 刷入【xuanyuan 的 DTBO】
    #   → 不匹配的 DTBO 可能导致无法开机。
    # 【新行为】标记 unsupported：不刷 DTBO、不挂 BAA，只保留纯软件功能。
    DEV_CODE=unsupported
    DEV_NAME="未知机型（未支持）"
    ;;
esac
# 未知机型：跳过一切镜像/BAA 相关动作，避免刷错
# v2.9.10：改成显式赋值（原来只 `&& IS_UNSUPPORTED=1`，同一进程内若 dev_code 从
#   unsupported 修正为正式机型后再 source，会残留 IS_UNSUPPORTED=1 → 明明支持却跳过
#   DTBO/BAA。虽然正常流程每个脚本都是新进程，但热重载/调试时踩到过，故改为双分支。）
if [ "$DEV_CODE" = "unsupported" ]; then
  IS_UNSUPPORTED=1
else
  IS_UNSUPPORTED=0
fi
# 机型最大有线功率(W)：inf 档对外展示为「<W>W MAX」
# 与 customize.sh 的 _PW / webroot 的 MAXW 表保持一致
case "$DEV_CODE" in
  myron|annibale|popsicle|songyuan|warsaw|pudding|pandora|byron) DEV_MAXW=100 ;;
  miro) DEV_MAXW=120 ;;
  bixi) DEV_MAXW=67 ;;
  unsupported) DEV_MAXW=0 ;;
  *) DEV_MAXW=90 ;;
esac

# ============================================================================
# 卡死 `tr` 清理（v3.0.1-xyexp-mix）
#   根因：读 /proc/<pid>/cmdline 时目标进程恰好退出 → read 永久阻塞 → 裸 tr 卡死烧 CPU
#         → 设备进不了 Doze → 待机大量掉电（实测单条 tr 烧 5 小时 CPU）
#   判据：ppid=1（父 shell 已退出=孤儿）且 累计 CPU ≥ 600s
#         —— 正常 tr 活不到 10 分钟 CPU，两条件同时满足才动手，不会误杀
#   调用点：service.sh 开机一次 / charge_guard.sh 主循环每 300 拍一次
# ============================================================================
xbt_clean_stuck_tr() {
  _killed=0
  for _tp in $(pgrep -x tr 2>/dev/null); do
    [ -r "/proc/$_tp/stat" ] || continue
    _ppid=$(awk '{print $4}' "/proc/$_tp/stat" 2>/dev/null)
    _cpu=$(awk '{print $14+$15}' "/proc/$_tp/stat" 2>/dev/null)
    case "$_ppid$_cpu" in ''|*[!0-9]*) continue ;; esac
    if [ "$_ppid" = "1" ] && [ "$_cpu" -ge 600 ]; then
      kill -9 "$_tp" 2>/dev/null && _killed=$((_killed + 1))
    fi
  done
  [ "$_killed" -gt 0 ] && log "xbt: 清理卡死 tr $_killed 个（孤儿+CPU>=600s）"
  return 0
}

# ===== 机型功率参数表（适配 15 / 15Pro 只需在此改一行）=====
#   FAST_W/MID_W/SLOW_W  : 「单电流模式」下 fast/mid/slow 档的目标瓦数（按实时电压换算为电流；
#                          实测电池电流≈节点电流，线性精确，全机型通用，一般无需按机型区分）
#   MAX_MA               : 电流安全上限（mA），fast/mid/slow 写入电流的钳制上限。已知交付硬顶 ≈8A(xuanyuan) / 8A(haotian) / 12.4A(dada)，xuanyuan/haotian 已按硬顶设 8000；miro=10250 / songyuan=9200 / warsaw=9000 / pudding=9200（按 div_single_curr÷2 推导，2026-09-27）；其余待真机标定
#   MID_CTRL / SLOW_CTRL : 旧 ctrl 阶梯机制（POWER_MECH=ctrl 时用，fast 沿用 mid 的档位值；已被系统改写干扰，仅作兼容保留）
# 可在 settings.conf 用 mid_ctrl/slow_ctrl/fast_w/mid_w/slow_w/max_ma 覆盖做现场标定。
case "$DEV_CODE" in
  xuanyuan) DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=8000  ; DEF_THERMAL_CEIL=580 ;;
  haotian)  DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=8000  ; DEF_THERMAL_CEIL=580 ;;
  dada)     DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=12000 ; DEF_THERMAL_CEIL=580 ;;
  nezha)    DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=8000  ; DEF_THERMAL_CEIL=580 ;;
  myron)    DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=9000  ; DEF_THERMAL_CEIL=580 ;;
  annibale) DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=9000  ; DEF_THERMAL_CEIL=580 ;;
  bixi)     DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=6500  ; DEF_THERMAL_CEIL=580 ;;
  onyx)     DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=8000  ; DEF_THERMAL_CEIL=580 ;;
  popsicle) DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=9000  ; DEF_THERMAL_CEIL=580 ;;
  miro)     DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=10250 ; DEF_THERMAL_CEIL=580 ;;
  songyuan) DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=9200  ; DEF_THERMAL_CEIL=580 ;;
  warsaw)   DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=9000  ; DEF_THERMAL_CEIL=580 ;;
  pudding)  DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=9200  ; DEF_THERMAL_CEIL=580 ;;
  pandora)  DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=9000  ; DEF_THERMAL_CEIL=580 ;;
  byron)    DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=9200  ; DEF_THERMAL_CEIL=580 ;;
  unsupported) DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=6800 ; DEF_THERMAL_CEIL=580 ;;
  *)        DEF_MID_CTRL=4; DEF_SLOW_CTRL=14; DEF_MID_W=25; DEF_SLOW_W=10; DEF_MAX_MA=6800  ; DEF_THERMAL_CEIL=580 ;;
esac
# fast（40W）档默认目标功率（全机型统一；写入电流受 max_ma/硬顶钳制，可 settings 覆盖 fast_w）
DEF_FAST_W=40
BAA_SRC=$XBT/baa/payload_BAA_config_$DEV_CODE.json
BAA_STOCK=$XBT/baa/stock_BAA_config_$DEV_CODE.json
BAA_TGT=/odm/etc/charger/BAA_config_$DEV_CODE.json
BAA_LABEL=u:object_r:batteryantiaging_cfg_file:s0
FV_NODE=/sys/class/xm_power/charger/smart_charge/smart_fv
PSS=com.miui.securitycenter/com.miui.powercenter.provider.PowerSaveService

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
hash_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# ===== v2.7 移植性：确保 state 目录存在 =====
# 【为什么需要】全新（纯净）安装时，customize.sh 只在"检测到旧版本可迁移"的分支里
#   才 mkdir state（见 customize.sh:91 / 123），首装不会创建。而多个脚本会直接写
#   $XBT/state/*（thermal_prev / last_real_cycle.txt / fv_default / direct_*_defaults …），
#   目录不存在时写入静默失败 → 温控"保护前档位"丢失、真实循环值无法记录。
#   这里在 common.sh 被加载时就兜底创建，任何 source 它的脚本都直接安全。
[ -d "$XBT/state" ] || mkdir -p "$XBT/state" 2>/dev/null

# ===== v2.7 移植性：timeout 兜底 =====
# 【为什么需要】部分脚本用 `timeout` 防止读 /proc/<pid>/cmdline 永久阻塞。
#   但 `timeout` 是 toybox 命令，部分老设备 / 精简 ROM / 魔改系统里**可能不存在**。
#   若不存在且不兜底，会静默失效（命令根本没执行 → 检测返回空 → 守护以为没在跑 → 重复启动）。
#
# 【两级策略】
#  ① 关键路径（xbt_pids 的进程检测）改用 `pgrep`——**pgrep 是原子操作，本身不会阻塞，
#     根本不需要 timeout 包裹**。这样进程检测不依赖 timeout 是否存在。
#  ② 仅 /proc 兜底读 cmdline 这种确实可能阻塞的地方才用 $XBT_TIMEOUT。
#
# 探测可用的 timeout（优先系统 > KernelSU busybox > Magisk busybox > 系统 busybox）
XBT_TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
  XBT_TIMEOUT="timeout"
elif [ -x /data/adb/ksu/bin/busybox ]; then
  XBT_TIMEOUT="/data/adb/ksu/bin/busybox timeout"
elif [ -x /data/adb/magisk/busybox ]; then
  XBT_TIMEOUT="/data/adb/magisk/busybox timeout"
elif command -v busybox >/dev/null 2>&1; then
  XBT_TIMEOUT="busybox timeout"
fi
# 用法：$XBT_TIMEOUT <秒> <命令...>；无 timeout 时退化为直接执行（无超时保护但不失效）
_xbt_run() {
  # $1 = 秒数，其余为命令
  _secs="$1"; shift
  if [ -n "$XBT_TIMEOUT" ]; then
    $XBT_TIMEOUT "$_secs" "$@"
  else
    "$@"
  fi
}
# 通用兜底：若系统完全没有 timeout，就定义一个 shell 函数顶上。
#   这样其它脚本里原有的 `timeout 5 xxx` 调用（9 个脚本 20+ 处）无需逐个改动即可工作。
#   注意：函数只在当前 shell 有效，而脚本都会 `. common.sh`，覆盖面无问题。
if [ -z "$XBT_TIMEOUT" ]; then
  timeout() { shift; "$@"; }
fi

# ===== v2.6.23 安全进程管理 =====
# 【为什么必须用 pgrep 而不是扫 /proc】
#   旧实现在多处使用 `for p in /proc/[0-9]*; do tr '\0' ' ' < $p/cmdline; done`。
#   当某个进程在"枚举到它"与"读取 cmdline"之间退出时，读 /proc/<pid>/cmdline 会**永久阻塞**
#   （内核已知行为）。实测：900+ 进程环境下 10 秒只能扫到 300 个，并直接导致
#   `thermal_ctl.sh on` 卡死 5 分钟不返回（温控守护开关"点不动"的真因）。
#   toybox/busybox 提供的 pgrep 是原子操作，瞬时且不会阻塞。
xbt_pids() {
  # $1 = pgrep -f 的模式（正则）；排除自身 pid
  # 【v2.7 修正】关键路径不再用 timeout 包裹 pgrep：
  #   pgrep 是原子操作不会阻塞，包 timeout 反而带来"timeout 不存在就静默失效"的移植性风险
  #   （实测：无 timeout 环境下 `timeout 5 pgrep ...` 整条不执行 → 返回空 → 守护重复启动）。
  _pat="$1"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "$_pat" 2>/dev/null | grep -v "^$$\$"
  else
    # 无 pgrep 的极老设备降级：读 cmdline 确实可能阻塞，用可用超时保护
    for _p in /proc/[0-9]*; do
      _pid=${_p#/proc/}
      [ "$_pid" = "$$" ] && continue
      case "$(_xbt_run 1 cat "$_p/cmdline" 2>/dev/null | tr '\0' ' ')" in
        *"$2"*) echo "$_pid" ;;
      esac
    done
  fi
}
xbt_kill() {
  # 杀掉匹配的进程（不含自身）
  for _k in $(xbt_pids "$1" "$2"); do kill -9 "$_k" 2>/dev/null; done
}
# ===== v2.7 循环伪装：真实值保护 =====
# 【为什么需要】旧版 unlock.sh 直接 `echo 伪装值 > cyclecount`，把真实值当场覆盖，
#   且从不记录 → 用户真实循环数永久丢失，之后 clear 也恢复不回来。
#   用户反馈「初始50，伪装20，不干预却回退成20」「真实循环显示异常」即此。
# 【真实值来源】fg_master/qmax_cyclecount 是 FG 内部用于 Qmax 学习的循环计数，
#   实测（xuanyuan）：连续采样稳定，且写入 cyclecount=15 后它仍保持 601 不变
#   → 不会随伪装变化，可作为权威真实值来源。
CYCLE_NODE=/sys/class/xm_power/fg_master/cyclecount
CYCLE_NODE2=/sys/class/power_supply/battery/cycle_count
CYCLE_REAL_NODE=/sys/class/xm_power/fg_master/qmax_cyclecount
CYCLE_REAL_FILE=$XBT/state/last_real_cycle.txt

# 读取真实循环值（优先 qmax_cyclecount；不可用时回退到节点当前值）
cycle_real_read() {
  _r=$(cat "$CYCLE_REAL_NODE" 2>/dev/null)
  case "$_r" in ''|*[!0-9]*) _r="" ;; esac
  if [ -z "$_r" ]; then
    _r=$(cat "$CYCLE_NODE" 2>/dev/null)
    case "$_r" in ''|*[!0-9]*) _r="" ;; esac
  fi
  echo "$_r"
}

# 记录真实循环值（只在首次、或伪装已关闭时更新；绝不写入伪装残留值）
cycle_real_capture() {
  _cur=$(cycle_real_read)
  [ -n "$_cur" ] || return 1
  _cf=$(cfg_get cycle_fake "")
  _old=$(cat "$CYCLE_REAL_FILE" 2>/dev/null)
  case "$_old" in ''|*[!0-9]*) _old="" ;; esac
  if [ -z "$_old" ]; then
    mkdir -p $XBT/state 2>/dev/null
    echo "$_cur" > "$CYCLE_REAL_FILE" 2>/dev/null
    log "cycle: real value captured $_cur (was empty)"
    return 0
  fi
  if [ -z "$_cf" ]; then
    # 未伪装：真实值随使用增长，保持跟随（只增不减，防回滚）
    if [ "$_cur" -gt "$_old" ]; then
      echo "$_cur" > "$CYCLE_REAL_FILE" 2>/dev/null
      log "cycle: real value updated $_old -> $_cur (no disguise)"
    fi
  else
    # 伪装中：qmax_cyclecount 才是权威值，若记录被伪装污染则纠正回来
    if [ "$_old" = "$_cf" ] && [ "$_cur" != "$_cf" ]; then
      echo "$_cur" > "$CYCLE_REAL_FILE" 2>/dev/null
      log "cycle: last_real was polluted by fake ($_cf) -> corrected to $_cur"
    fi
  fi
  return 0
}

cfg_get() {
  _k="$1"; _d="$2"
  [ -f "$CONF" ] || { echo "$_d"; return; }
  _v=$(grep -E "^${_k}=" "$CONF" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  if [ -n "$_v" ]; then echo "$_v"; else echo "$_d"; fi
}

# ===== v2.9.9【回退 v2.9.4 引入的 cfg_get 变量缓存 —— 它是严重 bug】=====
# 【曾经的"优化"】v2.9.4 为减少 fork，加了 `_cfg_load()` 把整个 settings.conf
#   读进 `_CFG_<key>` 变量，`cfg_get` 先查变量。
# 【为什么是 bug —— 真机证明（xuanyuan，2026-10-17 白天，充电中）】
#   · 场景：同一个 shell 里 source common.sh 后，另一个进程改 settings.conf，
#     再调 cfg_get → **仍返回 source 时的旧值**。
#     实测：
#       第1次 cfg_get power_limit = [mid]
#       改文件为 inf 后            = [mid]   ← 不更新
#   · 更致命的是【长驻守护】：charge_guard 开机 source 一次后循环运行，
#     `_CFG_LOADED=1` 让它永远读缓存 → **用户切档位后守护 2 秒内又覆盖回旧档**。
#     真机实测：WebUI 选 slow → 节点被写成 2200000 → 1 秒内被顶回 17600000，
#     th 顶回 1 → 功率始终 ~48W（= 最高功率）。
#     这正是用户反馈的「**无论怎么调都是最高功率**」。
#   · 受影响的不止 power_limit，还有 fast_w/mid_w/slow_w（用户调瓦数）、
#     closed_loop、thermal_ceil、cg_min_write_gap …—— 所有运行期配置修改全部失效。
# 【当初的收益】实测 471 ms vs 473 ms —— **在噪声内，零收益**。
#   ⇒ 纯净损失，整段回退，恢复"每次都读文件"的原实现。
#   这个文件里的 cfg_get 调用点单次只有十几处，grep|tail|cut 的成本远小于错误配置。

cfg_set() {
  _k="$1"; _v="$2"
  mkdir -p "$(dirname "$CONF")"
  # v2.7：同时确保 state 目录存在 —— 全新安装时安装脚本只在"有旧版本可迁移"的分支里
  #   才创建 state（customize.sh:91/123），纯净首装不会建。而多个脚本会直接写
  #   $XBT/state/*（thermal_prev / last_real_cycle.txt / fv_default …），
  #   目录不存在时写入静默失败 → 温控保护前的档位丢失、真实循环值无法记录。
  #   cfg_set 是所有配置/状态写入的必经入口，在这里兜底最可靠。
  mkdir -p "$XBT/state" 2>/dev/null
  touch "$CONF"
  # v2.6.23 修复：末行无换行时直接 >> 会与末行粘连（实测产生 `dev_code=slow_w=2`，
  # 导致 dev_code 变成 "slow_w=2" → 静默回退 xuanyuan → BAA 指向错误机型、解容挂载失败）
  if [ -s "$CONF" ] && [ -n "$(tail -c 1 "$CONF" 2>/dev/null)" ]; then
    echo "" >> "$CONF"
  fi
  if grep -qE "^${_k}=" "$CONF" 2>/dev/null; then
    # v2.7（发布前审计 🟡-1）：sed 加 /g —— 旧写法只替换【首个】匹配行，
    #   而 cfg_get 用 `tail -n 1` 读【最后一行】。若因并发追加产生了重复键，
    #   就会出现「写首行、读末行」→ 写入被旧值遮蔽（如 stop 动作的 slow_w=2 不生效）。
    #   加 /g 保证所有同名行同步更新，与 cfg_get 语义对齐（且顺带自愈历史重复键）。
    #
    # v3.0.0：把 sed 分隔符从 `|` 换成 `@`。
    #   同 L1117 那个 bug 是同一类隐患：`|` 既是分隔符又可能出现在数据里
    #   （配置值是用户可改的字符串，如 backup_dir 路径）。一旦值里带 `|`，
    #   sed 表达式会被截断 → **静默写坏配置**（写失败但没有任何报错）。
    #   路径里不可能出现 `@`，更安全。
    sed -i "s@^${_k}=.*@${_k}=${_v}@g" "$CONF"
  else
    echo "${_k}=${_v}" >> "$CONF"
  fi
  # 同步一份到模块目录外：模块更新会整体替换目录，靠这份备份在安装时恢复。
  # 放在 cfg_set 里而不是定时任务，保证用户改完立刻就有备份（不等 60 秒）。
  _xj_bak=/data/adb/HyperOS_XJ_data/battery/config
  [ -d "$_xj_bak" ] || mkdir -p "$_xj_bak" 2>/dev/null
  cp -f "$CONF" "$_xj_bak/settings.conf" 2>/dev/null
}

# 机型参数取用（必须在 cfg_get/cfg_set 定义之后解析，否则函数尚未定义会取到空值）
# 【v2.9.9】恢复 v2.9.4 之前的原实现：用 cfg_get 逐个读取。
#   v2.9.4 曾改成 `_cfg_load` + `_CFG_*` 变量直读，随缓存一起回退（见 cfg_get 上方注释）。
#   这 6 项只在 source 时取一次（与 v2.7.4 原版完全一致，属设计如此）：
#     · MAX_MA 用作 tier_target_ma 的钳制上限
#     · MID_CTRL/SLOW_CTRL 供旧 ctrl 阶梯机制用
#     · FAST_W/MID_W/SLOW_W 仅供兼容，实际档位瓦数由 tier_target_ma 实时 cfg_get
MID_CTRL=$(cfg_get mid_ctrl "$DEF_MID_CTRL")
SLOW_CTRL=$(cfg_get slow_ctrl "$DEF_SLOW_CTRL")
FAST_W=$(cfg_get fast_w "$DEF_FAST_W")
MID_W=$(cfg_get mid_w "$DEF_MID_W")
SLOW_W=$(cfg_get slow_w "$DEF_SLOW_W")
# 电流安全上限（mA）：每机型独立默认（xuanyuan 6800 / haotian 7800 / dada 12000 / nezha 8000 / myron 9000 / annibale 9000 / bixi 6500 / onyx 8000 / popsicle 9000 / miro 10250 / songyuan 9200 / warsaw 9000 / pudding 9200），可 settings 覆盖
MAX_MA=$(cfg_get max_ma "$DEF_MAX_MA")
# 【v2.7.6 修复】MAX_MA 必须做数字校验 —— cfg_get 只在"值为空"时回退默认，写成
#   `max_ma=abc` / `max_ma= 8000` / `max_ma=8_000` 都会原样返回；而钳制点
#   （下方 `[ "$_ma" -gt "$MAX_MA" ] 2>/dev/null && _ma="$MAX_MA"`）的 `2>/dev/null`
#   会把 `[` 的报错吞掉 → `&&` 短路 → **每机型电流安全上限被静默跳过**。
#   现场标定时最容易踩（settings.conf 就是引导用户手改这一项）。
case "$MAX_MA" in
  ''|*[!0-9]*) MAX_MA="$DEF_MAX_MA" ;;
esac
[ "$MAX_MA" -gt 0 ] 2>/dev/null || MAX_MA="$DEF_MAX_MA"

# ===== 温控总闸的关闭阈值（v2.7.9）=====
# 【背景 · 真机实测定位到的功率方波根因】
#   模块的 thermal_target() 原先【硬编码 50.0℃】就写 wired_thermal_remove=0
#   → 驱动改走 DT 温控表 → 电流被压到 ~0.5A（约 2W）
#   → 但模块自己改的 DTBO 里，temp_para1 是【满流到 55℃（部分机型 57℃）才归零】
#   → 结果：低电量高功率充电时电池爬到 49~51℃ → 闸门在 50℃ 来回切换
#     → 适配器 PD 契约反复重协商（实测 vbus 19.40V ↔ 8.99V）
#     → 功率 59W ↔ 0.5W 方波（用户反馈的"功率曲线疯狂跳舞"）
#   dmesg 实锤（pid 即 charge_guard）：
#     mca_charger_thermal_sysfs_store:550 set wired thermal remove: 0
#
# 【修法】阈值按【各机型 DTBO 里 temp_para1 的归零温度】走（实测自 13 个机型的 dtbo）：
#     55℃ : xuanyuan haotian dada nezha myron annibale bixi
#     57℃ : miro onyx popsicle pudding songyuan warsaw
#   → 模块不再"抢在 DTBO 前面"关闸，把温度保护完全交给 DTBO/BMS（它们本来就有）。
#   settings 的 thermal_ceil 可覆盖（单位 0.1℃，如 550 = 55.0℃）。
DEF_THERMAL_CEIL=${DEF_THERMAL_CEIL:-580}

# ===== v2.9.4：温控总闸阈值改为【运行时读本机 DTBO】 =====
# 【为什么必须改】旧实现是一张硬编码机型表（xuanyuan 等 7 个机型写 550 = 55.0℃），
#   但 v2.8.0 把 DTBO 温度表重做成了「40~57℃ 满流 / 58℃ 禁充」。真机实测：
#     /proc/device-tree/soc/mca_strategy_quick_charge/temp_para1  (583 B, 9 段)
#       段8 = 40~57    max_current=17600
#       段9 = 58~65535 max_current=0
#   → 模块在 55.0℃ 就抢先把 wired_thermal_remove 写 0、交回驱动 DT 温控表
#     （驱动随即将电流压到 ~0.5A ≈ 2W），而 DTBO 本来允许满流到 57℃
#   → 闸门在 55~57℃ 之间来回切，且【完全没有滞回】
#   → **功率方波 59W↔0.5W + PD 反复重协商**（= 用户反馈的"温控不生效/乱跳功率"）。
#   这与 v2.7.9 修掉的"硬编码 50℃"是同一类 bug，只是值没跟着 v2.8.0 的温度重做更新。
# 【修法】不信任硬编码表，直接从内核 device-tree 解析本机 DTBO 的"满流上界"。
#   解析方式【必须与布局无关】—— 实测两种表布局并存：
#     · 详表（xuanyuan 99 字段 / dada 110 / onyx 77）：11 字段/段的规整滑窗
#     · 简表（其余 11 个机型 27 字段）：首段只有 9 字段 + 尾部 null 填充
#       → 11 字段滑窗必然错位（曾导致 11/14 机型算出空值）
#   14 个机型都有的【统一锚点】：禁充段的写法固定为 `... <CUT> 65535 0 0 0`
#     → 反向找最后一个 "65535" 且其后紧跟 "0"，它前面那个纯数字即禁充起点 CUT；
#       CUT - 1 = 满流上界（满流段的上界正好顶到禁充起点前一度）。
#   实测 14/14 机型 CUT=58 → 满流上界 57 → THERMAL_CEIL=570，与设备端
#   /proc/device-tree 实测完全吻合。
#   好处：以后重做 DTBO 温度表也不会再漂移，未知机型自动拿到正确值。开销 ~10ms。
#   settings.conf 的 thermal_ceil 仍可手动覆盖（现场标定）。
DT_CEIL_PATHS="/proc/device-tree/soc/mca_strategy_quick_charge/temp_para1
/proc/device-tree/soc/mca_quick_charge_batt_para_gbl/temp_para1
/proc/device-tree/soc/mca_strategy_quick_wireless_class/temp_para1
/proc/device-tree/soc/mca_quick_wireless_batt_para_gbl/temp_para1"
detect_dt_thermal_ceil() {
  _f=""
  for _c in $DT_CEIL_PATHS; do
    [ -r "$_c" ] && { _f="$_c"; break; }
  done
  [ -n "$_f" ] || return 1
  _up=$(tr '\0' '\n' < "$_f" 2>/dev/null | awk '
    NF { a[++n]=$0 }
    END {
      cut=""
      for (i=2; i<=n-1; i++) {
        if (a[i]=="65535" && a[i+1]=="0") {
          if (a[i-1] ~ /^[0-9]+$/ && a[i-1]+0 > 0 && a[i-1]+0 < 200) cut=a[i-1]
        }
      }
      if (cut != "") printf "%d", (cut-1)*10
    }' 2>/dev/null)
  case "$_up" in ''|*[!0-9]*) return 1 ;; esac
  # 合理区间 40.0~75.0℃：越界说明解析/格式异常，宁可用兜底表也不要用错值
  [ "$_up" -ge 400 ] 2>/dev/null && [ "$_up" -le 750 ] 2>/dev/null || return 1
  echo "$_up"
  return 0
}

THERMAL_CEIL=$(cfg_get thermal_ceil "$DEF_THERMAL_CEIL")
case "$THERMAL_CEIL" in
  ''|*[!0-9]*) THERMAL_CEIL="$DEF_THERMAL_CEIL" ;;
esac
[ "$THERMAL_CEIL" -gt 0 ] 2>/dev/null || THERMAL_CEIL="$DEF_THERMAL_CEIL"
# 用户没在 settings.conf 显式设值 → 用 DTBO 实测值覆盖（读不到则保留硬编码兜底）
if [ -z "$(grep -E '^thermal_ceil=' "$CONF" 2>/dev/null | tail -n 1 | cut -d= -f2-)" ]; then
  _dtc=$(detect_dt_thermal_ceil 2>/dev/null)
  case "$_dtc" in
    ''|*[!0-9]*) : ;;
    *)
      if [ "$_dtc" -ge 400 ] 2>/dev/null && [ "$_dtc" -le 750 ] 2>/dev/null; then
        THERMAL_CEIL="$_dtc"
      fi
      ;;
  esac
  unset _dtc
fi

# 释放滞回（0.1℃）：默认 3.0℃。旧实现是【纯比较、无状态、无迟滞】
#   → 温度在阈值附近抖动时 thermal_remove 每秒 1↔0 翻转，每次都触发 PMIC 重协商
#   → 功率方波。加滞回后：≥TH 关闸；关闸后必须降到 ≤(TH-3.0℃) 才释放。
THERMAL_HYST=${THERMAL_HYST:-30}
case "$THERMAL_HYST" in ''|*[!0-9]*) THERMAL_HYST=30 ;; esac
[ "$THERMAL_HYST" -ge 0 ] 2>/dev/null || THERMAL_HYST=30
[ "$THERMAL_HYST" -gt 200 ] 2>/dev/null && THERMAL_HYST=200
THERMAL_GATE_FILE=$XBT/state/thermal_gate
# 功率机制: curr=单电流模式(th=0+ctrl=0+curr目标，实测线性精确，默认) / ctrl=旧ctrl阶梯(兼容)
POWER_MECH=$(cfg_get power_mech curr)

slot_letter() {
  _s=$(getprop ro.boot.slot_suffix)
  echo "${_s#_}"
}

baa_state() {
  # ===== v3.9.9【修 bug】不再对「空目标」返回 skipped =====
  # 【旧行为】魔改包把 BAA 掏空成 1 字节 → 这里返回 skipped → 上层不挂载、不重挂。
  # 【实测后果】annibale / haotian 两台 15 系列：系统无 BAA 配置 → 驱动用兜底阶梯 →
  #   volt_thermal_limit 4500（4.5A）锁死 → 60% 后掉到 20W。
  # 【新行为】空目标视为「没有系统约束」，照样挂载我们的配置 →
  #   走下面的正常判定（挂上了就 active，没挂上就 inactive 并触发重挂）。
  _s=$(hash_of "$BAA_SRC"); _t=$(hash_of "$BAA_TGT")
  _l=$(stat -c '%C' "$BAA_TGT" 2>/dev/null)
  _sl=$(stat -c '%C' "$BAA_SRC" 2>/dev/null)
  # 判定口径与 baa_ops.sh mount 一致：sha 相同 且 label 与挂载源一致（兼容标准 label）。
  # 之前硬编码标准 label，在魔改系统（原文件 label 不同 -> mount 时 chcon 复制原 label）
  # 会误报 inactive，导致 WebUI 显示"未生效"并反复重挂 —— 修正此假象。
  if [ -n "$_s" ] && [ "$_s" = "$_t" ] && [ -n "$_l" ] &&
     { [ "$_l" = "$_sl" ] || [ "$_l" = "$BAA_LABEL" ]; }; then
    echo "active"
  else
    echo "inactive"
  fi
}

# 显示用：把 skipped 换为中文说明（菜单/状态输出）
baa_state_cn() {
  _bs=$(baa_state)
  case "$_bs" in skipped) echo "跳过(系统BAA为空)" ;; *) echo "$_bs" ;; esac
}

pss_state() {
  _d=$(dumpsys package com.miui.securitycenter 2>/dev/null)
  _seg=$(echo "$_d" | sed -n '/disabledComponents:/,/enabledComponents:/p')
  case "$_seg" in
    *PowerSaveService*) echo "disabled" ;;
    *) echo "enabled" ;;
  esac
}

# ===== v2.9.10：PSS 动态模式（只有在低电量时才禁用）=====
# 【要解决的矛盾（真机实测，xuanyuan 2026-10-17）】
#   · 解容第 3 步 = 禁用 PSS（防系统在低电量时锁容）
#   · 但 PSS 被禁用后 com.miui.securitycenter.remote 进程不启动
#     → BatteryHealthUtils 完全不运行 → 设置里「电池健康度」不显示
#   两者直接冲突：一直禁用 → 健康度永远看不到；一直启用 → 解容少一步。
# 【思路】「锁容」按定义是【低电量】行为，那就只在低电量时禁用：
#     SOC ≤ pss_low_soc        → 禁用 PSS（防锁容）
#     SOC ≥ pss_low_soc + hyst → 启用 PSS（健康度正常显示）
#     两者之间保持不变（滞回，避免在阈值附近反复 pm enable/disable 造成抖动）
# 【默认】pss_low_soc=0 → 【不启用】动态模式，行为与旧版完全一致（始终禁用）。
#   想要「健康度可见 + 低电量仍防锁容」的用户把它设为 20~30 即可。
# 【为什么轻量】只用 state/pss_dynamic 记录上次动作，**不调 dumpsys**（pss_state 很贵），
#   所以可以挂在守护循环里每 ~30 秒跑一次。
pss_guard_tick() {
  [ "$(cfg_get pss_disable 1)" = "1" ] || return 0   # 总开关关 → 不动 PSS
  _low=$(cfg_get pss_low_soc 0)
  case "$_low" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_low" -gt 0 ] 2>/dev/null || return 0          # 0 = 不启用动态模式
  _hys=$(cfg_get pss_low_hyst 5)
  case "$_hys" in ''|*[!0-9]*) _hys=5 ;; esac
  _soc=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  case "$_soc" in ''|*[!0-9]*) return 0 ;; esac
  _pd=$(cat "$XBT/state/pss_dynamic" 2>/dev/null)
  if [ "$_soc" -le "$_low" ]; then
    # 进入低电区 → 确保禁用
    [ "$_pd" = "disabled" ] && return 0
    pm disable "$PSS" >/dev/null 2>&1
    echo 1 > "$XBT/state/pss_disabled_by_module" 2>/dev/null
    echo disabled > "$XBT/state/pss_dynamic" 2>/dev/null
    log "pss_dynamic: SOC=${_soc}% <= ${_low}% → PSS 禁用（防低电量锁容）"
  elif [ "$_soc" -ge "$((_low + _hys))" ]; then
    # 回到安全区 → 确保启用（恢复健康度）
    [ "$_pd" = "enabled" ] && return 0
    pm enable "$PSS" >/dev/null 2>&1
    rm -f "$XBT/state/pss_disabled_by_module" 2>/dev/null
    echo enabled > "$XBT/state/pss_dynamic" 2>/dev/null
    log "pss_dynamic: SOC=${_soc}% >= $((_low + _hys))% → PSS 启用（恢复电池健康度显示）"
  fi
  return 0
}

update_desc() {
  _h="$1"; _c="$2"; _u="$3"
  _mp=$XBT/module.prop
  [ -f "$_mp" ] || return 0
  if [ "$_u" = "1" ]; then _us="开"; else _us="关"; fi
  if [ "$(cfg_get cloud_guard 1)" = "1" ]; then _cgs="开"; else _cgs="关"; fi
  _pw=$(power_now)
  _pwl=$(power_label)
  _cap_raw=$(cat /sys/class/power_supply/battery/charge_full 2>/dev/null)
  case "$_cap_raw" in
    ''|*[!0-9]*) _cap="?" ;;
    *) _cap=$(((_cap_raw + 500) / 1000)) ;;
  esac
  sed -i "/^description=/d" "$_mp"
  echo "description=功率:${_pwl} ｜ 健康:${_h}% ｜ 容量:${_cap}mAh ｜ 电池解容:${_us} ｜ 云控屏蔽:${_cgs} ｜ $DEV_NAME ($DEV_CODE)" >> "$_mp"
}

# ---- 功率档位 ----
#四档：inf=不限速(全速) / fast=40W MAX / mid=25W MAX / slow=10W MAX（落点由机型参数表/设置控制）。
# 具体落点由【机型功率参数表】控制（common.sh 顶部），可被 settings.conf 覆盖。
PW_TABLE="inf fast mid slow"
# 兼容旧版数字档位：>=30 → fast，>=20 → mid，<20 → slow。旧值 limit 迁移到 mid。
normalize_power() {
  case "$1" in
    inf|∞|unlimited|0) echo inf; return ;;
    fast|boost|40) echo fast; return ;;
    mid|std|limit|medium) echo mid; return ;;
    slow|eco) echo slow; return ;;
  esac
  case "$1" in
    ''|*[!0-9]*) echo inf; return ;;
  esac
  if [ "$1" -ge 30 ] 2>/dev/null; then echo fast
  elif [ "$1" -ge 20 ] 2>/dev/null; then echo mid
  else echo slow; fi
}

power_now() { normalize_power "$(cfg_get power_limit inf)"; }

power_label() {
  case "$(power_now)" in
    inf) echo "${DEV_MAXW}W MAX" ;;
    fast) echo "${FAST_W:-40}W MAX" ;;
    mid) echo "${MID_W:-25}W MAX" ;;
    slow) echo "${SLOW_W:-10}W MAX" ;;
    *) echo "$(power_now)" ;;
  esac
}

# 档位的大致功率（用于提示文案）
power_hint() {
  case "$(power_now)" in
    inf) echo "全速，随电量约 20~48W" ;;
    fast) echo "单电流模式，约 ${FAST_W:-40}W" ;;
    mid) echo "单电流模式，约 ${MID_W:-25}W" ;;
    slow) echo "单电流模式，约 ${SLOW_W:-10}W" ;;
    *) echo "" ;;
  esac
}

DIRECT_WIRED=/sys/class/xm_power/charger/charger_thermal/wired_chg_curr
DIRECT_WIRED2=/sys/class/xm_power/charger/charger_thermal/wired_chg_curr2
DIRECT_WIRELESS=/sys/class/xm_power/charger/charger_thermal/wireless_chg_curr
DIRECT_WIRED_CTRL=/sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit
DIRECT_WIRELESS_CTRL=/sys/class/xm_power/charger/charger_thermal/wireless_ctrl_limit
DIRECT_WIRELESS_MAG_CTRL=/sys/class/xm_power/charger/charger_thermal/wireless_mag_ctrl_limit
DIRECT_WIRED_THERMAL_REMOVE=/sys/class/xm_power/charger/charger_thermal/wired_thermal_remove
DIRECT_WIRELESS_THERMAL_REMOVE=/sys/class/xm_power/charger/charger_thermal/wireless_thermal_remove

# Scene 在小米 15 系使用的三路原生限流节点：
# 有线走 wired_chg_curr + wired_chg_curr2，无线走 wireless_chg_curr。
direct_current_nodes() {
  _out=0
  for _p in "$DIRECT_WIRED" "$DIRECT_WIRED2" "$DIRECT_WIRELESS"; do
    [ -e "$_p" ] || continue
    if [ -w "$_p" ]; then echo "$_p"; _out=1; fi
  done
  # 有可写的 xm_power 原生节点 → 直接使用
  [ "$_out" = "1" ] && return 0

  # xm_power 节点缺失，或存在但均不可写时，回退到电池原生电流上限节点，
  # 保证在非 mca_charger_thermal 内核 / 部分定制 ROM 上仍有限流手段。
  for _p in \
    /sys/class/power_supply/main/constant_charge_current_max \
    /sys/class/power_supply/battery/constant_charge_current_max \
    /sys/class/power_supply/battery/constant_charge_current
  do
    [ -e "$_p" ] && echo "$_p"
  done
}

current_node() {
  direct_current_nodes | head -n 1
}

direct_set_current_ma() {
  _value="$1"
  _th="${2:-}"
  _lv="${3:-}"
  case "$_value" in ''|*[!0-9]*) return 1 ;; esac
  case "$_th" in 0|1) ;; *) _th=$(thermal_target) ;; esac

  # ===== 旁路供电让路 =====
  # 温控侧旁路需要把充电电流压得很低；期间电池解容不要抢节点，
  # 旁路结束后由温控调用 charge_guard.sh once 交还。
  if [ "$(cat /data/adb/modules/HyperOS_XJ/config/bypass_active 2>/dev/null)" = "1" ]; then
    return 0
  fi

  # ===== v2.9.9【核心修复：限流档必须同时施加 ctrl 阶梯】=====
  # 【真机实测（xuanyuan，2026-10-17 白天，充电中 SOC 69~71%，pd_pps）】
  #   固定 th=0 + wired_chg_curr=2200000，只改 wired_ctrl_limit 逐级测：
  #     ctrl=0  → 电池 5104mA 23.3W   泵 1350mA
  #     ctrl=3  → 电池 4834mA 22.0W   泵 1254mA
  #     ctrl=6  → 电池 4649mA 21.1W   泵 1211mA
  #     ctrl=9  → 电池 4398mA 19.9W   泵 1141mA
  #     ctrl=12 → 电池 4125mA 18.6W   泵 1087mA
  #     ctrl=14 → 电池 3936mA 17.8W   泵 1025mA
  #     ctrl=16 → 电池 3699mA 16.6W   泵  999mA
  #   **完全单调递减，23.3W → 16.6W（-29%），泵电流同步下降。**
  #   而同批次测 wave：只写 wired_chg_curr（2.2A~8A，远低于实际）→ 电池电流【纹丝不动】
  #   （与 v2.7.6 变更说明作者自记的"限流档几乎不限制功率"完全吻合）。
  # 【结论】本机唯一有效的软件限流旋钮是 `wired_ctrl_limit` 阶梯，不是 wired_chg_curr。
  #   而 POWER_MECH=curr 分支把 ctrl 硬编码写 0 → 档位限流完全失效。
  # 【本版做法】限流档（_th=0）下按档位施加 ctrl 阶梯：
  #     fast|mid → MID_CTRL(4)，slow → SLOW_CTRL(14)，inf → 0
  #   电流节点仍照写（在支持的机型上有效，且是官方设计路径），两者叠加。
  #   ★ ctrl 阶梯值沿用代码里原有的 power_ctrl_level() 与各机型 DEF_*_CTRL（作者已标定），
  #     不新造数值；若某机型不认 ctrl，回读校验会判"未生效"并记录，不会静默。
  if [ -z "$_lv" ]; then
    if [ "$_th" = "0" ]; then
      _lv=$(power_ctrl_level "$(power_now)")
    else
      _lv=0
    fi
  fi
  case "$_lv" in ''|*[!0-9]*) _lv=0 ;; esac

  # ===== v2.9.7【修复：无线节点单位比有线小 1000 倍】=====
  # 【现场实测（xuanyuan，2026-10-17）】
  #   wired_chg_curr    = 2200000   (µA)   ← 有线：微安
  #   wired_chg_curr2   = 2200000   (µA)   ← 有线：微安
  #   wireless_chg_curr = 2200      (mA)   ← 无线：【毫安】！比有线小 1000 倍
  # 而旧代码对三个节点统一写 `_value * 1000` → 无线节点被写成 2,200,000,000
  #   （= 2200 安培）这种荒谬值，实际语义完全错误。
  #   `common.sh` 的 `direct_node_read_ma()` 也只对无线做 /1000（见该函数注释），
  #   两处口径自相矛盾 → 本函数现在按【每个节点自己的单位】分别写。
  #   判据：只对 wireless* 节点写 mA，其余写 µA。
  #   若某机型无线节点其实也是 µA，写入后 `direct_tier_applied` 的 2% 回读校验
  #   会立刻判失败并重写 → 不会静默错下去（可在日志看到 write failed/不生效）。
  _ok=0
  for _p in $(direct_current_nodes); do
    [ -n "$_p" ] || continue
    case "$_p" in
      *wireless*) _raw=$_value ;;          # 无线节点：mA
      *)          _raw=$((_value * 1000)) ;; # 有线节点：µA
    esac
    chmod 664 "$_p" 2>/dev/null
    if echo "$_raw" > "$_p" 2>>"$LOG"; then
      _ok=1
    else
      log "direct: write failed node=$_p value=${_raw}"
    fi
  done
  [ "$_ok" = "1" ] || return 1

  # 写 ctrl 阶梯：限流档写 power_ctrl_level（slow=14 / fast|mid=4），非限流档写 0
  _ctrl_ok=0
  for _p in $(direct_limit_nodes); do
    [ -e "$_p" ] || continue
    chmod 664 "$_p" 2>/dev/null
    if echo "$_lv" > "$_p" 2>>"$LOG"; then
      _ctrl_ok=1
    else
      log "direct: ctrl write failed node=$_p value=$_lv"
    fi
  done

  for _p in $(direct_thermal_remove_nodes); do
    [ -e "$_p" ] || continue
    chmod 664 "$_p" 2>/dev/null
    echo "$_th" > "$_p" 2>>"$LOG" || _ctrl_ok=0
  done

  direct_record_applied "$_value"

  if [ -n "$(direct_control_nodes)" ]; then
    [ "$_ctrl_ok" = "1" ]
  else
    true
  fi
}

direct_control_nodes() {
  direct_limit_nodes
  direct_thermal_remove_nodes
}

direct_limit_nodes() {
  for _p in \
    "$DIRECT_WIRED_CTRL" \
    "$DIRECT_WIRELESS_CTRL" \
    "$DIRECT_WIRELESS_MAG_CTRL"
  do
    [ -e "$_p" ] && echo "$_p"
  done
}

direct_thermal_remove_nodes() {
  for _p in "$DIRECT_WIRED_THERMAL_REMOVE" "$DIRECT_WIRELESS_THERMAL_REMOVE"; do
    [ -e "$_p" ] && echo "$_p"
  done
}

# ===== 功率总闸（charger_thermal/{wired,wireless}_thermal_remove）=====
# 1 = 绕过驱动 DT 温控表，由实时电流节点（wired_chg_curr 等）决定功率。
#     要达成目标功率这一位必须为 1：实测写 0 时驱动温控表会把电流压到
#     ~0.5A（约 2W），此时无论实时电流节点写多少都无效。
# 0 = 交回驱动温控表。仅在电池温度超过【本机型 DTBO 的归零温度】时作为兜底。
#
# 【v2.7.9 修正】阈值从硬编码 500(50.0℃) 改为按机型走（DEF_THERMAL_CEIL / THERMAL_CEIL）
#   根因见本文件 THERMAL_CEIL 定义处的完整说明：
#     50℃ 落在 DTBO 的满流区间（40~55/57℃）之内 → 模块提前关闸
#     → 功率 59W↔0.5W 方波 + PD 契约反复重协商（真机 dmesg 实锤）。
thermal_target() {
  _t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
  case "$_t" in
    ''|*[!0-9-]*) echo 1; return ;;
  esac
  _on=${THERMAL_CEIL:-560}
  _off=$((_on - ${THERMAL_HYST:-30}))
  # 【v2.9.4 滞回】旧实现是纯比较 `_t >= _on`，无状态 → 温度在阈值附近抖动时
  #   每秒 1↔0 翻转，每次写都触发 PMIC 重协商 → 功率方波（59W↔0.5W）。
  #   现在：未关闸时 ≥_on 就关闸；已关闸后必须降到 ≤_off 才释放。
  #   状态存 state/thermal_gate（"0" = 已关闸；其它/缺失 = 未关闸）。
  _st=$(cat "$THERMAL_GATE_FILE" 2>/dev/null)
  if [ "$_t" -ge "$_on" ] 2>/dev/null; then
    [ "$_st" = "0" ] || echo 0 > "$THERMAL_GATE_FILE" 2>/dev/null
    echo 0
    return
  fi
  if [ "$_st" = "0" ] && [ "$_t" -gt "$_off" ] 2>/dev/null; then
    echo 0          # 仍高于释放点 → 保持关闸（这就是滞回）
    return
  fi
  [ "$_st" = "0" ] && echo 1 > "$THERMAL_GATE_FILE" 2>/dev/null
  echo 1
}

# （v2.5.10：曾加装"温度保护阀"，按作者要求移除——DTBO/BAA 已按 15~55℃ 顶满功率的激进策略设计，
#   温控兜底交给驱动 DT 温控表(th=0) 与 BMS；模块只负责"实时电流/电压换算 → 恒定目标功率"。）

direct_set_thermal() {
  _v="${1:-$(thermal_target)}"
  case "$_v" in 0|1) ;; *) _v=1 ;; esac
  for _p in $(direct_thermal_remove_nodes); do
    chmod 664 "$_p" 2>/dev/null
    echo "$_v" > "$_p" 2>/dev/null
  done
}

# ===== 功率档位 -> 内核旋钮映射 =====
# 本机型（mca_charger_thermal）实测只有两个真正生效的旋钮：
#   wired_thermal_remove : 1 = 绕过驱动 DT 温控表（全速，30~41W，随 SOC 回落）
#                          0 = 走 DT 温控表（限流）；此时 wired_ctrl_limit 才生效
#   wired_ctrl_limit     : 仅当 thermal_remove=0 时生效，值越大功率越低
#                          （实测 0~6 约 20~22W，7~12 约 17~20W，>=13 直接掉到约 4W）
# 数字档位统一走 thermal_remove=0 + ctrl 阶梯；inf（不限速）走 thermal_remove=1。
power_ctrl_level() {
  case "$1" in
    fast|mid) echo "${MID_CTRL:-4}" ;;
    slow) echo "${SLOW_CTRL:-14}" ;;
    *) echo 0 ;;
  esac
}

# ---- curr 机制：目标瓦数 -> 电流(mA) ----
# I_mA = P_W * 1e9 / V_uv，加 3% 线损余量后量化到 100mA。
# 换算是按【实时电压】做的，电压漂移会重新计算；量化可避免边界抖动造成 churn。
watt_to_current_ma() {
  _w="$1"
  case "$_w" in ''|*[!0-9]*) echo ""; return ;; esac
  _uv=$(read_voltage_uv)
  case "$_uv" in ''|*[!0-9]*|0) echo ""; return ;; esac
  # v2.5.10:实测「单电流模式(th=0+ctrl=0)」下电池电流≈节点值，不再加损耗余量。
  # 需微调时改 settings 的 mid_w/slow_w。
  _ma=$(awk -v w="$_w" -v v="$_uv" 'BEGIN { printf "%d", w*1e9/v }')
  quantize_current_ma "$_ma"
}

# 读 DTBO mca_strategy_quick_charge/div_max_curr 数组最大值（big-endian u32）
# 这是硬件真正允许的充电泵电流顶，任何写节点的目标都不得超过它
dt_curr_cap_ma() {
  _f=/proc/device-tree/soc/mca_strategy_quick_charge/div_max_curr
  [ -e "$_f" ] || { echo ""; return; }
  od -An -tu1 -v "$_f" 2>/dev/null | awk '
    { for(i=1;i<=NF;i++) a[++n]=$i }
    END{
      if(n<4){print ""; exit}
      max=0
      for(i=1;i+3<=n;i+=4){
        v=a[i]*16777216+a[i+1]*65536+a[i+2]*256+a[i+3]
        if(v>max) max=v
      }
      print max
    }'
}

# 各档在 curr 机制下的目标电流（inf 固定 20000mA，与“一发er”方案一致）
tier_target_ma() {
  _w=""
  case "$1" in
    inf)
      # ===== v3.11.0：inf 档目标由「自适应功率爬坡器 apl.sh」动态决定 =====
      # apl.sh 每 5s 采样实际功率/电流/温度，按 SOC 分 10 段学习硬件真实上限，
      # 结果写入 state/apl_target_ma；本函数读它。
      # 兜底顺序：apl_target_ma → DTBO div_max_curr → 20000
      # 安全：任何情况下不超过 min(DTBO div_max_curr, apl_max_ma, 20000)
      # 【v3.12.3 修 BUG9】绝不能把 MAX_MA 当 inf 上限！
      #   MAX_MA 是「fast/mid/slow 档 watt 换算的电流封顶」（haotian=8000），
      #   用它做 inf 上限会把目标压到 8A≈36W，解容直接废掉。
      #   v3.12.1 只改了 apl.sh 的 ceiling()，漏了这里 —— 现补上。
      #   inf 的真实上限只有 DTBO div_max_curr 说了算；可选 settings 键 apl_max_ma 覆盖。
      _cap=20000
      _dc=$(dt_curr_cap_ma 2>/dev/null)
      case "$_dc" in ''|*[!0-9]*) _dc="" ;; esac
      [ -n "$_dc" ] && [ "$_dc" -gt 0 ] && [ "$_dc" -lt "$_cap" ] && _cap="$_dc"
      _om=$(cfg_get apl_max_ma "")
      case "$_om" in ''|*[!0-9]*) ;; *)
        [ "$_om" -gt 0 ] && [ "$_om" -lt "$_cap" ] && _cap="$_om" ;; esac
      _at=$(cat "$XBT/state/apl_target_ma" 2>/dev/null)
      case "$_at" in ''|*[!0-9]*) _at="" ;; esac
      if [ -n "$_at" ] && [ "$_at" -ge 2000 ]; then
        [ "$_at" -gt "$_cap" ] && _at="$_cap"
        echo "$_at"
      else
        echo "$_cap"
      fi
      return ;;
    # v2.6.21：改为实时读取（运行中调整 fast_w/mid_w/slow_w 立即生效；thermal stop 动作依赖）
    fast) _w=$(cfg_get fast_w "${DEF_FAST_W:-40}") ;;
    mid)  _w=$(cfg_get mid_w "${DEF_MID_W:-25}") ;;
    slow) _w=$(cfg_get slow_w "${DEF_SLOW_W:-10}") ;;
    *)    echo ""; return ;;
  esac
  _ma=$(watt_to_current_ma "$_w")
  [ -n "$_ma" ] || { echo ""; return; }
  # 节点/电池电流安全上限（每机型独立默认值，可在 settings 用 max_ma 覆盖）
  [ "$_ma" -gt "$MAX_MA" ] 2>/dev/null && _ma="$MAX_MA"
  echo "$_ma"
}

direct_tier_th() {
  if [ "$1" = "inf" ]; then
    thermal_target
  else
    echo 0
  fi
}

# 记录当前档位实际写入的旋钮值（幂等判定用，避免每秒重写造成充电器反复协商）。
direct_record_tier() {
  _tier="$1"
  mkdir -p "$XBT/state" 2>/dev/null
  {
    echo "TIER|${_tier}"
    for _p in $(direct_limit_nodes); do
      echo "CTRL|${_p}|$(cat "$_p" 2>/dev/null)"
    done
    for _p in $(direct_thermal_remove_nodes); do
      echo "THERM|${_p}|$(cat "$_p" 2>/dev/null)"
    done
  } > "$XBT/state/direct_applied" 2>/dev/null
}

direct_tier_is_applied() {
  _tier="$1"
  _snap="$XBT/state/direct_applied"
  #  curr 机制（v2.5.10 单电流模式）幂等判据：
  #   mid/slow: th=0 + ctrl=0 + curr=目标
  #   inf（全速）: 快照目标一致 + 闸门==thermal_target() + ctrl=0（★ 不校验电流节点）
  # 关键：系统步进算法会尝试把电流节点顶高 → 偏差超 2% 即判"未生效"→ 守护逐秒重压。
  #（这是实测能真正压住功率的核心；只写一次会被系统顶回去。）
  if [ "$POWER_MECH" = "curr" ]; then
    # ===== v2.7.12：inf（全速）档恢复【事件驱动早退】=====
    # 【背景 · 真机实测定位到的功率方波根因】
    #   v2.7.3 曾在此处写 `if [ "$_tier" = "inf" ]; then return 1; fi`，
    #   本意是"统一走 charge_guard 的 inf 分支，避免两条并行路径出 bug"（这个顾虑是对的），
    #   但副作用是：apply_once 再也无法早退 → 【每秒】都跑一遍 inf 分支
    #   → inf 分支每秒重算 thermal_target() → 旧版阈值 50℃ 时写 thermal_remove=0
    #   → 驱动温控表把电流压到 ~0.5A → 功率塌陷 → 温度回落 → 写回 1 → 再爬 ⟲
    #   → 用户看到的"功率曲线疯狂跳舞 + 协议疯狂重复握手"
    #   （真机 dmesg 实锤：mca_charger_thermal_sysfs_store:550 set wired thermal remove: 0，
    #     进程号即 charge_guard；同时段功率 59.0W ↔ 0.5W、vbus 19.40V ↔ 8.99V）
    #
    # 【v2.7.12 做法 —— 混合方案：事件驱动 + 漂移自愈】
    #   保留"统一路径"的好处，同时恢复"稳态不写"：
    #     ① 稳态（三项全对）→ return 0 → apply_once 早退，本秒【零写入】
    #     ② 任一项漂移   → return 1 → 走 inf 分支自愈（v2.7.3+ 的自愈能力全部保留）
    #   三项判定都是廉价读：
    #     · 快照 TARGET 与目标一致（4% 容差，同 mid/slow）
    #     · thermal_remove == thermal_target()   ← 只读 1~2 个节点
    #     · ctrl_limit == 0                      ← inf 的语义要求
    #   【为什么不检查电流节点】inf 的语义是"不做限流"——电流节点整列由系统快充算法
    #     按 SOC/温度自管（实测该列是适配器输入侧 9v_in/5v_in，快充时本就 500~8000mA，
    #     永远到不了 10A）。把它纳入判据 → 每秒判失败 → 每秒重写 → PD 重协商锯齿。
    _ma=$(tier_target_ma "$_tier")
    [ -n "$_ma" ] || return 1
    [ -s "$_snap" ] || return 1
    _rec=$(grep -F 'TARGET|' "$_snap" 2>/dev/null | head -n 1 | cut -d'|' -f2)
    case "$_rec$_ma" in *[!0-9]*) return 1 ;; esac
    # 目标抖动容差（v2.5.10）：电压毫伏级波动会让换算目标在相邻量化档间跳（如 3100<->3200），
    # 精确比对会每几秒触发重写；给 4%（下限 120mA）容差，只有真正需要换目标才重写。
    _dtol=$((_ma / 25)); [ "$_dtol" -lt 120 ] && _dtol=120
    _dd=$((_rec - _ma)); [ "$_dd" -lt 0 ] && _dd=$((0 - _dd))
    [ "$_dd" -le "$_dtol" ] || return 1
    # ---- 闸门必须等于期望值（inf 期望 thermal_target()，即随温度）----
    if [ "$_tier" = "inf" ]; then _want_th=$(thermal_target); else _want_th=0; fi
    for _p in $(direct_thermal_remove_nodes); do
      [ "$(cat "$_p" 2>/dev/null)" = "$_want_th" ] || return 1
    done
    # ---- ctrl_limit 必须等于该档位的 ctrl 阶梯值（v2.9.9 起不再是恒 0）----
    #   inf     → 0        （不做限流）
    #   fast|mid → MID_CTRL  （默认 4）
    #   slow    → SLOW_CTRL  （默认 14）
    # 【为什么改】v2.9.9 起限流档改为用 ctrl 阶梯施加限制（真机实测这是本机唯一
    #   有效的软件限流旋钮，见 direct_set_current_ma 的实测表）。若这里仍要求 ==0，
    #   会和写入侧互相判"未生效" → 每秒重写 → PD 反复协商。必须同源。
    _want_lv=$(power_ctrl_level "$_tier")
    for _p in $(direct_limit_nodes); do
      [ -e "$_p" ] || continue
      [ "$(cat "$_p" 2>/dev/null)" = "$_want_lv" ] || return 1
    done
    # ---- 电流节点回读校验（容差 2%，下限 100µA）----
    #   ★ 只对 fast/mid/slow 做：inf 档【故意不校验电流节点】——
    #     inf 的语义是"不做限流"，那一列由系统快充算法按 SOC/温度自管
    #     （实测该列是适配器输入侧 9v_in/5v_in，快充时本就 500~8000mA，永远到不了 10A）。
    #     把它纳入 inf 判据 → 每秒判失败 → 每秒重写 → PD 重协商锯齿
    #     （正是 v2.7.4 实测到的"最短 13 秒一次"那个问题）。
    if [ "$_tier" != "inf" ]; then
      _tol=$((_ma * 1000 / 50))
      [ "$_tol" -lt 100 ] && _tol=100
      while IFS='|' read -r _kind _node _want; do
        [ "$_kind" = "NODE" ] || continue
        [ -n "$_node" ] || continue
        _now=$(direct_node_default_raw "$_node" 2>/dev/null)
        case "$_now" in ''|*[!0-9]*) return 1 ;; esac
        _d=$((_now - _want)); [ "$_d" -lt 0 ] && _d=$((0 - _d))
        [ "$_d" -le "$_tol" ] || return 1
      done < "$_snap"
    fi
    return 0
  fi
  [ -s "$_snap" ] || return 1
  _rec=$(grep -F 'TIER|' "$_snap" 2>/dev/null | head -n 1 | cut -d'|' -f2)
  [ "$_rec" = "$_tier" ] || return 1

  # v2.5.9: inf(不限速) 只认【温控总闸】thermal_remove=1。
  # 15/15Pro(haotian/dada) 上 wired_ctrl_limit 由系统每秒自行改写(0/11 跳)，
  # 旧版把 "ctrl_limit==0" 也当判据 -> 每秒判失败 -> 每秒重写 8 个节点 ->
  # 充电器反复重协商 -> 功率上不去(15W 锁的表象之一)。
  # inf 档不再检查 ctrl_limit，杜绝 churn；mid/slow 仍要求 ctrl 落点正确。
  _want_th=$(direct_tier_th "$_tier")
  for _p in $(direct_thermal_remove_nodes); do
    [ "$(cat "$_p" 2>/dev/null)" = "$_want_th" ] || return 1
  done
  if [ "$_tier" != "inf" ]; then
    _want_lv=$(power_ctrl_level "$_tier")
    for _p in $(direct_limit_nodes); do
      [ "$(cat "$_p" 2>/dev/null)" = "$_want_lv" ] || return 1
    done
  fi
  return 0
}

# 应用一个功率档位：写 thermal_remove + ctrl_limit 两个旋钮。
direct_set_tier() {
  _tier="$1"
  case "$_tier" in
    inf|fast|mid|slow) ;;
    *) _tier=inf ;;
  esac
  # curr 机制（v2.5.10 单电流模式）：th=0 + ctrl=0 + curr=目标 → 电池电流≈节点值，线性精确。
  # inf 例外：th=1（放行全速）。
  if [ "$POWER_MECH" = "curr" ]; then
    _ma=$(tier_target_ma "$_tier")
    if [ -z "$_ma" ]; then
      log "direct: curr no target ma tier=$_tier"
      return 1
    fi
    if [ "$_tier" = "inf" ]; then _thc=$(thermal_target); else _thc=0; fi
    # ===== v2.7.3 关键修复：inf（全速）不逐秒写电流节点 =====
    # 旧实现给 inf 也【每秒】写 wired_chg_curr=20000 mA，而每次写该节点都会让 PMIC
    # 重新协商 PD/PPS 契约 → 适配器电压/电流抖动 → 功率在 10~48W 锯齿抖动
    # （用户反馈"低电量时功率忽高忽低"；诊断包 dmesg 实测 vbus 4778~4957 mV、
    #   ibus 403~1594 mA 全在跳，chg_en=[0][term_recharge]）。
    #
    # 但【不能完全不写】：从 fast/mid/slow 切回 inf 时，节点还停在限流档的低电流，
    # 不写就会卡在低功率（实测：slow→inf 后节点仍为 2900000 µA）。
    # 正确做法 = **只在需要时写一次**（节点明显低于满速值时），之后不再碰。
    # inf 的语义是"不做限流"：模块解决容（thermal_remove）+ 清 ctrl_limit，
    # 电流节点交由系统自己的快充算法按 SOC/温度步进（它本来就会调）。
    if [ "$_tier" = "inf" ]; then
      for _p in $(direct_thermal_remove_nodes); do
        [ -e "$_p" ] || continue
        chmod 664 "$_p" 2>/dev/null
        echo "$_thc" > "$_p" 2>/dev/null
      done
      for _p in $(direct_limit_nodes); do
        [ -e "$_p" ] || continue
        chmod 664 "$_p" 2>/dev/null
        echo 0 > "$_p" 2>/dev/null
      done
      # 仅在真正"全速"时补写电流节点。若 _thc=0（电池 ≥50°C 的安全回退），
      #   此时应把温控整体交回 DT 表，不能再顶电流节点。
      if [ "$_thc" = "1" ]; then
        _cur_ma=$(direct_node_read_ma "$DIRECT_WIRED" 2>/dev/null)
        case "$_cur_ma" in ''|*[!0-9]*) _cur_ma=0 ;; esac
        if [ "$_cur_ma" -lt 10000 ]; then
          direct_set_current_ma "$_ma" "$_thc" >/dev/null 2>&1
          log "charge_guard: inf 恢复满速 (节点 $_cur_ma -> $_ma mA)"
        fi
      fi
      mkdir -p "$XBT/state" 2>/dev/null
      echo "inf" > "$XBT/state/power_mech_tier" 2>/dev/null
      return 0
    fi
    direct_set_current_ma "$_ma" "$_thc" || return 1
    mkdir -p "$XBT/state" 2>/dev/null
    echo "$_tier" > "$XBT/state/power_mech_tier" 2>/dev/null
    return 0
  fi
  _th=$(direct_tier_th "$_tier")
  _lv=$(power_ctrl_level "$_tier")

  for _p in $(direct_thermal_remove_nodes); do
    chmod 664 "$_p" 2>/dev/null
    echo 1 > "$_p" 2>/dev/null
  done
  for _p in $(direct_limit_nodes); do
    [ -e "$_p" ] || continue
    chmod 664 "$_p" 2>/dev/null
    echo "$_lv" > "$_p" 2>>"$LOG" || log "direct: ctrl write failed node=$_p lv=$_lv"
  done
  for _p in $(direct_thermal_remove_nodes); do
    [ -e "$_p" ] || continue
    chmod 664 "$_p" 2>/dev/null
    echo "$_th" > "$_p" 2>>"$LOG" || return 1
  done

  direct_record_tier "$_tier"
  return 0
}

direct_node_read_ma() {
  _node="$1"
  [ -n "$_node" ] || { echo ""; return; }
  _raw=$(cat "$_node" 2>/dev/null)
  case "$_raw" in ''|*[!0-9]*) echo ""; return ;; esac
  case "$_node" in
    "$DIRECT_WIRELESS") echo "$_raw" ;;
    *) echo $((_raw / 1000)) ;;
  esac
}

# v2.7.4：读【全部】电流节点取最小值（mA）。
# 【为什么】写入覆盖 wired_chg_curr + wired_chg_curr2（+ 无线），但判据原先只读 DIRECT_WIRED。
#   若真实生效的是第二个有线节点而第一个读回偏高，就会误判"已满速"而跳过补写。
#   取最小值是保守做法：只要还有节点停在低电流，就认为需要恢复。
direct_node_read_ma_all() {
  # ★v3.8.1 修复【全机型影响】：原来把 wireless_chg_curr 也算进最小值，
  #   而无线节点量级与有线完全不同（实测无线恒为 20，有线 500~22000），
  #   取最小值时永远被无线拉到 20 → 调用方 charge_guard 的「inf 安顿」判据
  #   `[ "$_after" -ge 10000 ]` 永远不成立 → 连试 3 次后落 state/inf_node_capped=20
  #   → 之后【永久不再补写电流节点】，日志显示
  #   「inf 该机型电流节点上限 20mA(<10A)，已安顿(不再重试)」。
  #   实测受影响：xuanyuan / nezha / haotian 全部命中（inf_node_capped=20）。
  #
  #   修法：有线充电时只统计【有线节点】；只有当没有任何有线节点可用时
  #   （纯无线充电场景）才回退到全部节点。这样判据与「有线充电功率」语义一致。
  _min=""
  _min_all=""
  for _p in $(direct_current_nodes); do
    [ -n "$_p" ] || continue
    _v=$(direct_node_read_ma "$_p" 2>/dev/null)
    case "$_v" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$_min_all" ] || [ "$_v" -lt "$_min_all" ]; then _min_all="$_v"; fi
    case "$_p" in
      *wireless*) continue ;;
    esac
    if [ -z "$_min" ] || [ "$_v" -lt "$_min" ]; then _min="$_v"; fi
  done
  if [ -n "$_min" ]; then echo "$_min"
  elif [ -n "$_min_all" ]; then echo "$_min_all"
  else echo ""
  fi
}

direct_node_default_raw() {
  _node="$1"
  _raw=$(cat "$_node" 2>/dev/null)
  case "$_raw" in ''|*[!0-9]*) return 1 ;; esac
  case "$_node" in
    "$DIRECT_WIRELESS") echo $((_raw * 1000)) ;;
    *) echo "$_raw" ;;
  esac
}

# 记录“实际生效”的控制快照，供幂等判定使用。
# 关键：记录的是写入后【回读的真实值】，不是理论目标值 —— 驱动会对
# 某些电流值做四舍五入/裁剪，用理论值比对会导致每秒无条件重写（churn）。
direct_record_applied() {
  _t="${1:-}"
  mkdir -p "$XBT/state" 2>/dev/null
  _snap="$XBT/state/direct_applied"
  {
    echo "TARGET|${_t}"
    for _p in $(direct_current_nodes); do
      [ -n "$_p" ] || continue
      _raw=$(direct_node_default_raw "$_p" 2>/dev/null)
      [ -n "$_raw" ] && echo "NODE|${_p}|${_raw}"
    done
    for _p in $(direct_thermal_remove_nodes); do
      echo "THERM|${_p}|$(cat "$_p" 2>/dev/null)"
    done
    for _p in $(direct_limit_nodes); do
      echo "CTRL|${_p}|$(cat "$_p" 2>/dev/null)"
    done
  } > "$_snap" 2>/dev/null
}

read_voltage_uv() {
  for _p in \
    /sys/class/power_supply/battery/voltage_now \
    /sys/class/power_supply/main/voltage_now \
    /sys/class/power_supply/usb/voltage_now
  do
    _v=$(cat "$_p" 2>/dev/null)
    case "$_v" in ''|*[!0-9]*) continue ;; esac
    [ "$_v" -gt 1000 ] 2>/dev/null || continue
    if [ "$_v" -lt 100000 ] 2>/dev/null; then _v=$((_v * 1000)); fi
    echo "$_v"
    return 0
  done
  echo ""
}

target_current_ma() {
  if [ "$POWER_MECH" = "curr" ]; then
    tier_target_ma "$(power_now)"
    return
  fi
  [ "$(power_now)" = "inf" ] && { echo 20000; return; }
  # ctrl 机制下按瓦精确限流由 ctrl_limit 完成，无独立目标电流。
  echo ""
}

quantize_current_ma() {
  case "$1" in
    ''|*[!0-9]*) echo ""; return ;;
  esac
  awk -v r="$1" 'BEGIN {
    q = int((r + 50) / 100) * 100;
    if (q < 500) q = 500;
    if (q > 12000) q = 12000;
    printf "%d", q;
  }'
}

snapshot_current_limit() {
  mkdir -p "$XBT/state" 2>/dev/null
  _snap="$XBT/state/direct_current_defaults"
  # 迁移旧版单节点备份，避免升级后丢失原始电流。
  _old_node=$(cat "$XBT/state/current_limit_node" 2>/dev/null)
  _old_raw=$(cat "$XBT/state/current_limit_default" 2>/dev/null)
  case "$_old_raw" in
    ''|*[!0-9]*) ;;
    *)
      [ -n "$_old_node" ] && ! grep -qF "${_old_node}|" "$_snap" 2>/dev/null &&
        echo "${_old_node}|${_old_raw}" >> "$_snap"
      ;;
  esac

  for _p in $(direct_current_nodes); do
    [ -n "$_p" ] || continue
    grep -qF "${_p}|" "$_snap" 2>/dev/null && continue
    _raw=$(direct_node_default_raw "$_p") || continue
    case "$_raw" in ''|*[!0-9]*|0) continue ;; esac
    [ "$_raw" -gt 0 ] 2>/dev/null || continue
    echo "${_p}|${_raw}" >> "$_snap"
  done
  return 0
}

snapshot_control_limit() {
  mkdir -p "$XBT/state" 2>/dev/null
  _snap="$XBT/state/direct_control_defaults"

  # ===== v2.9.4 【污染自愈】=====
  # 【问题】旧版本（≤v2.7.12）在【写完 thermal_remove=1 之后】才抓这个快照，
  #   把模块自己写的 1 当成了"驱动原厂值"存进来。而下面的写入逻辑是
  #   "该节点已有记录就跳过"（grep -qF + continue）→ **已污染的旧文件永远修不回来**；
  #   升级迁移（customize.sh 的 state 白名单）又会把它原样带到新版 →
  #   卸载时 restore_control_limit 把 1 写回 → 温控总闸永久停在"绕过驱动温控表"，
  #   DT 温控保护被解除，而还原说明文件还写"已自动还原" → 用户完全无感。
  # 【判据】驱动原厂默认 = 0（service.sh 有作者实机记录 `set wired thermal remove: 0`），
  #   value=1 只可能是模块自己写的 → 命中即污染，无害化修正为 0 并保留证据副本。
  #
  # ===== v2.10.8 【修 bug】=====
  # 【旧写法（错）】sed -i -E 's|(thermal_remove)\|1$|\1|0|' "$_snap"
  #   sed 的分隔符是 `|`，而数据里本来就有 `|` → 表达式被解析成
  #   pattern=(thermal_remove)|1$  replacement=\1  flags=0  → sed 直接报错退出，
  #   错误又被 2>/dev/null 吞掉，而下一行 log 无条件打印"repaired"。
  # 【后果】快照里的 thermal_remove|1 永远修不掉，且每 1.5 秒重试一次刷日志
  #   （实机取证：haotian / v2.10.1-extreme，8857 次 / 3.9 小时）。
  #   卸载时 restore_control_limit 会把 1 写回去 → DT 温控保护被永久解除。
  # 【新写法】不用 sed，直接逐行重建快照文件 + 重建后复验；失败如实告警，不谎报成功。
  if [ -s "$_snap" ] && grep -qE 'thermal_remove\|1$' "$_snap" 2>/dev/null; then
    [ -f "$_snap.polluted" ] || cp -f "$_snap" "$_snap.polluted" 2>/dev/null
    _fix="$_snap.fix.$$"
    : > "$_fix" 2>/dev/null
    while IFS= read -r _ln; do
      case "$_ln" in
        *'|thermal_remove|1') printf '%s\n' "${_ln%1}0" >> "$_fix" ;;
        *)                    printf '%s\n' "$_ln"      >> "$_fix" ;;
      esac
    done < "$_snap"
    if [ -s "$_fix" ] && ! grep -qE 'thermal_remove\|1$' "$_fix" 2>/dev/null; then
      mv -f "$_fix" "$_snap" 2>/dev/null
      log "snapshot: repaired polluted thermal_remove|1 -> 0 (evidence kept as .polluted)"
    else
      rm -f "$_fix" 2>/dev/null
      log "snapshot: ⚠ polluted snapshot repair FAILED（保留原文件，卸载时请人工核对 thermal_remove）"
    fi
  fi

  for _p in $(direct_control_nodes); do
    [ -n "$_p" ] || continue
    grep -qF "${_p}|" "$_snap" 2>/dev/null && continue
    _raw=$(cat "$_p" 2>/dev/null)
    case "$_raw" in ''|*[!0-9]*) continue ;; esac
    echo "${_p}|${_raw}" >> "$_snap"
  done
  return 0
}

restore_current_limit() {
  _snap="$XBT/state/direct_current_defaults"
  [ -s "$_snap" ] || return 1
  _ok=0
  while IFS='|' read -r _p _raw; do
    [ -n "$_p" ] || continue
    case "$_raw" in ''|*[!0-9]*) continue ;; esac
    if [ -e "$_p" ]; then
      chmod 664 "$_p" 2>/dev/null
      [ -w "$_p" ] || continue
      echo "$_raw" > "$_p" 2>>"$LOG" && _ok=1
    fi
  done < "$_snap"
  [ "$_ok" = "1" ]
}

restore_control_limit() {
  _snap="$XBT/state/direct_control_defaults"
  [ -s "$_snap" ] || return 1
  _ok=0
  while IFS='|' read -r _p _raw; do
    [ -n "$_p" ] || continue
    case "$_raw" in ''|*[!0-9]*) continue ;; esac
    if [ -e "$_p" ]; then
      chmod 664 "$_p" 2>/dev/null
      [ -w "$_p" ] || continue
      echo "$_raw" > "$_p" 2>>"$LOG" && _ok=1
    fi
  done < "$_snap"
  [ "$_ok" = "1" ]
}

# ---- 功率选择菜单辅助 ----
sub_mode() {
  echo
  echo "充电模式 (当前: $(power_label))"
  echo "  1) ⚡全速（不限速，急用顶满，随电量约 20~48W）"
  echo "  2) 🚀快速·${FAST_W:-40}W MAX（单电流模式，快而不顶满）"
  echo "  3) 🔸中等·${MID_W:-25}W MAX（单电流模式，日常/偏快）"
  echo "  4) 🐢慢充·${SLOW_W:-10}W MAX（单电流模式，睡觉挂机最凉）"
  echo "  9) 查看状态"
  echo "  0) 返回"
  printf "选择: "; read _n
  case "$_n" in
    1) sh $XBT/scripts/power_limit.sh set inf ;;
    2) sh $XBT/scripts/power_limit.sh set fast ;;
    3) sh $XBT/scripts/power_limit.sh set mid ;;
    4) sh $XBT/scripts/power_limit.sh set slow ;;
    9) sh $XBT/scripts/power_limit.sh status ;;
  esac
  printf '\n按回车返回...'; read _x
}
# ---- 云控屏蔽功能区（v1.6.0）----
cloud_line() {
  _cg=$(cfg_get cloud_guard 1)
  if [ "$_cg" = "1" ]; then _s="开"; else _s="关"; fi
  _f=$XBT/state/cloud_guard.state
  _lc="-"; _rl="待巡检"; _bt=0
  if [ -f "$_f" ]; then
    _lc=$(grep '^last_check=' "$_f" 2>/dev/null | tail -n 1 | cut -d= -f2)
    _r=$(grep '^last_result=' "$_f" 2>/dev/null | tail -n 1 | cut -d= -f2)
    _bt=$(grep '^blocked_total=' "$_f" 2>/dev/null | tail -n 1 | cut -d= -f2)
    case "$_r" in
      clean) _rl="正常" ;;
      blocked) _rl="有拦截" ;;
      off) _rl="未启用" ;;
      *) _rl="待巡检" ;;
    esac
  fi
  [ -n "$_lc" ] || _lc="-"
  [ -n "$_bt" ] || _bt=0
  echo "云控屏蔽 : ${_s} | 巡检:${_lc} ${_rl} | 拦截:${_bt}"
}

sub_cloud() {
  echo
  echo "[云控屏蔽 - BAA云端下发防护]"
  sh $XBT/scripts/cloud_guard.sh status
  echo
  echo "  1) 开启屏蔽 (v1h·服务跳过云端配置)"
  echo "  2) 关闭屏蔽 (恢复允许云端下发)"
  echo "  3) 立即巡检一次"
  echo "  4) 查看隔离区"
  echo "  0) 返回"
  printf "选择: "; read n
  case "$n" in
    1) sh $XBT/scripts/cloud_guard.sh on ;;
    2) sh $XBT/scripts/cloud_guard.sh off ;;
    3) sh $XBT/scripts/cloud_guard.sh check ;;
    4) ls -la $XBT/state/cloud_quarantine/ 2>/dev/null ;;
  esac
  printf '\n按回车返回...'; read x
}

# ---- BAA载荷格式自适应（v1.6.1）----
# 探测目标文件格式：enc=加密(BAA_ENC:) / plain=明文JSON / unknown
baa_probe_fmt() {
  _t="$BAA_TGT"
  [ -r "$_t" ] || { echo unknown; return; }
  if head -c 8 "$_t" 2>/dev/null | grep -q 'BAA_ENC:'; then echo enc; return; fi
  if head -c 64 "$_t" 2>/dev/null | grep -q '{'; then echo plain; return; fi
  echo unknown
}

# 当前应使用的载荷格式（baa_fmt=enc|plain 强制；auto=探测+缓存）
baa_use_fmt() {
  _cfg=$(cfg_get baa_fmt auto)
  case "$_cfg" in enc|plain) echo "$_cfg"; return ;; esac
  if [ "$(baa_state)" != "active" ]; then
    _p=$(baa_probe_fmt)
    case "$_p" in enc|plain)
      mkdir -p "$XBT/state" 2>/dev/null
      echo "$_p" > "$XBT/state/baa_fmt" 2>/dev/null
      echo "$_p"; return ;;
    esac
  fi
  _c=$(cat "$XBT/state/baa_fmt" 2>/dev/null)
  case "$_c" in plain) echo plain ;; *) echo enc ;; esac
}

# 固定使用 normal 基准载荷，充电速度由功率守护单独限制
baa_refresh_src() {
  _m=normal
  _f="$XBT/baa/modes/$_m.json"
  if [ "$(cfg_get cloud_guard 1)" = "1" ] && [ -f "$XBT/baa/modes/${_m}_nocloud.json" ]; then
    _f="$XBT/baa/modes/${_m}_nocloud.json"
  fi
  if [ "$(baa_use_fmt)" = "plain" ]; then
    _c="${_f%.json}_plain.json"
    [ -f "$_c" ] && _f="$_c"
  fi
  [ -f "$_f" ] && cp -f "$_f" "$BAA_SRC"
  echo "$(basename "$_f")"
}

# ---- BAA 目标路径自动探测（v2.5.0）----
# 兼容部分魔改系统把 BAA_config 放在非 /odm 路径的情况：
# 标准 /odm 路径优先，找不到时按常见 charger 配置目录顺序查找。
baa_detect_target() {
  _std=/odm/etc/charger/BAA_config_$DEV_CODE.json
  if [ -f "$_std" ]; then BAA_TGT="$_std"; return 0; fi
  for _d in /odm/etc/charger /vendor/etc/charger /my_product/etc/charger \
            /system/etc/charger /system_ext/etc/charger /product/etc/charger; do
    [ -d "$_d" ] || continue
    if [ -f "$_d/BAA_config_$DEV_CODE.json" ]; then
      BAA_TGT="$_d/BAA_config_$DEV_CODE.json"; return 0
    fi
    _any=$(ls "$_d"/BAA_config_*.json 2>/dev/null | head -n 1)
    [ -n "$_any" ] && { BAA_TGT="$_any"; return 0; }
  done
  BAA_TGT="$_std"
  return 1
}

# 加载时若当前目标不存在，自动探测一次（仅在缺失时执行，开销可忽略）
[ -f "$BAA_TGT" ] || baa_detect_target 2>/dev/null

# ---- 原厂满充电压上限（vterm）----
# volt_guard 用它判断用户设定值是否超过原厂上限；来源优先级：
#   state/fv_vterm_orig（fv_force 首次应用前锁定）→ stock 原厂备份 → fv_force_backup → 内置载荷
get_vterm_max() {
  for _src in "$XBT/state/fv_vterm_orig" \
              "$XBT/baa/stock_BAA_config_$DEV_CODE.json" \
              "$XBT/state/fv_force_backup/normal_plain.json"; do
    [ -f "$_src" ] || continue
    _mx=""
    if grep -qE '^[0-9]+$' "$_src" 2>/dev/null; then
      _mx=$(cat "$_src" 2>/dev/null)
    else
      _mx=$(grep -oE '"vterm"[[:space:]]*:[[:space:]]*[0-9]+' "$_src" 2>/dev/null \
            | grep -oE '[0-9]+$' | sort -n | tail -n 1)
    fi
    case "$_mx" in ''|0) continue ;; *) echo "$_mx"; return 0 ;; esac
  done
  _src="$XBT/baa/modes/normal_plain.json"
  [ -f "$_src" ] || _src="$XBT/baa/modes/normal_nocloud_plain.json"
  if [ -f "$_src" ]; then
    _mx=$(grep -oE '"vterm"[[:space:]]*:[[:space:]]*[0-9]+' "$_src" 2>/dev/null \
          | grep -oE '[0-9]+$' | sort -n | tail -n 1)
  fi
  case "$_mx" in ''|0) echo "" ;; *) echo "$_mx" ;; esac
}
