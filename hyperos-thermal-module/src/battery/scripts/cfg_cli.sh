#!/system/bin/sh
# 电池仅解容可改电压 - 配置读写 CLI（root 模块脚本通道）
# v1.0.19：WebUI 配置写入统一走此脚本（内部复用 cfg_set 成熟写入逻辑——
#   末行换行处理/多行去重/目录兜底），取代 WebUI 内裸 echo/sed 直接写
#   /data/local/tmp/battery_tune.conf 的不稳定通道。
# 用法：cfg_cli.sh get <key> [default]    # 读配置（USER_CONF 优先，settings.conf 兜底）
#       cfg_cli.sh set <key> <value>      # 写配置到 USER_CONF，成功后回显 key=value
XBT=/data/adb/modules/HyperOS_XJ/battery
. "$XBT/scripts/common.sh" 2>/dev/null || exit 1
case "$1" in
  get)
    cfg_get "$2" "$3"
    ;;
  set)
    [ -n "$2" ] || { echo "ERR: missing key"; exit 2; }
    cfg_set "$2" "$3"
    # 回读校验：cfg_set 成功后立即读回，不一致=写入失败（磁盘/权限问题）
    _back=$(cfg_get "$2" "")
    if [ "$_back" = "$3" ]; then
      echo "$2=$3"
    else
      echo "ERR: write-back mismatch (got[$_back] want[$3])" >&2
      exit 3
    fi
    ;;
  *)
    echo "usage: cfg_cli.sh get|set <key> [value]" >&2
    exit 1
    ;;
esac
exit 0
