#!/usr/bin/env python3
"""用 ECJ 构建统一控制端；--check 只编译 Java，签名 APK 输出到 build/。"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT.parent / 'app' / 'src' / 'main'
TOOL = Path('/root/android-toolchain')
AAPT2 = TOOL / 'debs/ext/usr/bin/aapt2'
ZIPALIGN = TOOL / 'debs/ext/usr/bin/zipalign'
D8 = TOOL / 'build-tools/d8'
ECJ = TOOL / 'ecj.jar'
ANDROID_JAR = TOOL / 'platform/android-34-ext12/android.jar'
XPOSED_JAR = ROOT.parent / 'app' / 'libs' / 'xposed-api-82.jar'
APKSIGNER = TOOL / 'build-tools/lib/apksigner.jar'
KEYSTORE = TOOL / 'hyperos-xj.keystore'
KS_ALIAS = 'hyperosxj'
OUT = ROOT / 'build' / 'HyperOSxj.apk'
PACKAGE = 'com.hyperos.xj'
VERSION_CODE = '2001'
VERSION_NAME = '2.1.0-unified'
MIN_API = '26'
ANDROID_NS = '{http://schemas.android.com/apk/res/android}'


def tool_env():
    env = dict(os.environ)
    paths = [str(TOOL / 'debs/ext/usr/lib/aarch64-linux-gnu/android'),
             str(TOOL / 'debs/ext/usr/lib'), str(TOOL / 'debs/ext/usr/lib/7zip')]
    if env.get('LD_LIBRARY_PATH'):
        paths.append(env['LD_LIBRARY_PATH'])
    env['LD_LIBRARY_PATH'] = ':'.join(paths)
    return env


def signing_env():
    env = tool_env()
    env['HYPEROS_KEYSTORE_PASSWORD'] = os.environ.get('HYPEROS_KEYSTORE_PASSWORD', 'android')
    return env


def java_tools():
    java = shutil.which('java')
    if not java:
        raise RuntimeError('缺少 Java 运行时')
    java = Path(java).resolve()
    jdk = java.parent.parent
    if not (jdk / 'lib' / 'modules').is_file():
        raise RuntimeError('Java 必须来自带 lib/modules 的真实 JDK: %s' % jdk)
    return java, jdk


def require_files(paths):
    for path in paths:
        if not path.is_file():
            raise RuntimeError('缺少文件: %s' % path)


def run(cmd, *, env=None, capture=False):
    cmd = [str(arg) for arg in cmd]
    result = subprocess.run(cmd, env=env if env is not None else tool_env(),
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        # 签名命令只传环境变量名；失败也不打印命令或环境。
        if capture and result.stderr:
            detail = result.stderr.decode('utf-8', errors='replace').strip()
            secret = (env or {}).get('HYPEROS_KEYSTORE_PASSWORD')
            if secret:
                detail = detail.replace(secret, '***')
            raise RuntimeError('工具执行失败 (%s): %s' % (Path(cmd[0]).name, detail))
        raise RuntimeError('工具执行失败 (%s)，退出码 %s' % (Path(cmd[0]).name, result.returncode))
    return result.stdout if capture else None


def control_html():
    from pack import stamp_build_date

    page = stamp_build_date((ROOT / 'src' / 'hyperosui' / 'index.html').read_bytes())
    page = re.sub(br'<link[^>]+href="https://mui[.]kernelsu[.]org/internal/insets[.]css"[^>]*>', b'', page)
    policy = b'<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'self\' \'unsafe-inline\'; style-src \'self\' \'unsafe-inline\'; img-src \'self\' data: blob:; font-src \'self\' data:; frame-src \'self\'; connect-src \'none\'; media-src \'self\' data: blob:; object-src \'none\'; base-uri \'none\'">'
    page = page.replace(b'<head>', b'<head>\n' + policy, 1)
    match = re.search(br'<script\b', page, re.IGNORECASE)
    if not match:
        raise RuntimeError('完整控制页缺少 script，无法注入 bridge.js')
    return page[:match.start()] + b'<script src="bridge.js"></script>\n' + page[match.start():]


def stage_assets(destination):
    for source in sorted((APP / 'assets').iterdir()):
        if source.name == 'control':
            continue
        target = destination / source.name
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)
    control = destination / 'control'
    shutil.copytree(ROOT / 'src' / 'hyperosui', control,
                    ignore=shutil.ignore_patterns('*.bak*', '*-bak', '*.orig'))
    bridge = APP / 'assets' / 'control' / 'bridge.js'
    require_files([bridge])
    shutil.copy2(bridge, control / 'bridge.js')
    (control / 'index.html').write_bytes(control_html())


def compile_java(work):
    java, jdk = java_tools()
    require_files([ECJ, ANDROID_JAR, XPOSED_JAR])
    sources = sorted((APP / 'java').rglob('*.java'))
    if not sources:
        raise RuntimeError('没有 Java 源码: %s' % (APP / 'java'))
    classes = work / 'classes'
    classes.mkdir()
    run([java, '-jar', ECJ, '-source', '8', '-target', '8', '-nowarn',
         '--system', jdk, '-classpath', os.pathsep.join(map(str, [ANDROID_JAR, XPOSED_JAR])),
         '-encoding', 'UTF-8', '-d', classes] + sources)
    print('ECJ 编译通过: %d 个 Java 源文件' % len(sources))
    return classes


def verify_apk(apk):
    java, jdk = java_tools()
    require_files([apk, AAPT2, APKSIGNER, KEYSTORE, jdk / 'bin' / 'keytool'])
    badging = run([AAPT2, 'dump', 'badging', apk], capture=True).decode('utf-8')
    match = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'",
                      badging, re.MULTILINE)
    if not match or match.groups() != (PACKAGE, VERSION_CODE, VERSION_NAME):
        raise RuntimeError('APK 包名/版本不符，需要 %s %s (%s)' % (PACKAGE, VERSION_NAME, VERSION_CODE))
    certs = run([java, '-jar', APKSIGNER, 'verify', '--print-certs', apk], capture=True).decode('utf-8')
    digests = re.findall(r'^(?:Signer #\d+|V[0-9.]+ Signer):? certificate SHA-256 digest: ([0-9a-fA-F]+)$', certs, re.MULTILINE)
    certificate = run([jdk / 'bin' / 'keytool', '-exportcert', '-keystore', KEYSTORE,
                       '-alias', KS_ALIAS, '-storepass:env', 'HYPEROS_KEYSTORE_PASSWORD'],
                      env=signing_env(), capture=True)
    if [digest.lower() for digest in digests] != [hashlib.sha256(certificate).hexdigest()]:
        raise RuntimeError('APK 签名与 hyperos-xj.keystore / hyperosxj 不符')
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError('APK 存在重复 ZIP 条目')
        if archive.read('assets/control/index.html') != control_html():
            raise RuntimeError('APK 控制页与当前完整 hyperosui 源码不符，请重新构建')
        if archive.read('assets/control/bridge.js') != (APP / 'assets/control/bridge.js').read_bytes():
            raise RuntimeError('APK bridge.js 与当前源码不符，请重新构建')
        if archive.read('assets/xposed_init').strip() != b'com.hyperos.xj.hook.HookEntry':
            raise RuntimeError('APK Xposed 入口不符')
        if 'classes.dex' not in names or any(name.startswith('de/robv/android/xposed/') or
                                            name.endswith('.jar') for name in names):
            raise RuntimeError('APK dex 缺失或意外打入编译依赖')
    return apk.read_bytes()


def build(work, classes):
    require_files([AAPT2, ZIPALIGN, D8, APKSIGNER, KEYSTORE])
    manifest = ET.parse(APP / 'AndroidManifest.xml').getroot()
    if (manifest.get('package'), manifest.get(ANDROID_NS + 'versionCode'),
            manifest.get(ANDROID_NS + 'versionName')) != (PACKAGE, VERSION_CODE, VERSION_NAME):
        raise RuntimeError('AndroidManifest.xml 包名/版本不符')
    assets = work / 'assets'
    assets.mkdir()
    stage_assets(assets)
    res_zip = work / 'res.zip'
    run([AAPT2, 'compile', '--dir', APP / 'res', '-o', res_zip])
    base = work / 'base.apk'
    run([AAPT2, 'link', '-o', base, '-I', ANDROID_JAR,
         '--manifest', APP / 'AndroidManifest.xml',
         '--min-sdk-version', MIN_API, '--target-sdk-version', '34',
         '--version-code', VERSION_CODE, '--version-name', VERSION_NAME, res_zip])
    classes_jar = work / 'classes.jar'
    with zipfile.ZipFile(classes_jar, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(classes.rglob('*.class')):
            archive.write(path, path.relative_to(classes).as_posix())
    dex_dir = work / 'dex'
    dex_dir.mkdir()
    # Xposed 由宿主提供，只参与解析；唯一 dex 输入是本项目的 classes.jar。
    run([D8, '--lib', ANDROID_JAR, '--classpath', XPOSED_JAR, '--min-api', MIN_API,
         '--release', '--output', dex_dir, classes_jar])
    require_files([dex_dir / 'classes.dex'])
    with zipfile.ZipFile(base, 'a', zipfile.ZIP_DEFLATED) as archive:
        # aapt2 默认忽略点目录；直接写 ZIP 保留控制页的 .file 壁纸资源。
        for asset in sorted(assets.rglob('*')):
            if asset.is_file():
                archive.write(asset, 'assets/' + asset.relative_to(assets).as_posix())
        for dex in sorted(dex_dir.glob('classes*.dex')):
            archive.write(dex, dex.name)
    aligned = work / 'aligned.apk'
    run([ZIPALIGN, '-f', '4', base, aligned])
    signed = work / 'signed.apk'
    java, _ = java_tools()
    run([java, '-jar', APKSIGNER, 'sign', '--ks', KEYSTORE,
         '--ks-pass', 'env:HYPEROS_KEYSTORE_PASSWORD', '--key-pass', 'env:HYPEROS_KEYSTORE_PASSWORD',
         '--ks-key-alias', KS_ALIAS, '--out', signed, aligned], env=signing_env(), capture=True)
    verify_apk(signed)
    os.replace(signed, OUT)
    print('产物: %s (%d 字节)' % (OUT, OUT.stat().st_size))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='只运行 ECJ 编译，不生成 APK')
    args = parser.parse_args()
    if args.check:
        with tempfile.TemporaryDirectory(prefix='hyperos-app-check-') as directory:
            compile_java(Path(directory))
    else:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.app-build-', dir=OUT.parent) as directory:
            work = Path(directory)
            build(work, compile_java(work))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error)) from None
