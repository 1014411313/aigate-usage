#!/system/bin/sh
# 电池解容工具箱 - DTBO 工具
# 用法: dtbo.sh status | list | info <file> | backup [slot] | flash <file> [slot] | autobackup
#       dtbo.sh dirs | dirslist | adddir <目录> | deldir <目录>   (扫描目录管理)
# 注意: list 仅扫描你通过 adddir / WebUI 添加的目录（不再自动扫描内置目录）
#       备份默认保存到 /sdcard/Download/dtbo_backup（可在 settings.conf 改 backup_dir）
XBT=/data/adb/modules/HyperOS_XJ/battery
. $XBT/scripts/common.sh

BK=$(cfg_get backup_dir "/sdcard/Download/dtbo_backup")
MANIFEST=$BK/manifest.txt
BLK=/dev/block/by-name
EDIRS_FILE=$XBT/state/extra_dirs.txt

mkdir -p "$BK" 2>/dev/null
mkdir -p "$XBT/state" 2>/dev/null

slot_dev() { echo "$BLK/dtbo_$1"; }

blk_sha() { dd if="$1" bs=1M 2>/dev/null | sha256sum | awk '{print $1}'; }

blk_md5() { dd if="$1" bs=1M 2>/dev/null | md5sum | awk '{print $1}'; }

show_status() {
  echo "[两槽状态]"
  echo "当前卡槽: _$(slot_letter)"
  echo "备份目录: $BK"
  slot=$(slot_letter)
  for s in a b; do
    _d=$(slot_dev $s)
    [ -e "$_d" ] || continue
    _sha=$(blk_sha "$_d")
    _md5=$(blk_md5 "$_d")
    _short=$(echo "$_sha" | cut -c1-12)
    _cur=""
    [ "$s" = "$slot" ] && _cur=" (运行槽)"
    echo "  dtbo_$s : $_short...${_cur}"
    echo "  md5: $_md5"
  done
}

