#!/usr/bin/env python3
"""发布工具

用法:
  python3 tools/release.py build                # 版本号 patch +1、打包到 dist/，不发不推（给你测试）
  python3 tools/release.py build 1.1.0          # 指定版本号打包（功能更新时手动指定）
  python3 tools/release.py publish              # 更新 latest.json、清理旧版本、提交推送、校验 CDN
  python3 tools/release.py publish --no-push    # 只改本地文件，不提交不推送（干跑）

版本号：语义化 x.y.z，文件名「动态温控·解容工具箱_vx.y.z.zip」；
versionCode 仍为递增整数，供客户端比较新旧版本。
约定：build 之后等你确认，才执行 publish。
"""
import os, re, sys, json, time, hashlib, subprocess, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'src')
DIST = os.path.join(ROOT, 'dist')
PROP = os.path.join(SRC, 'module.prop')
LATEST = os.path.join(ROOT, 'latest.json')
PACK = os.path.join(ROOT, 'tools', 'pack.py')
NAME = '动态温控·解容工具箱'
KEEP = 3
SEMVER = re.compile(r'(\d+)\.(\d+)\.(\d+)')
ZIP_RE = re.compile(re.escape(NAME) + r'_v(.+)\.zip$')

REPO_SLUG = '1014411313/aigate-usage'
BRANCH = 'main'
CDN = 'https://cdn.jsdelivr.net/gh/%s@%s/' % (REPO_SLUG, BRANCH)
CDN_CN = 'https://testingcf.jsdelivr.net/gh/%s@%s/' % (REPO_SLUG, BRANCH)
RAW = 'https://raw.githubusercontent.com/%s/%s/' % (REPO_SLUG, BRANCH)
REL = 'hyperos-thermal-module/'


def prop(key):
    for line in open(PROP, encoding='utf-8'):
        if line.startswith(key + '='):
            return line.split('=', 1)[1].strip()
    return ''


def set_prop(key, val):
    txt = open(PROP, encoding='utf-8').read()
    txt = re.sub(r'^%s=.*$' % key, '%s=%s' % (key, val), txt, flags=re.M)
    open(PROP, 'w', encoding='utf-8').write(txt)


def bump(arg=None):
    vc = int(prop('versionCode') or 0) + 1
    vn = prop('version')
    if arg:
        if not SEMVER.fullmatch(arg):
            print('版本号需形如 1.0.0，收到：%s' % arg)
            sys.exit(1)
        new = arg
    else:
        m = SEMVER.fullmatch(vn)
        new = '%s.%s.%d' % (m.group(1), m.group(2), int(m.group(3)) + 1) if m else '1.0.0'
    set_prop('versionCode', vc)
    set_prop('version', new)
    return vc, new


def zip_name(vn):
    return '%s_v%s.zip' % (NAME, vn)


def zip_path(vn):
    return os.path.join(DIST, zip_name(vn))


def dist_entries():
    """dist 里的发布包，按修改时间从新到旧：(versionName, 路径)"""
    out = []
    for f in os.listdir(DIST):
        m = ZIP_RE.match(f)
        if m:
            out.append((m.group(1), os.path.join(DIST, f)))
    out.sort(key=lambda x: os.path.getmtime(x[1]), reverse=True)
    return out


