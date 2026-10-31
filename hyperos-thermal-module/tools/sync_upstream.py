#!/usr/bin/env python3
"""上游同步工具（电池解容工具箱 / 动态温控）

用法:
  python3 tools/sync_upstream.py list
  python3 tools/sync_upstream.py check  <组件> <上游zip>
  python3 tools/sync_upstream.py apply  <组件> <上游zip> [--include-new rel ...] [--skip rel ...]
  python3 tools/sync_upstream.py init   <组件> <上游zip>          # 首次建立基线（可选 --force）

组件：battery（电池解容工具箱）、thermal（动态温控）

规则（详见 upstream/README.md）：
  · 基线（上游原样）的哈希记在 upstream/manifest.json，我们改过的文件额外存一份文本快照到
    upstream/<组件>/base/，三方合并要用。
  · apply 时：我们没改过的文件直接覆盖；我们改过的走 git merge-file 三方合并；
    合并有冲突时保留我们的文件不动，另存 <文件>.merge 供人工处理。
  · 上游新增文件默认不引入，需要显式 --include-new。
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, 'upstream', 'manifest.json')
TEXT_EXT = {'.sh', '.prop', '.json', '.conf', '.md', '.txt', '.css', '.html', '.js', '.py', '.log'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load_manifest():
    if not os.path.isfile(MANIFEST):
        print('缺少 upstream/manifest.json')
        sys.exit(1)
    with open(MANIFEST, encoding='utf-8') as f:
        return json.load(f)


def save_manifest(m):
    with open(MANIFEST, 'w', encoding='utf-8') as f:
        json.dump(m, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write('\n')


def comp(m, name):
    c = m['components'].get(name)
    if not c:
        print('未知组件：%s（可用：%s）' % (name, ', '.join(m['components'])))
        sys.exit(1)
    return c


def read_zip(path):
    out = {}
    with zipfile.ZipFile(path) as z:
        for n in z.namelist():
            if n.endswith('/'):
                continue
            out[n] = z.read(n)
    return out


def skip(c, rel):
    return any(rel.startswith(p) for p in c.get('skip_prefixes', []))


def target_path(c, rel):
    return os.path.join(ROOT, c['target_dir'], rel)


def base_path(c, rel):
    return os.path.join(ROOT, c['base_dir'], rel)


def is_text(rel):
    return os.path.splitext(rel)[1].lower() in TEXT_EXT


def cmd_list():
    m = load_manifest()
    for name, c in m['components'].items():
        print('%-8s %-16s 基线 %-8s 已整合 %-8s 文件 %d 个，本地改动 %d 个' % (
            name, c['name'], c['base_version'], c.get('integrated_version', '-'),
            len(c['files']), len(c.get('local_modified', []))))


def cmd_check(name, zippath):
    m = load_manifest()
    c = comp(m, name)
    up = read_zip(zippath)
    base = c['files']
    tdir = os.path.join(ROOT, c['target_dir'])

    new, changed, same, removed = [], [], 0, []
    for rel, data in sorted(up.items()):
        if skip(c, rel):
            continue
        h = sha(data)
        if rel not in base:
            new.append(rel)
        elif base[rel] != h:
            changed.append(rel)
        else:
            same += 1
    for rel in sorted(base):
        if rel not in up:
            removed.append(rel)

    clean, conflict, absent = [], [], []
    for rel in changed:
        p = os.path.join(tdir, rel)
        if not os.path.isfile(p):
            absent.append(rel)
            continue
        ours = sha(open(p, 'rb').read())
        (clean if ours == base[rel] else conflict).append(rel)

    print('组件 %s（基线 %s） ← %s' % (name, c['base_version'], os.path.basename(zippath)))
    print('  未变 %d · 上游改动 %d（可直接覆盖 %d / 需三方合并 %d / 本地缺失 %d）· 上游新增 %d · 上游删除 %d'
          % (same, len(changed), len(clean), len(conflict), len(absent), len(new), len(removed)))
    if new:
        print('  上游新增：')
        for rel in new:
            print('    + %s (%d B)' % (rel, len(up[rel])))
    if clean:
        print('  可直接覆盖：')
        for rel in clean:
            print('    · %s' % rel)
    if conflict:
        print('  需三方合并：')
        for rel in conflict:
            print('    ! %s' % rel)
    if absent:
        print('  本地缺失（上游有、我们没有）：')
        for rel in absent:
            print('    ? %s' % rel)
    if removed:
        print('  上游已删除：')
        for rel in removed:
            print('    - %s' % rel)
    print('  提示：确认后用 apply 执行；上游新增项需 --include-new 显式引入。')
    return 0


def three_way_merge(rel, ours_path, base_file, theirs):
    with tempfile.NamedTemporaryFile(delete=False, suffix='.theirs') as tf:
        tf.write(theirs)
        theirs_path = tf.name
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix='.out') as of:
            out_path = of.name
        r = subprocess.run(['git', 'merge-file', '-p', '-L', 'ours', '-L', 'base', '-L', 'upstream',
                            ours_path, base_file, theirs_path], capture_output=True)
        merged = r.stdout
        with open(out_path, 'wb') as f:
            f.write(merged)
        if r.returncode == 0:
            shutil.copyfile(out_path, ours_path)
            return True, None
        return False, merged
    finally:
        for p in (theirs_path, locals().get('out_path')):
            if p and os.path.isfile(p):
                os.unlink(p)


def cmd_apply(name, zippath, include_new, skip_files, dry=False):
    m = load_manifest()
    c = comp(m, name)
    up = read_zip(zippath)
    base = c['files']
    tdir = os.path.join(ROOT, c['target_dir'])
    applied, merged, conflicts, added = [], [], [], []

    for rel, data in sorted(up.items()):
        if skip(c, rel) or rel in skip_files:
            continue
        p = os.path.join(tdir, rel)
        h = sha(data)
        if rel not in base:
            if rel in include_new:
                if not dry:
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    open(p, 'wb').write(data)
                added.append(rel)
            continue
        if base[rel] == h:
            continue
        ours = sha(open(p, 'rb').read()) if os.path.isfile(p) else None
        if ours is None or ours == base[rel]:
            if not dry:
                os.makedirs(os.path.dirname(p), exist_ok=True)
                open(p, 'wb').write(data)
            applied.append(rel)
            continue
        bp = base_path(c, rel)
        if not is_text(rel) or not os.path.isfile(bp):
            conflicts.append((rel, 'binary-or-no-base'))
            continue
        if dry:
            with tempfile.NamedTemporaryFile(delete=False, suffix='.ours') as cf:
                shutil.copyfile(p, cf.name)
                tmp_ours = cf.name
            try:
                ok, _ = three_way_merge(rel, tmp_ours, bp, data)
            finally:
                if os.path.isfile(tmp_ours):
                    os.unlink(tmp_ours)
        else:
            ok, merged_bytes = three_way_merge(rel, p, bp, data)
            if not ok:
                open(p + '.merge', 'wb').write(merged_bytes or b'')
        if ok:
            merged.append(rel)
            if not dry:
                os.makedirs(os.path.dirname(bp), exist_ok=True)
                open(bp, 'wb').write(data)
        else:
            conflicts.append((rel, 'merge-conflict'))

    if dry:
        print('组件 %s ← %s（试运行，未写入任何文件）' % (name, os.path.basename(zippath)))
        print('  可直接覆盖 %d · 三方合并可自动完成 %d · 上游新增引入 %d · 冲突 %d'
              % (len(applied), len(merged), len(added), len(conflicts)))
        for rel in applied:
            print('    = %s' % rel)
        for rel in merged:
            print('    ~ %s' % rel)
        for rel in added:
            print('    + %s' % rel)
        for rel, why in conflicts:
            print('    ! %s（%s）' % (rel, why))
        return 0 if not conflicts else 2

    # 更新 manifest
    c['files'] = {rel: sha(d) for rel, d in up.items() if not skip(c, rel)}
    c['base_version'] = up_version(zippath) or c['base_version']
    c['integrated_version'] = c['base_version']
    lm, lo = [], []
    for rel in c['files']:
        p = os.path.join(tdir, rel)
        if not os.path.isfile(p):
            lo.append(rel)
        elif sha(open(p, 'rb').read()) != c['files'][rel]:
            lm.append(rel)
    c['local_modified'] = sorted(lm)
    c['local_only'] = sorted(lo)
    save_manifest(m)

    print('组件 %s ← %s' % (name, os.path.basename(zippath)))
    print('  直接覆盖 %d · 三方合并成功 %d · 上游新增引入 %d · 冲突 %d'
          % (len(applied), len(merged), len(added), len(conflicts)))
    for rel in applied:
        print('    = %s' % rel)
    for rel in merged:
        print('    ~ %s（已自动合并）' % rel)
    for rel in added:
        print('    + %s' % rel)
    for rel, why in conflicts:
        print('    ! %s（%s）%s' % (rel, why, '' if why != 'merge-conflict' else ' → 见 ' + rel + '.merge'))
    return 0 if not conflicts else 2


def up_version(zippath):
    try:
        with zipfile.ZipFile(zippath) as z:
            txt = z.read('module.prop').decode('utf-8', 'ignore')
        for line in txt.splitlines():
            if line.startswith('version='):
                return line.split('=', 1)[1].strip()
    except Exception:
        pass
    return ''


def cmd_init(name, zippath, force=False):
    m = load_manifest()
    c = comp(m, name)
    if c.get('files') and not force:
        print('组件 %s 已有基线（%s），如需重建加 --force' % (name, c['base_version']))
        return 1
    up = read_zip(zippath)
    tdir = os.path.join(ROOT, c['target_dir'])
    files, lm, lo = {}, [], []
    for rel, data in up.items():
        if skip(c, rel):
            continue
        files[rel] = sha(data)
        p = os.path.join(tdir, rel)
        if not os.path.isfile(p):
            lo.append(rel)
            continue
        ours = open(p, 'rb').read()
        if sha(ours) != files[rel]:
            lm.append(rel)
            if is_text(rel):
                bp = base_path(c, rel)
                os.makedirs(os.path.dirname(bp), exist_ok=True)
                open(bp, 'wb').write(data)
    c['files'] = files
    c['base_version'] = up_version(zippath) or c.get('base_version', '?')
    c['local_modified'] = sorted(lm)
    c['local_only'] = sorted(lo)
    c['integrated_version'] = c['base_version']
    save_manifest(m)
    print('组件 %s 基线已建立：%s · 文件 %d · 本地改动 %d · 本地缺失 %d'
          % (name, c['base_version'], len(files), len(lm), len(lo)))
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] == 'list':
        return cmd_list()
    cmd = argv[1]
    if cmd in ('check', 'apply', 'init'):
        if len(argv) < 4:
            print(__doc__)
            return 1
        name, zippath = argv[2], argv[3]
        if cmd == 'check':
            return cmd_check(name, zippath)
        if cmd == 'init':
            return cmd_init(name, zippath, '--force' in argv)
        include_new, skip_files = [], []
        i = 4
        while i < len(argv):
            if argv[i] == '--include-new':
                i += 1
                while i < len(argv) and not argv[i].startswith('--'):
                    include_new.append(argv[i])
                    i += 1
            elif argv[i] == '--skip':
                i += 1
                while i < len(argv) and not argv[i].startswith('--'):
                    skip_files.append(argv[i])
                    i += 1
            else:
                i += 1
        return cmd_apply(name, zippath, include_new, skip_files, '--dry' in argv)
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
