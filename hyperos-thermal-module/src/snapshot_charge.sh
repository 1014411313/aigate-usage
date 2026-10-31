#!/system/bin/sh
# snapshot_charge.sh —— 充电/满电节点快照（对比诊断用）
# 用法: snapshot_charge.sh [tag]     不传 tag 时自动按当前装的模块判断（battery_tune→stock / HyperOS_XJ→mod）
# 特性: 只读采集，不写任何系统节点；脚本不依赖模块目录，可拷到 /data/local/tmp 单独跑
#       全量遍历 power_supply / xm_power 时跳过会阻塞的 uevent、device、subsystem 等
MODX=/data/adb/modules/HyperOS_XJ
MODB=/data/adb/modules/battery_tune
TAG=${1:-}
if [ -z "$TAG" ]; then
    if [ -f "$MODB/module.prop" ] && [ ! -f "$MODX/module.prop" ]; then TAG=stock
    elif [ -f "$MODX/module.prop" ]; then TAG=mod
    else TAG=none
    fi
fi
case "$TAG" in ''|*[!A-Za-z0-9_-]*) TAG=mod ;; esac
OUT=/sdcard/Download/xj_charge_${TAG}_$(date '+%Y%m%d_%H%M%S').txt
MAXLEN=120

_dump_dir() {
    # $1=标题 $2=目录 $3=深度
    echo "[$1]"
    [ -d "$2" ] || { echo "dir=不存在"; echo; return 0; }
    find "$2" -maxdepth "${3:-2}" -type f 2>/dev/null | sort | while IFS= read -r f; do
        base=$(basename "$f")
        case "$base" in
            uevent|modalias|device|subsystem|power|driver|of_node|dev|name) continue ;;
        esac
        v=$(timeout 1 cat "$f" 2>/dev/null | tr -d '\n')
        [ ${#v} -gt $MAXLEN ] && v=$(echo "$v" | cut -c1-$MAXLEN)"…"
        echo "${f}=${v}"
    done
    echo
}

{
    echo "# xj_charge_snapshot tag=$TAG time=$(date '+%F %T')"
    echo

    echo "[meta]"
    echo "tag=$TAG"
    echo "model=$(getprop ro.product.model)"
    echo "market=$(getprop ro.product.marketname)"
    echo "device=$(getprop ro.product.device)"
    echo "os=$(getprop ro.mi.os.version.name)$(getprop ro.mi.os.version.incremental)"
    echo "android=$(getprop ro.build.version.release)"
    echo "kernel=$(uname -r)"
    echo "slot=$(getprop ro.boot.slot_suffix)"
    if [ -f "$MODX/module.prop" ]; then
        echo "mod_xj=$(grep -m1 '^version=' "$MODX/module.prop" | cut -d= -f2)"
    else
        echo "mod_xj=未安装"
    fi
    if [ -f "$MODB/module.prop" ]; then
        echo "mod_battery_tune=$(grep -m1 '^version=' "$MODB/module.prop" | cut -d= -f2)"
    else
        echo "mod_battery_tune=未安装"
    fi
    echo "dev_code=$(getprop ro.product.device)"
    echo

    echo "[cfg_xj]"
    for c in "$MODX/battery/config/settings.conf"; do
        [ -f "$c" ] || { echo "file=不存在"; continue; }
        grep -vE '^\s*#|^\s*$' "$c" 2>/dev/null | sort
    done
    echo

    echo "[cfg_stock]"
    for c in "$MODB/config/settings.conf"; do
        [ -f "$c" ] || { echo "file=不存在"; continue; }
        grep -vE '^\s*#|^\s*$' "$c" 2>/dev/null | sort
    done
    echo

    echo "[baa]"
    echo "mount_lines=$(mount 2>/dev/null | grep -c 'BAA_config')"
    for f in /odm/etc/charger/BAA_config_*.json; do
        [ -f "$f" ] || continue
        echo "$f=$(stat -c '%s' "$f" 2>/dev/null)B sha=$(sha256sum "$f" 2>/dev/null | cut -c1-16)"
        grep -oE '"(vterm|max_vbat|min_vbat|ffc_[a-z_]*)"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null | head -n 12
    done
    echo

    _dump_dir power_supply_battery /sys/class/power_supply/battery 1
    _dump_dir power_supply_usb     /sys/class/power_supply/usb     1
    _dump_dir power_supply_wireless /sys/class/power_supply/wireless 1
    _dump_dir power_supply_main    /sys/class/power_supply/main    1
    _dump_dir charger_thermal      /sys/class/xm_power/charger/charger_thermal 1
    _dump_dir charger_common       /sys/class/xm_power/charger/charger_common 1
    _dump_dir fg_master            /sys/class/xm_power/fg_master  1
    _dump_dir wireless_master      /sys/class/xm_power/wireless_master 1

    echo "[dt]"
    for d in /proc/device-tree/soc/mca_strategy_quick_charge \
             /proc/device-tree/soc/mca_strategy_quick_wireless_class \
             /proc/device-tree/soc/mca_buckchg_jeita; do
        [ -d "$d" ] || { echo "$d=不存在"; continue; }
        for f in "$d"/*; do
            [ -f "$f" ] || continue
            echo "${f}=$(od -An -tx1 "$f" 2>/dev/null | tr -d ' \n' | cut -c1-96)"
        done
    done
    echo

    echo "[thermal_conf]"
    for f in /data/vendor/thermal/config/thermal-normal.conf; do
        if [ -f "$f" ]; then
            echo "$f=$(stat -c '%s' "$f")B sha=$(sha256sum "$f" | cut -c1-16)"
        else
            echo "$f=不存在"
        fi
    done
    echo
} > "$OUT" 2>/dev/null

sync 2>/dev/null
echo "快照已保存：$OUT"
echo "PATH=$OUT"
exit 0
