#!/usr/bin/env python3
# 从 src/ 打包可分发的模块 zip；输出到 dist/，文件名带 versionCode，便于多版本并存。
# 用法: python3 tools/pack.py [输出路径]
import os, sys, zipfile, time, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, 'src')
DIST = os.path.join(ROOT, 'dist')

EXEC = {'thermal_core.sh', 'service.sh', 'action.sh', 'uninstall.sh', 'customize.sh',
        'post-fs-data.sh', 'diagnose.sh',
        'battery/post-fs-data.sh', 'battery/service.sh', 'battery/uninstall.sh',
        'battery/bin/freepps'}
EXEC_DIR_PREFIX = ('battery/scripts/',)


def perms(rel):
    if rel in EXEC or rel.startswith(EXEC_DIR_PREFIX):
        return 0o100755
    return 0o100644


def read_prop(path, key):
    for line in open(path, encoding='utf-8'):
        if line.startswith(key + '='):
            return line.split('=', 1)[1].strip()
    return ''


def main():
    vc = read_prop(os.path.join(SRC, 'module.prop'), 'versionCode')
    vn = read_prop(os.path.join(SRC, 'module.prop'), 'version')
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        DIST, 'HyperOS_XJ_K2_battery-pps-dtbo_v%s.zip' % vc)
    os.makedirs(os.path.dirname(out), exist_ok=True)

    files = []
    for root, dirs, fs in os.walk(SRC):
        dirs.sort(); fs.sort()
        for f in fs:
            files.append(os.path.relpath(os.path.join(root, f), SRC))
    files.sort()

    order = ['module.prop'] + [f for f in files if f.startswith('META-INF/')] + \
            [f for f in files if f != 'module.prop' and not f.startswith('META-INF/')]
    order = [f for f in order if f in files]

    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel in order:
            p = os.path.join(SRC, rel)
            data = open(p, 'rb').read()
            zi = zipfile.ZipInfo(rel, date_time=time.localtime(os.path.getmtime(p))[:6])
            zi.external_attr = perms(rel) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)

    size = os.path.getsize(out)
    sha = hashlib.sha256(open(out, 'rb').read()).hexdigest()
    print('version %s (%s)' % (vn, vc))
    print('output  %s' % out)
    print('entries %d  size %d' % (len(order), size))
    print('sha256  %s' % sha)


if __name__ == '__main__':
    main()
