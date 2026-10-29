#!/system/bin/sh
# 安装期 DTBO 刷入：只在 OS4 上、只写当前槽的 dtbo 分区，先备份后写入并整分区校验
XBT=${XBT:-/data/adb/modules/HyperOS_XJ/battery}
DR="$XBT/dtbo"
BK=/sdcard/Download/dtbo_backup
PAD=/data/local/tmp/xj_dtbo_pad.img
say() { echo "$1"; }

DEV=$(getprop ro.product.device)
VD=$(getprop ro.product.vendor.device)
NM=$(getprop ro.product.name)
CODE=""
for _c in xuanyuan dada haotian nezha myron annibale bixi onyx popsicle miro songyuan warsaw pudding pandora byron; do
    if [ "$DEV" = "$_c" ] || [ "$VD" = "$_c" ] || [ "$NM" = "$_c" ]; then CODE=$_c; break; fi
done
if [ -z "$CODE" ]; then
    say "跳过 DTBO：机型 ${DEV:-未知} 不在支持列表"
    exit 4
fi

_conf="$XBT/config/settings.conf"
if [ -f "$_conf" ]; then
    if grep -q '^dev_code=' "$_conf" 2>/dev/null; then
        sed -i "s/^dev_code=.*/dev_code=$CODE/" "$_conf" 2>/dev/null
    else
        [ -s "$_conf" ] && [ "$(tail -c1 "$_conf" | wc -l)" = "0" ] && echo "" >> "$_conf"
        echo "dev_code=$CODE" >> "$_conf"
    fi
fi

IMG="$DR/$CODE.img"

OS_INC=$(getprop ro.mi.os.version.incremental)
OS_NAME=$(getprop ro.mi.os.version.name)
case "$OS_NAME$OS_INC" in
    *OS4*) ;;
    *) say "记录机型 $CODE，但系统非 OS4（name=${OS_NAME:-未知} inc=${OS_INC:-未知}），跳过 DTBO"; exit 3 ;;
esac

if [ ! -f "$IMG" ]; then
    say "跳过 DTBO：包内没有 $CODE.img"
    exit 5
fi

SLOT=$(getprop ro.boot.slot_suffix)
SLOT=${SLOT#_}
if [ -z "$SLOT" ]; then SLOT=$(getprop ro.boot.slot 2>/dev/null); fi
if [ -z "$SLOT" ]; then SLOT=b; fi
case "$SLOT" in
    a|b) ;;
    *) say "跳过 DTBO：槽位无法识别（$SLOT）"; exit 6 ;;
esac

DEVC=/dev/block/by-name/dtbo_$SLOT
if [ -e "$DEVC" ]; then :; else
    say "跳过 DTBO：$DEVC 不存在"
    exit 7
fi
REAL=$(readlink -f "$DEVC" 2>/dev/null)
case "$REAL" in
    /dev/block/*) ;;
    *) say "跳过 DTBO：$DEVC 解析异常（$REAL）"; exit 8 ;;
esac
if [ -b "$REAL" ]; then :; else
    say "跳过 DTBO：$REAL 不是块设备"
    exit 9
fi

MG=$(od -An -tx1 -N4 "$IMG" 2>/dev/null | tr -d ' \n')
if [ "$MG" = "d7b7ab1e" ]; then :; else
    say "跳过 DTBO：镜像头不是标准 dtbo（magic=$MG）"
    exit 10
fi

F_SZ=$(stat -c %s "$IMG" 2>/dev/null)
D_SZ=$(blockdev --getsize64 "$DEVC" 2>/dev/null)
case "$F_SZ" in ''|*[!0-9]*) say "跳过 DTBO：读不到镜像大小"; exit 11 ;; esac
case "$D_SZ" in ''|*[!0-9]*) say "跳过 DTBO：读不到分区大小（blockdev 不可用）"; exit 12 ;; esac
if [ "$D_SZ" -le 0 ]; then say "跳过 DTBO：分区大小为 0"; exit 13; fi
if [ "$F_SZ" -gt "$D_SZ" ]; then
    say "跳过 DTBO：镜像 ${F_SZ}B 大于分区 ${D_SZ}B"
    exit 14
fi

WANT=$(sha256sum "$IMG" 2>/dev/null | awk '{print $1}')
CUR=$(head -c "$F_SZ" "$DEVC" 2>/dev/null | sha256sum | awk '{print $1}')
if [ -n "$WANT" ] && [ "$CUR" = "$WANT" ]; then
    say "DTBO：当前槽 dtbo_$SLOT 已是该镜像，无需刷入"
    echo "$(date '+%F %T') install_flash_SKIP $SLOT already=$WANT <- $CODE.img" >> "$BK/manifest.txt" 2>/dev/null
    exit 0
fi

mkdir -p "$BK" 2>/dev/null
BF="$BK/dtbo_${SLOT}_before_install_$(date +%Y%m%d-%H%M%S).img"
say "目标分区：$DEVC -> $REAL（${D_SZ}B）"
say "镜像文件：$CODE.img（${F_SZ}B）"
say "备份当前槽到 $BF"
if ! dd if="$DEVC" of="$BF" bs=1M 2>/dev/null; then
    say "备份失败，已中止（分区未改动）"
    exit 15
fi
sync

SRC="$IMG"
if [ "$F_SZ" -lt "$D_SZ" ]; then
    rm -f "$PAD" 2>/dev/null
    if cp -f "$IMG" "$PAD" 2>/dev/null && truncate -s "$D_SZ" "$PAD" 2>/dev/null && \
       [ "$(stat -c %s "$PAD" 2>/dev/null)" = "$D_SZ" ]; then
        SRC="$PAD"
        say "镜像已补齐至分区大小"
    else
        rm -f "$PAD" 2>/dev/null
        say "补齐失败，已中止（分区未改动）"
        echo "$(date '+%F %T') install_flash_ABORT pad_failed slot=$SLOT fsz=$F_SZ dsz=$D_SZ" >> "$BK/manifest.txt" 2>/dev/null
        exit 16
    fi
fi

say "写入中..."
if ! dd if="$SRC" of="$DEVC" bs=1M 2>/dev/null; then
    rm -f "$PAD" 2>/dev/null
    say "写入失败，请用备份恢复：$BF"
    echo "$(date '+%F %T') install_flash_WRITE_FAIL $SLOT" >> "$BK/manifest.txt" 2>/dev/null
    exit 17
fi
sync

N_SHA=$(head -c "$D_SZ" "$DEVC" 2>/dev/null | sha256sum | awk '{print $1}')
I_SHA=$(sha256sum "$SRC" 2>/dev/null | awk '{print $1}')
rm -f "$PAD" 2>/dev/null
if [ -n "$N_SHA" ] && [ "$N_SHA" = "$I_SHA" ]; then
    say "刷入成功且校验一致（整分区 ${D_SZ}B，重启后生效）"
    echo "$(date '+%F %T') install_flash_OK $SLOT $N_SHA <- $CODE.img scope=part:$D_SZ" >> "$BK/manifest.txt" 2>/dev/null
    exit 0
fi
say "校验不一致：分区=$N_SHA 镜像=$I_SHA"
say "请用备份恢复：$BF"
echo "$(date '+%F %T') install_flash_VERIFY_FAIL $SLOT part=$N_SHA file=$I_SHA" >> "$BK/manifest.txt" 2>/dev/null
exit 18
