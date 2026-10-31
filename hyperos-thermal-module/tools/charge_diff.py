#!/usr/bin/env python3
"""充电节点快照对比（原版解容 vs 二改整合版）

用法:
  python3 tools/charge_diff.py <A快照.txt> <B快照.txt> [输出报告.txt]

两份快照由模块「关于 → 工具 → 采集充电快照」生成（/sdcard/Download/xj_charge_*.txt）。
输出：按区块列出「仅 A 有」「仅 B 有」「值不同」三类差异，末尾给统计。
"""
import sys
import re

SKIP_SECTIONS = ()


def parse(path):
    sec = '?'
    data = {}
    order = []
    for line in open(path, encoding='utf-8', errors='ignore'):
        line = line.rstrip('\n')
        if not line.strip():
            continue
        if line.startswith('#'):
            continue
        m = re.match(r'^\[(.+)\]$', line.strip())
        if m:
            sec = m.group(1)
            if sec not in order:
                order.append(sec)
            continue
        if '=' not in line:
            continue
        k, v = line.split('=', 1)
        key = (sec, k.strip())
        if key not in data:
            order.append(key)
        data[key] = v.strip()
    return data, order


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    pa, pb = sys.argv[1], sys.argv[2]
    out_path = sys.argv[3] if len(sys.argv) > 3 else None

    A, oa = parse(pa)
    B, ob = parse(pb)

    lines = []
    def w(s=''):
        lines.append(s)

    w('# 充电节点对比报告')
    w('')
    w('- A（基准）: %s' % pa)
    w('- B（对比）: %s' % pb)
    w('- 采集时间: A=%s  B=%s' % (A.get(('meta', 'model'), '?'), B.get(('meta', 'model'), '?')))
    w('- 模块版本: A=%s  B=%s' % (A.get(('meta', 'mod_xj'), '?'), B.get(('meta', 'mod_xj'), '?')))
    w('')

    sections = []
    for k in list(oa) + list(ob):
        if isinstance(k, tuple) and k[0] not in sections:
            sections.append(k[0])

    total_diff = 0
    for sec in sections:
        keys_a = {k[1]: v for k, v in A.items() if k[0] == sec}
        keys_b = {k[1]: v for k, v in B.items() if k[0] == sec}
        only_a = [k for k in keys_a if k not in keys_b]
        only_b = [k for k in keys_b if k not in keys_a]
        diff = [k for k in keys_a if k in keys_b and keys_a[k] != keys_b[k]]
        if not (only_a or only_b or diff):
            continue
        total_diff += len(only_a) + len(only_b) + len(diff)
        w('## %s' % sec)
        if diff:
            w('### 值不同（%d）' % len(diff))
            for k in sorted(diff):
                w('  %-46s A=%s' % (k, keys_a[k]))
                w('  %-46s B=%s' % ('', keys_b[k]))
            w('')
        if only_a:
            w('### 仅 A 有（%d）' % len(only_a))
            for k in sorted(only_a):
                w('  %-46s A=%s' % (k, keys_a[k]))
            w('')
        if only_b:
            w('### 仅 B 有（%d）' % len(only_b))
            for k in sorted(only_b):
                w('  %-46s B=%s' % (k, keys_b[k]))
            w('')

    w('## 统计')
    w('  A 键数=%d  B 键数=%d  差异项=%d' % (len(A), len(B), total_diff))
    if total_diff == 0:
        w('  两份快照完全一致')

    text = '\n'.join(lines) + '\n'
    if out_path:
        open(out_path, 'w', encoding='utf-8').write(text)
        print('报告已写入 %s（差异 %d 项）' % (out_path, total_diff))
    else:
        print(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
