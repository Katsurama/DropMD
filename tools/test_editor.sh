#!/bin/bash
# 单页编辑器按键行为测试（自动格式、回车、Tab、退格）。需要 macOS 和完整的 Xcode。
# 用法：tools/test_editor.sh
set -euo pipefail
cd "$(dirname "$0")/.."
S=macos/Sources/DropMD
OUT="$(mktemp -d)"
swiftc -O -o "$OUT/editor_test" tools/editor_test/main.swift \
  "$S/MarkdownCodec.swift" "$S/MarkdownInline.swift" "$S/MarkdownSerialize.swift" \
  "$S/RichBridge.swift" "$S/RichStyle.swift" "$S/RichTextView.swift" "$S/EditorAction.swift"
"$OUT/editor_test"
