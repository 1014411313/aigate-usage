#!/system/bin/sh
# config_backup.sh —— 把当前用户设置同步到模块目录外的备份
# 用途：模块更新会整体替换模块目录，安装时从这份备份恢复。
# 调用时机：界面「立即备份」按钮、cfg_set 写配置时（只同步 settings.conf）、保存温控配置时。
# 注意：不做定时备份，只在这几个时机写。
MODDIR=${MODDIR:-/data/adb/modules/HyperOS_XJ}
BAK=${XJ_BAK:-/data/adb/HyperOS_XJ_data}
n=0

mkdir -p "$BAK/config" "$BAK/battery/config" "$BAK/profiles" 2>/dev/null

for f in settings.json bypass_manual current_mode; do
    [ -s "$MODDIR/config/$f" ] || continue
    cmp -s "$MODDIR/config/$f" "$BAK/config/$f" 2>/dev/null && continue
    cp -f "$MODDIR/config/$f" "$BAK/config/$f" 2>/dev/null && n=$((n + 1))
done

for f in "$MODDIR"/battery/config/settings.conf; do
    [ -s "$f" ] || continue
    cmp -s "$f" "$BAK/battery/config/settings.conf" 2>/dev/null && continue
    cp -f "$f" "$BAK/battery/config/settings.conf" 2>/dev/null && n=$((n + 1))
done

for p in "$MODDIR"/profiles/*.conf; do
    [ -f "$p" ] || continue
    bn=$(basename "$p")
    [ "$bn" = "default.conf" ] && continue
    cmp -s "$p" "$BAK/profiles/$bn" 2>/dev/null && continue
    cp -f "$p" "$BAK/profiles/$bn" 2>/dev/null && n=$((n + 1))
done

if [ "$n" -gt 0 ]; then
    echo "已同步 $n 项设置到备份"
else
    echo "设置已是最新，无需同步"
fi
exit 0
