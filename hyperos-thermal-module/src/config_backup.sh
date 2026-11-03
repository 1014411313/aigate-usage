#!/system/bin/sh
# config_backup.sh —— 把当前用户设置同步到模块目录外的备份
# 用途：模块更新会整体替换模块目录，安装时从这份备份恢复。
# 调用时机：界面「立即备份」按钮、cfg_set 写配置时（只同步 settings.conf）、保存温控配置时。
# 注意：不做定时备份，只在这几个时机写。
MODDIR=${MODDIR:-/data/adb/modules/HyperOS_XJ}
BAK=${XJ_BAK:-/data/adb/HyperOS_XJ_data}
n=0
failed=0

mkdir -p "$BAK/config" "$BAK/battery/config" "$BAK/profiles" 2>/dev/null || exit 1

for f in settings.json rearscreen.json bypass_manual; do
    [ -s "$MODDIR/config/$f" ] || continue
    cmp -s "$MODDIR/config/$f" "$BAK/config/$f" 2>/dev/null && continue
    cp -f "$MODDIR/config/$f" "$BAK/config/$f" 2>/dev/null && n=$((n + 1)) || failed=1
done

for f in "$MODDIR"/battery/config/settings.conf; do
    [ -s "$f" ] || continue
    cmp -s "$f" "$BAK/battery/config/settings.conf" 2>/dev/null && continue
    cp -f "$f" "$BAK/battery/config/settings.conf" 2>/dev/null && n=$((n + 1)) || failed=1
done

for p in "$MODDIR"/profiles/*.conf; do
    [ -f "$p" ] || continue
    bn=$(basename "$p")
    cmp -s "$p" "$BAK/profiles/$bn" 2>/dev/null && continue
    cp -f "$p" "$BAK/profiles/$bn" 2>/dev/null && n=$((n + 1)) || failed=1
done

# 运行态里需要跨升级保留的只有“恢复资料”，不是 PID/节流时间戳：
# fv_force_backup 是强改电压前的原载荷，cloud_quarantine 是云控隔离的系统文件，
# extra_dirs.txt 是用户自己加的 DTBO 扫描目录。升级替换模块目录时就靠这份备份找回。
for d in fv_force_backup cloud_quarantine; do
    [ -d "$MODDIR/battery/state/$d" ] || continue
    if ! diff -rq "$MODDIR/battery/state/$d" "$BAK/battery/state/$d" >/dev/null 2>&1; then
        mkdir -p "$BAK/battery/state" 2>/dev/null
        cp -af "$MODDIR/battery/state/$d" "$BAK/battery/state/" 2>/dev/null && n=$((n + 1)) || failed=1
    fi
done
if [ -s "$MODDIR/battery/state/extra_dirs.txt" ]; then
    cmp -s "$MODDIR/battery/state/extra_dirs.txt" "$BAK/battery/state/extra_dirs.txt" 2>/dev/null || {
        mkdir -p "$BAK/battery/state" 2>/dev/null
        cp -f "$MODDIR/battery/state/extra_dirs.txt" "$BAK/battery/state/extra_dirs.txt" 2>/dev/null && n=$((n + 1)) || failed=1
    }
fi

if [ "$failed" = 1 ]; then
    echo "部分设置备份失败，请检查磁盘空间与目录权限" >&2
    exit 1
fi
if [ "$n" -gt 0 ]; then
    echo "已同步 $n 项设置到备份"
else
    echo "设置已是最新，无需同步"
fi
exit 0