def do_build(arg=None):
    vc, vn = bump(arg)
    os.makedirs(DIST, exist_ok=True)
    out = zip_path(vn)
    r = subprocess.run([sys.executable, PACK, out], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        sys.exit(1)
    size = os.path.getsize(out)
    sha = hashlib.sha256(open(out, 'rb').read()).hexdigest()
    print('''
已打包（尚未发布）
  文件   : %s
  版本   : %s (%d)
  大小   : %d 字节
  sha256 : %s

测试通过后执行：python3 tools/release.py publish
''' % (os.path.relpath(out, ROOT), vn, vc, size, sha))
    return vc, vn, out, size, sha


def latest_upd(vc, vn, size, sha):
    d = json.load(open(LATEST, encoding='utf-8'))
    q = urllib.parse.quote(zip_name(vn))
    d['versionName'] = vn
    d['versionCode'] = vc
    d['zip'] = CDN + REL + 'dist/' + q
    d['zipCN'] = CDN_CN + REL + 'dist/' + q
    d['zipRaw'] = RAW + REL + 'dist/' + q
    d['sha256'] = sha
    d['size'] = size
    d['updated'] = time.strftime('%Y-%m-%d')
    # 以 dist 目录实际存在的文件为准重建 versions，避免清单里出现已删除的版本 / 漏掉现有版本
    old = {v.get('versionName'): v for v in d.get('versions', []) if isinstance(v, dict)}
    old[vn] = {
        'versionCode': vc, 'versionName': vn,
        'file': 'dist/' + zip_name(vn),
        'sha256': sha, 'size': size, 'date': time.strftime('%Y-%m-%d'),
        'note': old.get(vn, {}).get('note', '')
    }
    versions = []
    for name, path in dist_entries()[:KEEP]:
        v = old.get(name, {'versionCode': 0, 'versionName': name, 'sha256': '', 'size': 0, 'date': '', 'note': ''})
        v['file'] = os.path.relpath(path, ROOT)
        v['size'] = os.path.getsize(path)
        versions.append(v)
    d['versions'] = versions
    json.dump(d, open(LATEST, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    return d


def prune():
    removed = []
    for name, path in dist_entries()[KEEP:]:
        os.remove(path)
        removed.append(os.path.basename(path))
    return removed


def git(args, retries=5, wait=15):
    for i in range(retries):
        r = subprocess.run(['git'] + args, cwd=os.path.dirname(ROOT),
                           capture_output=True, text=True)
        if r.returncode == 0:
            return True, (r.stdout or '') + (r.stderr or '')
        print('  git %s 第 %d 次失败：%s' % (args[0], i + 1, (r.stderr or r.stdout).strip()[:120]))
        time.sleep(wait)
    return False, (r.stderr or r.stdout)


def verify(url, size, tries=6, wait=20):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, method='HEAD')
            with urllib.request.urlopen(req, timeout=60) as r:
                cl = r.headers.get('Content-Length')
                if r.status == 200 and (cl is None or int(cl) == size):
                    return True, 'HTTP %s, %s 字节' % (r.status, cl)
        except Exception as e:
            pass
        time.sleep(wait)
    return False, '未取到 200'


def do_publish(no_push):
    vc = int(prop('versionCode') or 0)
    vn = prop('version')
    f = zip_path(vn)
    if not os.path.exists(f):
        print('缺少 %s，请先执行 build' % f)
        sys.exit(1)
    size = os.path.getsize(f)
    sha = hashlib.sha256(open(f, 'rb').read()).hexdigest()
    d = latest_upd(vc, vn, size, sha)
    removed = prune()
    print('latest.json -> %s / %s' % (vc, vn))
    if removed:
        print('清理旧版本:', ', '.join(removed))
    if no_push:
        print('（--no-push：未提交、未推送）')
        return
    ok, out = git(['add', 'hyperos-thermal-module'])
    ok2, out2 = git(['commit', '-m', 'chore(release): %s v%s' % (NAME, vn)])
    ok3, out3 = git(['push', 'origin', BRANCH])
    if not ok3:
        print('推送失败：', out3.strip()[:200])
        sys.exit(1)
    print('已推送')
    q = urllib.parse.quote(zip_name(vn))
    okv, msg = verify(CDN_CN + REL + 'dist/' + q, size)
    print('CDN(大陆):', msg)
    print('\n下载链接：\n  ' + CDN_CN + REL + 'dist/' + q)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ('build', 'publish'):
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == 'build':
        do_build(sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        do_publish('--no-push' in sys.argv)


if __name__ == '__main__':
    main()
