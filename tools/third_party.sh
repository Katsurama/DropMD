#!/bin/bash
# 生成 THIRD_PARTY_LICENSES.md：固定说明 + 本次构建实际打包的所有 Python 库及其许可证。
set -euo pipefail
cp docs/THIRD_PARTY_HEADER.md THIRD_PARTY_LICENSES.md
{
  echo ""
  echo "## 本次构建实际打包的 Python 库（$1）"
  echo ""
  pip-licenses --format=markdown --with-urls --order=name \
    --ignore-packages pyinstaller pyinstaller-hooks-contrib pip-licenses altgraph macholib pefile pywin32-ctypes prettytable wcwidth dmgbuild ds_store ds-store mac_alias mac-alias
} >> THIRD_PARTY_LICENSES.md
