#!/system/bin/sh
# baa_crypt_awk.sh v3.00.41 — BAA 加解密（手机端纯内置实现，零外部依赖）
# 适用: ROM 无 openssl / 无 python 的设备（小米 HyperOS 常见）
# 依赖: toybox/base64(编码解码) + od + awk（Android 全部自带）
# 用法与 baa_crypt.sh 相同: decrypt|encrypt|selfcheck
# 算法: AES-128-CBC + PKCS7，密钥 michargerbattery，格式 BAA_ENC:base64(iv(16B)||密文)
# 说明: 纯 awk 实现（位运算用查表），48KB 载荷 PC 约 10~40 秒、手机 toybox awk
#        约 30 秒~2 分钟（一次性操作，volt_guard 已幂等，不会重复执行）
# v3.00.41: 修复 6 处（split 字符串转数值 / ShiftRows 列主序 / MixColumns s1 / mul14 /
#           IV||密文统一 b64 编码 / b64pad1 单字节填充），已通过 FIPS-197 向量 +
#           openssl 双向互操作 + 48578B 全量载荷 + 无 openssl 端到端验证

KEY_HEX="6d696368617267657262617474657279"
MAGIC="BAA_ENC:"

usage() {
  echo "用法:"
  echo "  baa_crypt_awk.sh decrypt <BAA_ENC文件> [-o 输出.json]"
  echo "  baa_crypt_awk.sh encrypt <明文JSON>  [-o 输出文件]"
  echo "  baa_crypt_awk.sh selfcheck"
  exit 9
}

CMD="$1"; INF=""; OUT=""
shift 2>/dev/null || true
[ -n "$1" ] && { INF="$1"; shift 2>/dev/null || true; }
while [ -n "$1" ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 2>/dev/null || true ;;
    *)  shift 2 2>/dev/null || true ;;
  esac
done

