#!/bin/bash
# 软件更新的安装测试：从 .zip / .dmg 取出新版本，等旧进程退出后替换。需要 macOS。
# 用法：tools/test_update.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swiftc -O -o "$OUT/update_test" tools/update_test/main.swift macos/Sources/DropMD/AppUpdateInstaller.swift
"$OUT/update_test" "$OUT"
