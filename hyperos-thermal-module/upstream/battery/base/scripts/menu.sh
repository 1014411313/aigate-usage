#!/system/bin/sh
# 电池解容工具箱 - 交互式主菜单
XBT=/data/adb/modules/battery_tune
. $XBT/scripts/common.sh

sub_unlock() {
  echo
  echo "解容开关操作:"
  echo "  1) 开启解容 (挂载BAA + smart_fv守护)"
  echo "  2) 关闭解容 (卸载 + 停守护)"
  echo "  3) 重同步"
  echo "  0) 返回"
  printf "选择: "; read n
  case "$n" in
    1) sh $XBT/scripts/unlock.sh on ;;
    2) sh $XBT/scripts/unlock.sh off ;;
    3) sh $XBT/scripts/unlock.sh sync ;;
  esac
  printf '\n按回车返回...'; read x
}

sub_pss() {
  echo
  echo "低电量锁容服务 (PowerSaveService) 当前: $(pss_state)"
  echo "  1) 禁用 —— 注意：会让「电池健康度」不显示（v2.9.10 起默认【不】禁用）"
  echo "  2) 恢复启用（恢复电池健康度显示）"
  printf "选择: "; read n
  # v2.9.10：CLI 开关必须【同时写配置】，否则重启后 service.sh 会按旧配置覆盖回去
  case "$n" in
    1) pm disable "$PSS" 2>/dev/null
       cfg_set pss_disable 1 2>/dev/null
       echo 1 > "$XBT/state/pss_disabled_by_module" 2>/dev/null
       echo "done: $(pss_state)  (pss_disable=1，重启后保持)" ;;
    2) pm enable "$PSS" 2>/dev/null
       cfg_set pss_disable 0 2>/dev/null
       rm -f "$XBT/state/pss_disabled_by_module" 2>/dev/null
       echo "done: $(pss_state)  (pss_disable=0，重启后保持)" ;;
  esac
  printf '\n按回车返回...'; read x
}

sub_cycle() {
  echo
  echo "当前循环值: $(cat /sys/class/xm_power/fg_master/cyclecount 2>/dev/null)"
  echo "开机维持: $(cfg_get cycle_fake '(空=不干预)')"
  echo "  1) 设为 50"
  echo "  2) 设为 20"
  echo "  3) 自定义值"
  echo "  4) 清除伪装设置"
  printf "选择: "; read n
  case "$n" in
    1) sh $XBT/scripts/unlock.sh cycle 50 ;;
    2) sh $XBT/scripts/unlock.sh cycle 20 ;;
    3) printf "输入数值: "; read v; sh $XBT/scripts/unlock.sh cycle "$v" ;;
    4) sh $XBT/scripts/unlock.sh cycle clear ;;
  esac
  printf '\n按回车返回...'; read x
}

pick_and_flash() {
  _tmp=/data/local/tmp/xt_dtbo_list.txt
  sh $XBT/scripts/dtbo.sh list > "$_tmp"
  echo
  echo "可用镜像:"
  while IFS='|' read id f sz sh tag; do
    [ -z "$id" ] && continue
    case "$id" in *[!0-9]*) continue ;; esac
    echo "  [$id] [$sh] [$sz bytes]"
    echo "        $f"
  done < "$_tmp"
  printf '\n选择编号 [0=取消]: '; read i
  [ "$i" = "0" ] && return
  sel=$(sed -n "${i}p" "$_tmp")
  case "$sel" in
    [0-9]*\|*) ;;
    *) echo "无效编号"; sleep 1; return ;;
  esac
  f=$(echo "$sel" | cut -d'|' -f2)
  echo; sh $XBT/scripts/dtbo.sh info "$f"
  echo
  printf "槽位 [a 或 b，回车取消]: "; read s
  case "$s" in a|b) ;; *) echo "已取消"; sleep 1; return ;; esac
  printf "确认刷入 [%s] -> dtbo_%s ? (输入 yes 确认): " "$(basename "$f")" "$s"; read ok
  if [ "$ok" = "yes" ]; then
    sh $XBT/scripts/dtbo.sh flash "$f" "$s"
  else
    echo "已取消"
  fi
  printf '\n按回车返回...'; read x
}

