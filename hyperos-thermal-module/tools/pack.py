#!/usr/bin/env python3
# 从 src/ 打包可分发的模块 zip；输出到 dist/，文件名带 versionCode，便于多版本并存。
# 用法: python3 tools/pack.py [输出路径]
import os, sys, zipfile, time, hashlib, re

# 构建日期：打包时自动写入当天日期（发布/本地打包都走本脚本，源文件里的值不维护）
BUILD_DATE_RE = re.compile(r'(构建日期</span><span class="info-val">)\d{4}-\d{2}-\d{2}')
BUILD_DATE = time.strftime('%Y-%m-%d')


def stamp_build_date(data):
    return BUILD_DATE_RE.sub(lambda m: m.group(1) + BUILD_DATE, data.decode('utf-8')).encode('utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, 'src')
DIST = os.path.join(ROOT, 'dist')

EXEC = {'thermal_core.sh', 'service.sh', 'action.sh', 'uninstall.sh', 'customize.sh',
        'post-fs-data.sh', 'diagnose.sh', 'config_backup.sh', 'api/app_api.sh', 'api/snapshotd.sh',
        'battery/post-fs-data.sh', 'battery/service.sh', 'battery/uninstall.sh',
        'battery/bin/freepps'}
EXEC_DIR_PREFIX = ('battery/scripts/',)


def perms(rel):
    if rel.endswith('.sh') or rel in EXEC or rel.startswith(EXEC_DIR_PREFIX):
        return 0o100755
    return 0o100644


def read_prop(path, key):
    for line in open(path, encoding='utf-8'):
        if line.startswith(key + '='):
            return line.split('=', 1)[1].strip()
    return ''


def main():
    from build_app import OUT as APP_APK, verify_apk

    vc = read_prop(os.path.join(SRC, 'module.prop'), 'versionCode')
    vn = read_prop(os.path.join(SRC, 'module.prop'), 'version')
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        DIST, '温控解容工具箱_统一测试版_v%s.zip' % vn)
    apk_data = verify_apk(APP_APK)
    if not os.path.isfile(os.path.join(SRC, 'webroot', 'index.html')):
        sys.exit('缺少独立模块 WebUI: src/webroot/index.html')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)

    files = []
    for root, dirs, fs in os.walk(SRC):
        if root == SRC:
            dirs[:] = [name for name in dirs if name != 'hyperosui']
        dirs.sort(); fs.sort()
        for f in fs:
            rel = os.path.relpath(os.path.join(root, f), SRC)
            if rel == 'MiWKJR.apk':
                continue
            # 开发期的旧版备份（*.bak / *.glass-bak 等）不进包
            if '.bak' in f or f.endswith('-bak') or f.endswith('.orig'):
                continue
            files.append(rel)
    files.sort()

    order = ['module.prop'] + [f for f in files if f.startswith('META-INF/')] + \
            [f for f in files if f != 'module.prop' and not f.startswith('META-INF/')]
    order = [f for f in order if f in files]

    extra = {'MiWKJR.apk': apk_data}

    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel in order:
            p = os.path.join(SRC, rel)
            data = open(p, 'rb').read()
            zi = zipfile.ZipInfo(rel, date_time=time.localtime(os.path.getmtime(p))[:6])
            zi.external_attr = perms(rel) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
        for rel, data in extra.items():
            zi = zipfile.ZipInfo(rel, date_time=time.localtime()[:6])
            zi.external_attr = 0o100644 << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)

    size = os.path.getsize(out)
    sha = hashlib.sha256(open(out, 'rb').read()).hexdigest()
    print('version %s (%s)' % (vn, vc))
    print('output  %s' % out)
    print('entries %d  size %d' % (len(order) + len(extra), size))
    print('sha256  %s' % sha)


if __name__ == '__main__':
    main()
