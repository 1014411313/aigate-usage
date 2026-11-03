#!/bin/sh
# 打包成可由 KernelSU / Magisk 管理器直接安装的模块 zip（文件位于压缩包根目录）
set -e
cd "$(dirname "$0")"

version=$(sed -n 's/^version=//p' module.prop)
out="dist/perf_tuner-${version}.zip"
mkdir -p dist
rm -f "$out"

chmod 0755 customize.sh service.sh action.sh uninstall.sh bin/perf.sh
chmod 0644 module.prop webroot/index.html webroot/style.css webroot/app.js webroot/ksu.js

python3 - "$PWD" "$out" <<'PY'
import os
import sys
import zipfile

src, out = sys.argv[1], sys.argv[2]
skip_dirs = {"dist", ".git", "__pycache__"}
skip_files = {"build.sh"}

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
    for base, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in skip_dirs and not d.startswith(".")]
        for name in sorted(files):
            if name.startswith("."):
                continue
            path = os.path.join(base, name)
            rel = os.path.relpath(path, src)
            if rel in skip_files:
                continue
            archive.write(path, rel)
print(f"已生成 {out}")
PY
