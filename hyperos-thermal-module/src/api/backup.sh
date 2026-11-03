#!/system/bin/sh
backup_collect() {
  STAGE=$WORK/archive
  mkdir -p "$STAGE" || return 1
  : > "$WORK/members"
  for rel in config/settings.json config/rearscreen.json config/bypass_manual battery/config/settings.conf ui/ui-settings.json; do
    [ -f "$MODDIR/$rel" ] || continue
    internal_path "$MODDIR/$rel" || return 1
    mkdir -p "$STAGE/${rel%/*}" || return 1
    cp "$MODDIR/$rel" "$STAGE/$rel" || return 1
    printf '%s\n' "$rel" >> "$WORK/members"
  done
  if extract content "$REQ" > "$WORK/ui" 2>/dev/null; then
    [ "$(LC_ALL=C awk -v check=type -v path=content -f "$JSON_AWK" -f "$API_DIR/validate.awk" "$REQ")" != string ] || {
      LC_ALL=C awk -v check=text -v path=content -f "$JSON_AWK" -f "$API_DIR/validate.awk" "$REQ" > "$WORK/ui" || return 1
    }
    json_check ui "$WORK/ui" > "$WORK/ui.valid" || return 1
    mkdir -p "$STAGE/ui" || return 1
    cp "$WORK/ui.valid" "$STAGE/ui/ui-settings.json" || return 1
    awk '$0!="ui/ui-settings.json"' "$WORK/members" > "$WORK/list"
    mv "$WORK/list" "$WORK/members"
    printf '%s\n' ui/ui-settings.json >> "$WORK/members"
  fi
  for p in "$MODDIR"/profiles/*.conf; do
    [ -f "$p" ] || continue
    internal_path "$p" || return 1
    bn=${p##*/}; case "$bn" in ''|.*|*..*|*[!A-Za-z0-9_\ .-]*) return 1 ;; esac
    mkdir -p "$STAGE/profiles" || return 1
    cp "$p" "$STAGE/profiles/$bn" || return 1
    printf 'profiles/%s\n' "$bn" >> "$WORK/members"
  done
  [ -s "$WORK/members" ] || return 1
}

backup_validate_files() {
  while IFS= read -r rel; do
    case "$rel" in
      config/settings.json) settings_prepare "$STAGE/$rel" "$WORK/valid" || return 1; mv "$WORK/valid" "$STAGE/$rel" || return 1 ;;
      config/rearscreen.json) json_check rear "$STAGE/$rel" > "$WORK/valid" || return 1; mv "$WORK/valid" "$STAGE/$rel" || return 1 ;;
      config/bypass_manual) LC_ALL=C awk 'NR!=1 || $0 !~ /^[01]$/ {bad=1} END{exit (bad || NR!=1)}' "$STAGE/$rel" || return 1 ;;
      ui/ui-settings.json) json_check ui "$STAGE/$rel" > "$WORK/valid" || return 1; mv "$WORK/valid" "$STAGE/$rel" || return 1 ;;
      profiles/*.conf) LC_ALL=C awk -v kind=profile -f "$API_DIR/conf_check.awk" "$STAGE/$rel" || return 1; profile_json "$STAGE/$rel" > "$WORK/profile" || return 1; json_check profile "$WORK/profile" >/dev/null || return 1 ;;
      battery/config/settings.conf) LC_ALL=C awk -v kind=battery -f "$API_DIR/conf_check.awk" "$STAGE/$rel" || return 1 ;;
      *) return 1 ;;
    esac
  done < "$WORK/members"
}

full_export() {
  need_string directory; external_path "$FIELD" || error '备份目录无效'; directory=$EXTERNAL
  mkdir -p "$directory" || error '无法创建备份目录'
  no_symlinks "$directory" || error '备份目录包含链接'
  lock_acquire || error 'API 正忙' 6
  battery_lock || error '电池配置正忙' 6
  backup_collect && backup_validate_files || error '配置校验失败，未导出'
  tar -czf "$WORK/backup.tar.gz" -C "$STAGE" -T "$WORK/members" || error '备份打包失败'
  destination=$directory/HyperOS_XJ_backup_$(date +%Y%m%d_%H%M%S)_$$.tar.gz
  atomic_file "$WORK/backup.tar.gz" "$destination" || error '备份导出失败'
  printf '{"path":'; printf '%s' "$destination" | json_quote; printf '}\n'
}

full_restore() {
  need_string path; external_path "$FIELD" || error '备份路径无效'; source_file=$EXTERNAL
  [ -f "$source_file" ] && [ ! -L "$source_file" ] || error '备份不存在'
  [ "$(wc -c < "$source_file")" -le 8388608 ] || error '备份过大'
  # Freeze the input before validation so external storage cannot swap the archive.
  cp "$source_file" "$WORK/input.tar.gz" || error '读取备份失败'
  (gzip -dc "$WORK/input.tar.gz" 2>/dev/null; printf '%s\n' "$?" > "$WORK/gzip.status") | head -c 6291457 > "$WORK/input.tar"
  [ "$(wc -c < "$WORK/input.tar")" -le 6291456 ] || error '解压后的备份过大'
  [ "$(cat "$WORK/gzip.status" 2>/dev/null)" = 0 ] || error '备份压缩流损坏'
  od -An -v -tu1 "$WORK/input.tar" > "$WORK/bytes" || error '无法检查备份'
  LC_ALL=C awk -f "$API_DIR/tar_check.awk" "$WORK/bytes" > "$WORK/members" || error '备份含未授权成员、链接或损坏的 tar 头'
  STAGE=$WORK/archive
  mkdir "$STAGE" || error '无法准备恢复目录'
  tar -xf "$WORK/input.tar" -C "$STAGE" || error '备份解包失败'
  lock_acquire || error 'API 正忙' 6
  battery_lock || error '电池配置正忙' 6
  backup_validate_files || error '备份内容校验失败，未写入配置'
  # Prepare rollback copies for every destination before committing any file.
  mkdir "$WORK/rollback" || error '无法准备回滚'
  count=0
  while IFS= read -r rel; do
    for base in "$MODDIR" "$BAK"; do
      internal_path "$base/$rel" || error '恢复目标含符号链接'
      count=$((count+1))
      if [ -f "$base/$rel" ]; then cp "$base/$rel" "$WORK/rollback/$count" || error '无法保存回滚副本'; fi
    done
  done < "$WORK/members"
  restored=1
  while IFS= read -r rel; do
    commit_config "$rel" "$STAGE/$rel" && cmp -s "$STAGE/$rel" "$MODDIR/$rel" && cmp -s "$STAGE/$rel" "$BAK/$rel" || { restored=0; break; }
  done < "$WORK/members"
  if [ "$restored" = 0 ]; then
    count=0
    while IFS= read -r rel; do
      for base in "$MODDIR" "$BAK"; do
        count=$((count+1))
        if [ -f "$WORK/rollback/$count" ]; then atomic_file "$WORK/rollback/$count" "$base/$rel" || printf '回滚失败: %s\n' "$rel" >&2
        else rm -f "$base/$rel"; fi
      done
    done < "$WORK/members"
    error '恢复提交失败，已尝试回滚'
  fi
  printf '{"restored":true,"ui":'
  if [ -f "$STAGE/ui/ui-settings.json" ]; then cat "$STAGE/ui/ui-settings.json"; else printf null; fi
  printf '}\n'
}