# 核心 awk 程序：读 hex 文本流（od 输出），MODE=decrypt/encrypt
# 输入: 每行若干 2 位小写 hex（od -An -v -tx1 输出）
# 输出: base64 文本（decrypt=明文；encrypt=IV||密文）
AES_AWK=$(cat <<'AWKEOF'
function b64chr(a,b,c,    n){
  n=a*65536+b*256+c
  s=substr(B64,int(n/262144)+1,1) substr(B64,int(n/4096)%64+1,1) substr(B64,int(n/64)%64+1,1) substr(B64,n%64+1,1)
  return s
}
function b64pad1(a,    n){
  n=a*65536
  s=substr(B64,int(n/262144)+1,1) substr(B64,int(n/4096)%64+1,1)
  return s "=="
}
function b64pad2(a,b,    n){
  n=a*65536+b*256
  s=substr(B64,int(n/262144)+1,1) substr(B64,int(n/4096)%64+1,1) substr(B64,int(n/64)%64+1,1)
  return s "="
}
function xr(a,b){ return x8[a*256+b] }
function xt(x,    t){
  t=(x*2)%256
  if(x>=128) t=xr(t,27)
  return t
}
function sb(x){ return sbox[x+1] }
function rsb(x){ return rsbox[x+1] }
function mul9(x){ return xr(xt(xt(xt(x))),x) }
function mul11(x){ return xr(xt(xt(xt(x))),xr(xt(x),x)) }
function mul13(x){ return xr(xt(xt(xt(x))),xr(xt(xt(x)),x)) }
function mul14(x){ return xr(xr(xt(xt(xt(x))),xt(xt(x))),xt(x)) }
function addrk(st, r,    i){
  for(i=1;i<=16;i++) st[i]=xr(st[i],rk[r,i])
}
function inv_shift_rows(st,    t0,t1,t2,t3){
  # 行1 右移1（列主序 st[col*4+row+1]：行1=st[2],st[6],st[10],st[14]）
  t0=st[2]; t1=st[6]; t2=st[10]; t3=st[14]
  st[2]=t3; st[6]=t0; st[10]=t1; st[14]=t2
  # 行2 右移2（行2=st[3],st[7],st[11],st[15]）
  t0=st[3]; t1=st[7]; t2=st[11]; t3=st[15]
  st[3]=t2; st[7]=t3; st[11]=t0; st[15]=t1
  # 行3 右移3（行3=st[4],st[8],st[12],st[16]）
  t0=st[4]; t1=st[8]; t2=st[12]; t3=st[16]
  st[4]=t1; st[8]=t2; st[12]=t3; st[16]=t0
}
function shift_rows(st,    t0,t1,t2,t3){
  # 行1 左移1
  t0=st[2]; t1=st[6]; t2=st[10]; t3=st[14]
  st[2]=t1; st[6]=t2; st[10]=t3; st[14]=t0
  # 行2 左移2
  t0=st[3]; t1=st[7]; t2=st[11]; t3=st[15]
  st[3]=t2; st[7]=t3; st[11]=t0; st[15]=t1
  # 行3 左移3
  t0=st[4]; t1=st[8]; t2=st[12]; t3=st[16]
  st[4]=t3; st[8]=t0; st[12]=t1; st[16]=t2
}
function mix_cols(st,    c,b0,b1,b2,b3){
  for(c=0;c<4;c++){
    b0=st[c*4+1]; b1=st[c*4+2]; b2=st[c*4+3]; b3=st[c*4+4]
    st[c*4+1]=xr(xr(xt(b0),xr(xt(b1),b1)),xr(b2,b3))
    st[c*4+2]=xr(xr(xr(b0,xt(b1)),xr(xt(b2),b2)),b3)
    st[c*4+3]=xr(xr(xr(b0,b1),xt(b2)),xr(xt(b3),b3))
    st[c*4+4]=xr(xr(xr(xt(b0),b0),b1),xr(b2,xt(b3)))
  }
}
function inv_mix_cols(st,    c,b0,b1,b2,b3){
  for(c=0;c<4;c++){
    b0=st[c*4+1]; b1=st[c*4+2]; b2=st[c*4+3]; b3=st[c*4+4]
    st[c*4+1]=xr(xr(xr(mul14(b0),mul11(b1)),mul13(b2)),mul9(b3))
    st[c*4+2]=xr(xr(xr(mul9(b0),mul14(b1)),mul11(b2)),mul13(b3))
    st[c*4+3]=xr(xr(xr(mul13(b0),mul9(b1)),mul14(b2)),mul11(b3))
    st[c*4+4]=xr(xr(xr(mul11(b0),mul13(b1)),mul9(b2)),mul14(b3))
  }
}
function aes_dec_block(st,    r,i){
  addrk(st,10)
  for(r=9;r>=1;r--){
    inv_shift_rows(st)
    for(i=1;i<=16;i++) st[i]=rsb(st[i])
    addrk(st,r)
    inv_mix_cols(st)
  }
  inv_shift_rows(st)
  for(i=1;i<=16;i++) st[i]=rsb(st[i])
  addrk(st,0)
}
function aes_enc_block(st,    r,i){
  addrk(st,0)
  for(r=1;r<=9;r++){
    for(i=1;i<=16;i++) st[i]=sb(st[i])
    shift_rows(st)
    mix_cols(st)
    addrk(st,r)
  }
  for(i=1;i<=16;i++) st[i]=sb(st[i])
  shift_rows(st)
  addrk(st,10)
}
function hexch(v,    h){
  h="0123456789abcdef"
  return substr(h, int(v/16)+1, 1) substr(h, v%16+1, 1)
}
function hex2num(c){
  return index("0123456789abcdef", c)-1
}
BEGIN{
  split("63 7c 77 7b f2 6b 6f c5 30 01 67 2b fe d7 ab 76 ca 82 c9 7d fa 59 47 f0 ad d4 a2 af 9c a4 72 c0 b7 fd 93 26 36 3f f7 cc 34 a5 e5 f1 71 d8 31 15 04 c7 23 c3 18 96 05 9a 07 12 80 e2 eb 27 b2 75 09 83 2c 1a 1b 6e 5a a0 52 3b d6 b3 29 e3 2f 84 53 d1 00 ed 20 fc b1 5b 6a cb be 39 4a 4c 58 cf d0 ef aa fb 43 4d 33 85 45 f9 02 7f 50 3c 9f a8 51 a3 40 8f 92 9d 38 f5 bc b6 da 21 10 ff f3 d2 cd 0c 13 ec 5f 97 44 17 c4 a7 7e 3d 64 5d 19 73 60 81 4f dc 22 2a 90 88 46 ee b8 14 de 5e 0b db e0 32 3a 0a 49 06 24 5c c2 d3 ac 62 91 95 e4 79 e7 c8 37 6d 8d d5 4e a9 6c 56 f4 ea 65 7a ae 08 ba 78 25 2e 1c a6 b4 c6 e8 dd 74 1f 4b bd 8b 8a 70 3e b5 66 48 03 f6 0e 61 35 57 b9 86 c1 1d 9e e1 f8 98 11 69 d9 8e 94 9b 1e 87 e9 ce 55 28 df 8c a1 89 0d bf e6 42 68 41 99 2d 0f b0 54 bb 16", sbox, " ")
  split("52 09 6a d5 30 36 a5 38 bf 40 a3 9e 81 f3 d7 fb 7c e3 39 82 9b 2f ff 87 34 8e 43 44 c4 de e9 cb 54 7b 94 32 a6 c2 23 3d ee 4c 95 0b 42 fa c3 4e 08 2e a1 66 28 d9 24 b2 76 5b a2 49 6d 8b d1 25 72 f8 f6 64 86 68 98 16 d4 a4 5c cc 5d 65 b6 92 6c 70 48 50 fd ed b9 da 5e 15 46 57 a7 8d 9d 84 90 d8 ab 00 8c bc d3 0a f7 e4 58 05 b8 b3 45 06 d0 2c 1e 8f ca 3f 0f 02 c1 af bd 03 01 13 8a 6b 3a 91 11 41 4f 67 dc ea 97 f2 cf ce f0 b4 e6 73 96 ac 74 22 e7 ad 35 85 e2 f9 37 e8 1c 75 df 6e 47 f1 1a 71 1d 29 c5 89 6f b7 62 0e aa 18 be 1b fc 56 3e 4b c6 d2 79 20 9a db c0 fe 78 cd 5a f4 1f dd a8 33 88 07 c7 31 b1 12 10 59 27 80 ec 5f 60 51 7f a9 19 b5 4a 0d 2d e5 7a 9f 93 c9 9c ef a0 e0 3b 4d ae 2a f5 b0 c8 eb bb 3c 83 53 99 61 17 2b 04 7e ba 77 d6 26 e1 69 14 63 55 21 0c 7d", rsbox, " ")
  split("0 1 2 3 1 0 3 2 2 3 0 1 3 2 1 0", x2, " ")
  # v3.00.41 关键修复：split 元素是字符串（如 "4d"），awk 算术只取前导数字
  #   （"4d"→4）导致整个 S-Box/逆S-Box 查表错乱 → 必须转十进制数值
  for(i=1;i<=256;i++){ sbox[i]=hex2num(substr(sbox[i],1,1))*16+hex2num(substr(sbox[i],2,1)); rsbox[i]=hex2num(substr(rsbox[i],1,1))*16+hex2num(substr(rsbox[i],2,1)) }
  B64="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  # 预计算 256x256 XOR 查表（awk 无位运算，查表实现）
  for(i=0;i<256;i++){
    ah=int(i/16); al=i%16; ah1=int(ah/4); al1=ah%4
    for(j=0;j<256;j++){
      bh=int(j/16); bl=j%16; bh1=int(bh/4); bl1=bh%4
      vh=(x2[ah1*4+bh1+1]*4 + x2[al1*4+bl1+1])*16
      vl=x2[int(al/4)*4+int(bl/4)+1]*4 + x2[al%4*4+bl%4+1]
      x8[i*256+j]=vh+vl
    }
  }
  # 密钥
  kh="6d696368617267657262617474657279"
  for(i=0;i<16;i++) key[i+1]=hex2num(substr(kh, i*2+1, 1))*16+hex2num(substr(kh, i*2+2, 1))
  # 密钥扩展（w 为 44 个字，每字 4 字节）
  for(i=0;i<16;i++) w[i]=key[i+1]
  for(i=4;i<=43;i++){
    t0=w[(i-1)*4]; t1=w[(i-1)*4+1]; t2=w[(i-1)*4+2]; t3=w[(i-1)*4+3]
    if(i%4==0){
      tp=t0; t0=t1; t1=t2; t2=t3; t3=tp
      t0=sb(t0); t1=sb(t1); t2=sb(t2); t3=sb(t3)
      rcw=1; k=1
      while(k< i/4){ rcw=xt(rcw); k++ }
      t0=xr(t0,rcw)
    }
    w[i*4]=xr(w[(i-4)*4],t0); w[i*4+1]=xr(w[(i-4)*4+1],t1)
    w[i*4+2]=xr(w[(i-4)*4+2],t2); w[i*4+3]=xr(w[(i-4)*4+3],t3)
  }
  for(r=0;r<=10;r++) for(c=0;c<4;c++){
    rk[r,c*4+1]=w[(r*4+c)*4]; rk[r,c*4+2]=w[(r*4+c)*4+1]
    rk[r,c*4+3]=w[(r*4+c)*4+2]; rk[r,c*4+4]=w[(r*4+c)*4+3]
  }
  # 读 hex 流
  h=""
  while((getline line) > 0){
    gsub(/[^0-9a-f]/,"",line)
    h=h line
  }
  n=length(h)/2
  for(i=1;i<=n;i++) B[i]=hex2num(substr(h,(i-1)*2+1,1))*16+hex2num(substr(h,(i-1)*2+2,1))
  if(MODE=="decrypt"){
    nblk=int(n/16)-1
    out=""
    for(b=0;b<nblk;b++){
      for(i=1;i<=16;i++) st[i]=B[b*16+i+16]
      aes_dec_block(st)
      if(b==0){ for(i=1;i<=16;i++) st[i]=xr(st[i],B[i]) }
      else { for(i=1;i<=16;i++) st[i]=xr(st[i],B[b*16+i]) }
      for(i=1;i<=16;i++) out=out hexch(st[i])
    }
    n2=length(out)/2
    pad=hex2num(substr(out,n2*2-1,1))*16+hex2num(substr(out,n2*2,1))
    n2=n2-pad
    out=substr(out,1,n2*2)
    b64=""; cnt=0
    for(i=1;i<=n2;i++){
      v1=hex2num(substr(out,(i-1)*2+1,1))*16+hex2num(substr(out,(i-1)*2+2,1))
      cache[cnt]=v1; cnt++
      if(cnt==3){ b64=b64 b64chr(cache[0],cache[1],cache[2]); cnt=0 }
    }
    if(cnt==1){ b64=b64 b64pad1(cache[0]) }
    else if(cnt==2){ b64=b64 b64pad2(cache[0],cache[1]) }
    printf "%s", b64
  } else {
    rem=n%16; pad=16-rem
    out=""
    for(i=1;i<=n;i++) out=out hexch(B[i])
    for(i=1;i<=pad;i++) out=out hexch(pad)
    n2=length(out)/2
    ivh=IVHEX
    for(i=1;i<=16;i++) cprev[i]=hex2num(substr(ivh,(i-1)*2+1,1))*16+hex2num(substr(ivh,(i-1)*2+2,1))
    for(b=0;b<n2/16;b++){
      for(i=1;i<=16;i++) st[i]=hex2num(substr(out,(b*16+i-1)*2+1,1))*16+hex2num(substr(out,(b*16+i-1)*2+2,1))
      for(i=1;i<=16;i++) st[i]=xr(st[i],cprev[i])
      aes_enc_block(st)
      for(i=1;i<=16;i++){ cprev[i]=st[i]; ctxt[b*16+i]=st[i] }
    }
    # 统一字节数组编码（IV||密文 连续字节流，避免分段编码字节错乱）
    b64=""; cnt=0
    ntot=16+n2
    for(i=1;i<=ntot;i++){
      if(i<=16){ v1=hex2num(substr(ivh,(i-1)*2+1,1))*16+hex2num(substr(ivh,(i-1)*2+2,1)) }
      else { b1=int((i-16-1)/16); b2=(i-16-1)%16+1; v1=ctxt[b1*16+b2] }
      cache[cnt]=v1; cnt++
      if(cnt==3){ b64=b64 b64chr(cache[0],cache[1],cache[2]); cnt=0 }
    }
    if(cnt==1){ b64=b64 b64pad1(cache[0]) }
    else if(cnt==2){ b64=b64 b64pad2(cache[0],cache[1]) }
    printf "%s", b64
  }
}
AWKEOF
)

