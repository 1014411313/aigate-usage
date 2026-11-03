#!/usr/bin/env bash
# 构建 GitHub 加速 APK。依赖 ANDROID_TOOLS 目录下的 build-tools、platform(android.jar) 与 ecj.jar。
set -euo pipefail
cd "$(dirname "$0")"

TOOLS="${ANDROID_TOOLS:-$HOME/android-toolchain}"
BT="$TOOLS/build-tools"
ANDROID_JAR="${ANDROID_JAR:-$(find "$TOOLS/platform" -maxdepth 2 -name android.jar | head -1)}"
# 本机是 arm64，Google 的 build-tools 只有 x86_64 二进制，
# 因此 aapt2/zipalign 改用 Debian (arm64) 版，只解包不安装；d8 与 apksigner 是 Java 脚本，架构无关。
DEBROOT="$TOOLS/debs/ext"
AAPT2="$DEBROOT/usr/bin/aapt2"
ZIPALIGN="$DEBROOT/usr/bin/zipalign"
export LD_LIBRARY_PATH="$DEBROOT/usr/lib/aarch64-linux-gnu:$DEBROOT/usr/lib/aarch64-linux-gnu/android:$DEBROOT/usr/lib:$DEBROOT/usr/lib/7zip${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
ECJ="$TOOLS/ecj.jar"
KEYSTORE="${KEYSTORE:-$TOOLS/githubhosts.keystore}"
STOREPASS="android"
ALIAS="githubhosts"

APP="$PWD/app"
OUT="$PWD/build"
APK_NAME="github-hosts.apk"

for f in "$AAPT2" "$BT/d8" "$ZIPALIGN" "$BT/apksigner" "$ANDROID_JAR" "$ECJ"; do
  [ -e "$f" ] || { echo "缺少 $f" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/tools" "$OUT/dex"

echo "[1/6] 生成图标"
java -jar "$ECJ" -source 11 -target 11 -nowarn -d "$OUT/tools" tools/MakeIcon.java
java -Djava.awt.headless=true -cp "$OUT/tools" MakeIcon "$APP/res"

echo "[2/6] 编译资源"
"$AAPT2" compile --dir "$APP/res" -o "$OUT/res.zip"
"$AAPT2" link -o "$OUT/base.apk" -I "$ANDROID_JAR" \
  --manifest "$APP/AndroidManifest.xml" -A "$APP/assets" "$OUT/res.zip"

echo "[3/6] 编译 Java"
# 用 -bootclasspath 走非模块模式，否则 android.jar 里的 java.* 与 JDK 的 java.base 冲突
SOURCES=("$APP"/src/site/chudian/githubhosts/*.java)
java -jar "$ECJ" -bootclasspath "$ANDROID_JAR" -source 8 -target 8 -nowarn \
  -d "$OUT/classes" "${SOURCES[@]}"

echo "[4/6] 生成 dex"
python3 - "$OUT/classes" "$OUT/classes.jar" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1:3]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PY
"$BT/d8" --lib "$ANDROID_JAR" --min-api 24 --output "$OUT/dex" "$OUT/classes.jar"

echo "[5/6] 打包并添加 dex"
python3 - "$OUT/base.apk" "$OUT/dex/classes.dex" "$OUT/unsigned.apk" <<'PY'
import sys, zipfile
src, dex, dst = sys.argv[1:4]
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        zout.writestr(item, zin.read(item.filename))
    zout.write(dex, "classes.dex")
PY
"$ZIPALIGN" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "[6/6] 签名"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -storepass "$STOREPASS" \
    -keyalg RSA -keysize 2048 -validity 10000 -alias "$ALIAS" \
    -dname "CN=GitHub Hosts, O=AiCode, C=CN"
fi
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass "pass:$STOREPASS" --ks-key-alias "$ALIAS" \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT/$APK_NAME" "$OUT/aligned.apk"

"$BT/apksigner" verify --print-certs "$OUT/$APK_NAME" | head -4
"$AAPT2" dump badging "$OUT/$APK_NAME" | grep -E "^(package|application-label|sdkVersion|targetSdkVersion|launchable-activity)"
echo "APK: $OUT/$APK_NAME ($(du -h "$OUT/$APK_NAME" | cut -f1))"
