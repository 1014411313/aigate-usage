#!/system/bin/sh
# GPU 智能升频 · 安装脚本
# KernelSU / Magisk 安装时执行，环境变量 MODPATH 指向模块目录。

ui_print() { echo "$1"; }

MODPATH=${MODPATH:-$MODDIR}
[ -n "$MODPATH" ] || { ui_print "! 无法确定模块目录"; exit 1; }

ui_print "- GPU 智能升频 V1.0"
ui_print "- 仅调整 GPU 下限，不改动 CPU"

# 目录与文件权限：脚本必须可执行，配置类保持只读
chmod 0755 "$MODPATH/service.sh" "$MODPATH/uninstall.sh" "$MODPATH/action.sh" 2>/dev/null
chmod 0755 "$MODPATH/gpud" 2>/dev/null
chmod 0755 "$MODPATH/webroot/api.sh" 2>/dev/null
chmod 0644 "$MODPATH/webroot/index.html" "$MODPATH/module.prop" "$MODPATH/default.conf" 2>/dev/null

# 数据目录放在模块之外：管理器升级模块是「先删目录再解包」，
# 放在里面会被新包的默认值盖掉，用户改的配置一次升级就没了。
DATA=/data/adb/gpu_autoboost
mkdir -p "$DATA/run" 2>/dev/null
chmod 0755 "$DATA" "$DATA/run" 2>/dev/null
if [ ! -f "$DATA/config.conf" ]; then
    cp "$MODPATH/default.conf" "$DATA/config.conf" 2>/dev/null
    chmod 0644 "$DATA/config.conf" 2>/dev/null
else
    # 升级时把新版新增的键补进现有配置，不覆盖用户已改的值。
    # 守护对缺失键有内置默认值，但 WebUI 会读不到，滑杆就显示不出来。
    while IFS='=' read -r k v; do
        case "$k" in ''|'#'*) continue ;; esac
        grep -q "^$k=" "$DATA/config.conf" 2>/dev/null || \
            printf '%s=%s\n' "$k" "$v" >> "$DATA/config.conf"
    done < "$MODPATH/default.conf"
fi

ui_print "- 安装完成，重启后生效"