# ---- 扫描：单个目录中的 *.img（内部使用，更新全局 _i） ----
scan_one_dir() {
  [ -d "$1" ] || return 0
  for _f in "$1"/*.img; do
    [ -f "$_f" ] || continue
    _i=$((_i+1))
    _sz=$(stat -c %s "$_f" 2>/dev/null)
    _sh=$(hash_of "$_f")
    echo "$_i|$_f|$_sz|$(echo $_sh | cut -c1-12)|"
  done
}

list_candidates() {
  _i=0
  _n=0
  if [ -s "$EDIRS_FILE" ]; then
    while IFS= read -r _ed; do
      [ -n "$_ed" ] || continue
      _n=$((_n+1))
      scan_one_dir "$_ed"
    done < "$EDIRS_FILE"
  fi
  if [ "$_i" = "0" ]; then
    if [ "$_n" = "0" ]; then
      echo "(未添加扫描目录——请先在“自定义目录”里添加至少一个文件夹)"
    else
      echo "(已扫描 $_n 个目录，未找到 .img 文件)"
    fi
  fi
  return 0
}

show_dirs() {
  echo "[扫描目录]（列表 = 你添加的目录）"
  echo
  if [ -s "$EDIRS_FILE" ]; then
    _n=0
    while IFS= read -r _d; do
      [ -n "$_d" ] || continue
      _n=$((_n+1))
      if [ -d "$_d" ]; then echo "  ✓ $_d"; else echo "  - $_d (目录不存在)"; fi
    done < "$EDIRS_FILE"
    [ "$_n" = "0" ] && echo "  (无)"
  else
    echo "  (无——尚未添加任何目录)"
  fi
  echo
  echo "添加: dtbo.sh adddir <目录>  |  移除: dtbo.sh deldir <目录>"
}

list_extra_dirs() {
  [ -s "$EDIRS_FILE" ] && cat "$EDIRS_FILE"
  return 0
}

norm_dir() { echo "$1" | sed 's:/*$::'; }

add_scan_dir() {
  _p=$(norm_dir "$1")
  [ -n "$_p" ] || { echo "用法: dtbo.sh adddir <目录路径>"; return 1; }
  case "$_p" in
    /*) ;;
    *) echo "请使用绝对路径（以 / 开头）"; return 1 ;;
  esac
  [ -d "$_p" ] || { echo "目录不存在: $_p （请先在文件管理器创建该文件夹）"; return 1; }
  mkdir -p "$XBT/state"
  touch "$EDIRS_FILE"
  if grep -Fxq "$_p" "$EDIRS_FILE" 2>/dev/null; then
    echo "已在扫描列表中: $_p"; return 0
  fi
  echo "$_p" >> "$EDIRS_FILE"
  log "dtbo: adddir $_p"
  echo "已添加: $_p"
  echo "现在刷新镜像列表即可看到该目录中的 .img 文件"
}

del_scan_dir() {
  _p=$(norm_dir "$1")
  [ -n "$_p" ] || { echo "用法: dtbo.sh deldir <目录路径>"; return 1; }
  [ -s "$EDIRS_FILE" ] || { echo "扫描列表为空"; return 0; }
  if ! grep -Fxq "$_p" "$EDIRS_FILE" 2>/dev/null; then
    echo "不在扫描列表中: $_p"; return 1
  fi
  grep -Fxv "$_p" "$EDIRS_FILE" > "$EDIRS_FILE.tmp" 2>/dev/null
  mv -f "$EDIRS_FILE.tmp" "$EDIRS_FILE"
  log "dtbo: deldir $_p"
  echo "已移除: $_p"
}

show_info() {
  f="$1"
  [ -f "$f" ] || { echo "文件不存在: $f"; return 1; }
  echo "文件   : $f"
  echo "大小   : $(stat -c %s "$f") bytes"
  _mt=$(stat -c %Y "$f" 2>/dev/null)
  [ -n "$_mt" ] && echo "修改时间: $(date -d @$_mt '+%F %T' 2>/dev/null || echo $_mt)"
  echo "sha256 : $(hash_of "$f")"
  _mg=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
  echo "magic  : $_mg $( [ "$_mg" = "d7b7ab1e" ] && echo '(标准dtbo)' || echo '(注意:非标准头)' )"
}

do_backup() {
  s="${1:-$(slot_letter)}"
  case "$s" in a|b) ;; *) echo "槽参数必须是 a 或 b"; return 1 ;; esac
  dev=$(slot_dev "$s")
  [ -e "$dev" ] || { echo "分区不存在: $dev"; return 1; }
  mkdir -p "$BK"
  _sha=$(blk_sha "$dev")
  _f="$BK/dtbo_${s}_manual_$(date +%Y%m%d-%H%M%S).img"
  echo "备份 dtbo_$s ..."
  if dd if="$dev" of="$_f" bs=1M 2>/dev/null; then
    sync
    echo "$(date '+%F %T') manual_backup $s $_sha $(basename "$_f")" >> "$MANIFEST"
    echo "备份完成: $_f"
    echo "sha256: $_sha"
  else
    echo "备份失败"; rm -f "$_f"
    return 1
  fi
}

do_flash() {
  f="$1"
  s="${2:-$(slot_letter)}"
  case "$s" in a|b) ;; *) echo "槽参数必须是 a 或 b"; return 1 ;; esac
  [ -f "$f" ] || { echo "文件不存在: $f"; return 1; }
  dev=$(slot_dev "$s")
  [ -e "$dev" ] || { echo "分区不存在: $dev"; return 1; }

  fsz=$(stat -c %s "$f" 2>/dev/null)
  dsz=$(blockdev --getsize64 "$dev" 2>/dev/null)
  echo "目标分区: $dev ($dsz bytes)"
  echo "镜像文件: $f ($fsz bytes)"
  if [ -n "$dsz" ] && [ "$fsz" -gt "$dsz" ]; then
    echo "错误: 镜像大于分区，中止"
    return 1
  fi
  if [ -n "$dsz" ] && [ "$fsz" -lt "$dsz" ]; then
    echo "提示: 镜像小于分区，将按文件大小写入（未补全镜像可能残留旧尾部数据）"
  fi

  _bsha=$(blk_sha "$dev")
  _dup=""
  [ -f "$MANIFEST" ] && _dup=$(grep -F "$_bsha" "$MANIFEST" | head -n 1)
  if [ -z "$_dup" ]; then
    mkdir -p "$BK"
    _bf="$BK/dtbo_${s}_before_$(date +%Y%m%d-%H%M%S).img"
    echo "-> 自动备份当前槽到: $_bf"
    if dd if="$dev" of="$_bf" bs=1M 2>/dev/null; then
      sync
      echo "$(date '+%F %T') auto_before_flash $s $_bsha $(basename "$_bf")" >> "$MANIFEST"
      echo "   备份sha256: $_bsha"
    else
      echo "   ! 备份失败，为安全中止刷写"
      return 1
    fi
  else
    echo "-> 当前槽内容已有备份记录，跳过: $_bsha"
  fi

  echo "-> 刷入中..."
  # 若镜像小于分区：先补齐到分区大小（补 0）再写。直接 dd 只会覆盖前段、
  # 尾部残留旧 dtbo 数据会导致镜像损坏（如 dada 镜像 18MB < 24MB 分区即属此情况）。
  _src="$f"
  _used_pad=0
  if [ -n "$dsz" ] && [ -n "$fsz" ] && [ "$fsz" -lt "$dsz" ]; then
    _pad=/data/local/tmp/dtbo_pad.img
    if cp -f "$f" "$_pad" 2>/dev/null && truncate -s "$dsz" "$_pad" 2>/dev/null && \
       [ "$(stat -c %s "$_pad" 2>/dev/null)" = "$dsz" ]; then
      _src="$_pad"
      _used_pad=1
      echo "   镜像已补齐至分区大小 ($dsz bytes)"
    else
      # 【v2.9.4 修复 —— 变砖级】旧行为：`! 补齐失败，仍按原文件写入`
      #   后果：镜像只有 616KB 而分区 24MB，补齐失败就只覆盖前 616KB，
      #   【分区尾部残留旧版 DTBO 数据】；而随后的校验只读回前 N 字节 → 报"成功"。
      #   用户拿到的是一个头尾不一致的分区 → 不匹配的 device-tree → 可能不开机/黑砖。
      #   customize.sh 早已改成"补齐失败即中止"，但 **WebUI 一键刷入走的正是这条运行时路径**
      #   （index.html 的 flash/flashlocal → dtbo.sh），此前一直没同步修。
      #   【新行为】补齐失败 = 中止刷写，绝不写半个镜像。
      echo "   ! 补齐失败（cp/truncate 异常或尺寸复核不符）→ 为安全【中止刷写】，分区未被改动"
      rm -f "$_pad" 2>/dev/null
      return 1
    fi
  fi
  if dd if="$_src" of="$dev" bs=1M 2>/dev/null; then
    sync
    echo "-> 校验..."
    # v2.6.23：判空，避免 stat 失败时空 head -c 导致误报"校验不一致"
    # 【v2.7.10 修复 —— 这是"刷入成功却报校验失败"的真根因】
    #   旧代码在 dd 之后、校验之前就 `rm -f "$_pad"` 删掉了补齐件（原第 222 行），
    #   而后面要用 _src(=$_pad) 做两件事：
    #     ① _ssz=$(stat -c %s "$_src")   → 文件已删 → 空 → 回退成【未补齐】尺寸
    #     ② _fsha=$(hash_of "$_src")     → hash_of 对不存在的文件返回【空字符串】
    #   于是 `[ "$_nsha" = "$_fsha" ]` 里 _fsha 恒为空 → 只要镜像小于分区
    #   （本项目所有机型都是：镜像 616KB / 分区 24MB）→ 【必然 VERIFY_FAIL】。
    #   而 dd 明明写成功了（manifest 里 part= 正是镜像 sha，可自证）。
    #   旧版 v2.7.5 及以前是另一个错法（_ssz 用补齐尺寸、_fsha 用原文件哈希），
    #   v2.7.6 只改了 _fsha 的同源性，没注意文件已在前面被删 → 依然失败。
    #   【修法】把删除推迟到本函数【所有返回路径都经过】的最后（见函数末尾）。
    _ssz=$(stat -c %s "$_src" 2>/dev/null)
    case "$_ssz" in ''|*[!0-9]*) _ssz=$(stat -c %s "$f" 2>/dev/null) ;; esac
    case "$_ssz" in ''|*[!0-9]*)
      echo "   ! 无法读取镜像大小，跳过校验（写入已完成，请重启后看 diag 结论）"
      _ssz=""
      ;;
    esac
    if [ -n "$_ssz" ]; then
      _nsha=$(head -c "$_ssz" "$dev" 2>/dev/null | sha256sum | awk '{print $1}')
      # 哈希必须与 _ssz 同源：都取自 $_src（补齐后的临时件或原文件）
      _fsha=$(hash_of "$_src")
      if [ -n "$_nsha" ] && [ "$_nsha" = "$_fsha" ]; then
        echo "=================================="
        echo "刷入成功且校验一致 (重启后生效)"
        echo "sha256: $_nsha"
        echo "=================================="
        echo "$(date '+%F %T') flash_OK $s $_nsha <- $f" >> "$MANIFEST"
        [ "$_used_pad" = "1" ] && rm -f "$_pad" 2>/dev/null
      else
        echo "校验不一致! 分区=$_nsha 文件=$_fsha"
        echo "请用备份恢复或重刷"
        echo "$(date '+%F %T') flash_VERIFY_FAIL $s part=$_nsha file=$_fsha" >> "$MANIFEST"
        [ "$_used_pad" = "1" ] && rm -f "$_pad" 2>/dev/null
        return 1
      fi
    fi
    # 跳过校验的分支也要清理补齐件
    [ "$_used_pad" = "1" ] && rm -f "$_pad" 2>/dev/null
  else
    echo "dd 写入失败!"
    [ "$_used_pad" = "1" ] && rm -f "$_pad" 2>/dev/null
    return 1
  fi
}

autobackup() {
  mkdir -p "$BK" 2>/dev/null
  s=$(slot_letter)
  dev=$(slot_dev "$s")
  [ -e "$dev" ] || exit 0
  _sha=$(blk_sha "$dev")
  if [ -f "$MANIFEST" ] && grep -qF "$_sha" "$MANIFEST" 2>/dev/null; then
    exit 0
  fi
  _f="$BK/dtbo_${s}_auto_$(date +%Y%m%d-%H%M%S).img"
  if dd if="$dev" of="$_f" bs=1M 2>/dev/null; then
    sync
    echo "$(date '+%F %T') auto_backup $s $_sha $(basename "$_f")" >> "$MANIFEST"
    log "dtbo: autobackup saved $_f"
  fi
  exit 0
}

case "$1" in
  status) show_status ;;
  list) list_candidates ;;
  info) show_info "$2" ;;
  backup) do_backup "$2" ;;
  flash) do_flash "$2" "$3" ;;
  flashlocal) do_flash "$XBT/dtbo/local.img" "${2:-$(slot_letter)}" ;;
  haslocal) if [ -f "$XBT/dtbo/local.img" ]; then echo "yes"; else echo "no"; fi ;;
  autobackup) autobackup ;;
  dirs) show_dirs ;;
  dirslist) list_extra_dirs ;;
  adddir) add_scan_dir "$2" ;;
  deldir) del_scan_dir "$2" ;;
  *) echo "用法: dtbo.sh status|list|info <file>|backup [slot]|flash <file> [slot]|flashlocal [slot]|haslocal|autobackup|dirs|dirslist|adddir <目录>|deldir <目录>"; exit 9 ;;
esac