run_awk() {
  awk -v MODE="$1" -v IVHEX="$2" "$AES_AWK"
}

case "$CMD" in
  decrypt)
    [ -n "$OUT" ] || { echo "缺少 -o 输出路径"; usage; }
    [ -f "$INF" ] || { echo "输入文件不存在: $INF"; exit 1; }
    sed 's/^BAA_ENC://' "$INF" | tr -d '\n' | base64 -d 2>/dev/null | od -An -v -tx1 | run_awk decrypt "" | base64 -d > "$OUT" 2>/dev/null
    [ -s "$OUT" ] && { echo "OK: $OUT"; exit 0; }
    echo "解密失败（检查文件是否为 BAA_ENC 格式）"; exit 1
    ;;
  encrypt)
    [ -n "$OUT" ] || { echo "缺少 -o 输出路径"; usage; }
    [ -f "$INF" ] || { echo "输入文件不存在: $INF"; exit 1; }
    IVH=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    case "$IVH" in ''|*[!0-9a-f]*) IVH="00112233445566778899aabbccddeeff" ;; esac
    od -An -v -tx1 "$INF" | run_awk encrypt "$IVH" | sed 's/^/BAA_ENC:/' > "$OUT" 2>/dev/null
    [ -s "$OUT" ] && { echo "OK: $OUT"; exit 0; }
    echo "加密失败"; exit 1
    ;;
  selfcheck)
    TMP=$(mktemp -d 2>/dev/null || echo /data/local/tmp)
    echo '{"strategy":{"smart_fv":{"decrease_mv_max":80}}}' > "$TMP/p.json"
    sh "$0" encrypt "$TMP/p.json" -o "$TMP/p.enc" >/dev/null 2>&1 || { echo "encrypt 失败"; exit 1; }
    sh "$0" decrypt "$TMP/p.enc" -o "$TMP/p2.json" >/dev/null 2>&1 || { echo "decrypt 失败"; exit 1; }
    if cmp -s "$TMP/p.json" "$TMP/p2.json"; then
      echo "selfcheck OK（encrypt↔decrypt roundtrip 一致）"
      rm -rf "$TMP"; exit 0
    fi
    echo "selfcheck FAILED"; rm -rf "$TMP"; exit 1
    ;;
  *) usage ;;
esac
