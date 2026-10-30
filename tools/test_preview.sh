#!/bin/bash
# 预览页面测试：App 调用的预览函数都不能抛出异常。需要 macOS。用法：tools/test_preview.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swiftc -O -o "$OUT/preview_test" tools/preview_test/main.swift
"$OUT/preview_test" "$PWD/macos/Resources/preview/preview.html"
