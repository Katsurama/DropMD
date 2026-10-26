#!/bin/bash
# Markdown 转换（解析 ⇄ 序列化）往返测试。只用到 Foundation，macOS 和 Linux 都能运行。
# 用法：tools/test_codec.sh
set -euo pipefail
cd "$(dirname "$0")/.."
S=macos/Sources/DropMD
OUT="$(mktemp -d)"
swiftc -O -o "$OUT/codec_test" tools/codec_test/main.swift \
  "$S/MarkdownCodec.swift" "$S/MarkdownInline.swift" "$S/MarkdownSerialize.swift"
"$OUT/codec_test"