pick_restore() {
  BK=$(cfg_get backup_dir "/sdcard/Download/dtbo_backup")
  _tmp=/data/local/tmp/xt_restore_list.txt
  : > "$_tmp"
  _i=0
  for f in "$BK"/*.img; do
    [ -f "$f" ] || continue
    _i=$((_i+1))
    echo "$_i|$f" >> "$_tmp"
    echo "  [$_i] $(basename "$f") ($(stat -c %s "$f" 2>/dev/null) bytes)"
  done
  if [ "$_i" = "0" ]; then echo "(备份目录为空)"; sleep 1; return; fi
  printf '\n选择编号 [0=取消]: '; read i
  [ "$i" = "0" ] && return
  sel=$(sed -n "${i}p" "$_tmp" | cut -d'|' -f2)
  [ -f "$sel" ] || { echo "无效编号"; sleep 1; return; }
  echo
  printf "槽位 [a 或 b，回车取消]: "; read s
  case "$s" in a|b) ;; *) echo "已取消"; sleep 1; return ;; esac
  printf "确认刷入 [%s] -> dtbo_%s ? (输入 yes 确认): " "$(basename "$sel")" "$s"; read ok
  if [ "$ok" = "yes" ]; then
    sh $XBT/scripts/dtbo.sh flash "$sel" "$s"
  else
    echo "已取消"
  fi
  printf '\n按回车返回...'; read x
}

sub_dtbo() {
  echo
  echo "[DTBO 工具箱]"
  echo "  1) 查看状态 (两槽+MD5)"
  echo "  2) 备份当前槽"
  echo "  3) 选择文件刷入"
  echo "  4) 从备份恢复/刷回"
  echo "  5) 识别文件信息"
  echo "  0) 返回"
  printf "选择: "; read n
  case "$n" in
    1) sh $XBT/scripts/dtbo.sh status; printf '\n按回车返回...'; read x ;;
    2) printf "槽位 [回车=当前槽]: "; read s; _s=$(slot_letter); [ -n "$s" ] || s=$_s; sh $XBT/scripts/dtbo.sh backup "$s"; printf '\n按回车返回...'; read x ;;
    3) pick_and_flash ;;
    4) pick_restore ;;
    5) printf "输入文件路径: "; read f; sh $XBT/scripts/dtbo.sh info "$f"; printf '\n按回车返回...'; read x ;;
  esac
}

sub_diag() {
  echo
  echo "[诊断记录器]"
  sh $XBT/scripts/diag_log.sh status 2>/dev/null
  echo "  1) 开启连续记录 (后台持续采样)"
  echo "  2) 停止记录"
  echo "  3) 查看最近日志"
  echo "  4) 导出日志到 Download"
  echo "  5) 清空全部日志"
  echo "  0) 返回"
  printf "选择: "; read n
  case "$n" in
    1) sh $XBT/scripts/diag_log.sh start ;;
    2) sh $XBT/scripts/diag_log.sh stop ;;
    3) sh $XBT/scripts/diag_log.sh tail 80 ;;
    4) sh $XBT/scripts/diag_log.sh pack ;;
    5) sh $XBT/scripts/diag_log.sh clear ;;
  esac
  printf '\n按回车返回...'; read x
}

while true; do
  clear 2>/dev/null || true
  _u=$(cfg_get unlock 1)
  if [ "$_u" = "1" ]; then _us="开"; else _us="关"; fi
  _cg=$(cfg_get cloud_guard 1)
  if [ "$_cg" = "1" ]; then _cgs="开"; else _cgs="关"; fi
  _bs=$(baa_state_cn)
  _fv=$(cat $FV_NODE 2>/dev/null)
  _cap=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  echo "=========================================="
  echo "  电池解容工具箱 $(grep '^version=' $XBT/module.prop 2>/dev/null | head -n1 | cut -d= -f2) · $DEV_NAME"
  echo "=========================================="
  echo "  解容:$_us | BAA:$_bs | smart_fv:$_fv | 电量:${_cap}% |云控:$_cgs"
  echo "------------------------------------------"
  echo "  1) 电池信息"
  echo "  2) 解容开关 (当前:$_us)"
  echo "  3) DTBO 工具箱 (备份/刷写)"
  echo "  4) smart_fv 守护状态"
  echo "  5) 低电量锁容服务: $(pss_state)"
  echo "  6) 循环计数工具"
  echo "  7) 查看运行日志"
  echo "  8) 状态快照"
  echo "  9) 充电模式 (全速 / 40W MAX / 25W MAX / 10W MAX)"
  echo " 10) 云控屏蔽 (当前:$_cgs)"
  echo " 11) 诊断记录 (开/停/看/导出)"
  echo "  0) 退出"
  echo "=========================================="
  printf "请选择 [0-11]: "
  read c
  case "$c" in
    1) sh $XBT/scripts/battery_info.sh; printf '\n按回车返回...'; read x ;;
    2) sub_unlock ;;
    3) sub_dtbo ;;
    4) sh $XBT/scripts/fv_guard.sh status; printf '\n按回车返回...'; read x ;;
    5) sub_pss ;;
    6) sub_cycle ;;
    7) tail -n 40 "$LOG" 2>/dev/null; printf '\n按回车返回...'; read x ;;
    8) sh $XBT/action.sh; printf '\n按回车返回...'; read x ;;
    9) sub_mode ;;
    10) sub_cloud ;;
    11) sub_diag ;;
    0) exit 0 ;;
  esac
done