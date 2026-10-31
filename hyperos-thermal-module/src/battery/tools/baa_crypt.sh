#!/system/bin/sh
# baa_crypt.sh — BAA 加解密工具（手机端版，依赖 openssl + base64 + od）
# 用法同 tools/baa_crypt.py（decrypt / encrypt / selfcheck；gen 请用电脑版 python）
# 密钥/格式见 docs/BAA加解密方案.md

KEY_HEX="6d696368617267657262617474657279"   # michargerbattery (hex)
MAGIC="BAA_ENC:"

usage() {
  echo "用法:"
  echo "  baa_crypt.sh decrypt <BAA_ENC文件> [-o 输出.json]   # 解密 → 明文"
  echo "  baa_crypt.sh encrypt <明文JSON>  [-o 输出文件]     # 明文 → BAA_ENC"
  echo "  baa_crypt.sh selfcheck                             # 自检"
  echo "  (gen/genenc 生成解容载荷请用电脑版: python3 tools/baa_crypt.py)"
  exit 9
}

have_openssl() {
  command -v openssl >/dev/null 2>&1 && return 0
  for _o in /system/bin/openssl /system/xbin/openssl /data/adb/magisk/openssl /data/adb/ksu/bin/openssl /data/adb/twrp/openssl; do
    [ -x "$_o" ] && { export PATH="$(dirname "$_o"):$PATH"; return 0; }
  done
  return 1
}

hex() { od -An -v -tx1 "$1" 2>/dev/null | tr -d ' \n'; }

to_hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }

CMD="$1"
INF=""; OUT=""
shift 2>/dev/null || true
[ -n "$1" ] && { INF="$1"; shift 2>/dev/null || true; }
while [ -n "$1" ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 2>/dev/null || true ;;
    *)  shift 2>/dev/null || true ;;
  esac
done

case "$CMD" in
  selfcheck)
    have_openssl || { echo "缺少 openssl，无法自检"; exit 1; }
    TMP=$(mktemp -d)
    echo '{"strategy":{"smart_fv":{"decrease_mv_max":80}}}' > "$TMP/p.json"
    dd if=/dev/urandom of="$TMP/iv.bin" bs=16 count=1 2>/dev/null
    openssl enc -e -aes-128-cbc -nosalt -K "$KEY_HEX" -iv "$(hex "$TMP/iv.bin")" -in "$TMP/p.json" -out "$TMP/c.bin" 2>/dev/null
    cat "$TMP/iv.bin" "$TMP/c.bin" > "$TMP/full.bin"
    { printf '%s' "$MAGIC"; base64 -w0 "$TMP/full.bin"; } > "$TMP/enc.bin"
    # 回解（纯文件管道，避免二进制进变量）
    tail -c +9 "$TMP/enc.bin" | base64 -d > "$TMP/body.bin"
    dd bs=1 count=16 if="$TMP/body.bin" of="$TMP/iv.bin" 2>/dev/null
    dd bs=1 skip=16 if="$TMP/body.bin" of="$TMP/ct.bin" 2>/dev/null
    openssl enc -d -aes-128-cbc -nopad -nosalt -K "$KEY_HEX" -iv "$(hex "$TMP/iv.bin")" -in "$TMP/ct.bin" -out "$TMP/p2.bin" 2>/dev/null
    # PKCS7 unpad
    LAST=$(tail -c 1 "$TMP/p2.bin" | od -An -tu1 | tr -d ' ')
    SZ=$(wc -c < "$TMP/p2.bin")
    head -c $((SZ-LAST)) "$TMP/p2.bin" > "$TMP/p3.bin"
    if cmp -s "$TMP/p.json" "$TMP/p3.bin"; then
      echo "selfcheck OK：encrypt↔decrypt roundtrip 一致"
      rm -rf "$TMP"
      exit 0
    else
      echo "selfcheck FAILED"; rm -rf "$TMP"; exit 1
    fi
    ;;
  decrypt)
    [ -f "$INF" ] || { echo "文件不存在: $INF"; exit 1; }
    have_openssl || { echo "缺少 openssl（本机可能无）；请用电脑版: python3 tools/baa_crypt.py decrypt $INF"; exit 1; }
    HEAD=$(head -c 8 "$INF")
    [ "$HEAD" = "$MAGIC" ] || { echo "[decrypt] $INF 不是 BAA_ENC（已是明文）→ 原样输出"; OUT=${OUT:-"$INF.plain.json"}; cp "$INF" "$OUT"; echo "→ $OUT"; exit 0; }
    TMP=$(mktemp -d)
    tail -c +9 "$INF" | base64 -d > "$TMP/body.bin"
    dd bs=1 count=16 if="$TMP/body.bin" of="$TMP/iv.bin" 2>/dev/null
    dd bs=1 skip=16 if="$TMP/body.bin" of="$TMP/ct.bin" 2>/dev/null
    openssl enc -d -aes-128-cbc -nopad -nosalt -K "$KEY_HEX" -iv "$(hex "$TMP/iv.bin")" -in "$TMP/ct.bin" -out "$TMP/pt.bin" 2>/dev/null
    LAST=$(tail -c 1 "$TMP/pt.bin" | od -An -tu1)
    SZ=$(wc -c < "$TMP/pt.bin")
    head -c $((SZ-LAST)) "$TMP/pt.bin" > "${OUT:-/dev/stdout}"
    echo "[decrypt] OK（明文 $(wc -c < "$TMP/pt.bin") 字节）" >&2
    rm -rf "$TMP"
    ;;
  encrypt)
    [ -f "$INF" ] || { echo "文件不存在: $INF"; exit 1; }
    have_openssl || { echo "缺少 openssl；请用电脑版: python3 tools/baa_crypt.py encrypt $INF"; exit 1; }
    OUT=${OUT:-"$INF.enc"}
    TMP=$(mktemp -d)
    dd if=/dev/urandom of="$TMP/iv.bin" bs=16 count=1 2>/dev/null
    openssl enc -e -aes-128-cbc -nosalt -K "$KEY_HEX" -iv "$(hex "$TMP/iv.bin")" -in "$INF" -out "$TMP/c.bin" 2>/dev/null
    cat "$TMP/iv.bin" "$TMP/c.bin" > "$TMP/full.bin"
    { printf '%s' "$MAGIC"; base64 -w0 "$TMP/full.bin"; } > "$OUT"
    echo "[encrypt] $INF → $OUT（$(wc -c < "$OUT") 字节）"
    rm -rf "$TMP"
    ;;
  *) usage ;;
esac
