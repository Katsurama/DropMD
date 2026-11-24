#!/bin/bash
# 单页编辑器按键行为测试（自动格式、回车、Tab、退格）。需要 macOS 和完整的 Xcode。
# 用法：tools/test_editor.sh
set -euo pipefail
cd "$(dirname "$0")/.."
S=macos/Sources/DropMD
OUT="$(mktemp -d)"
swiftc -O -DDEBUG -o "$OUT/editor_test" tools/editor_test/main.swift \
  "$S/MarkdownCodec.swift" "$S/MarkdownInline.swift" "$S/MarkdownSerialize.swift" \
  "$S/RichBridge.swift" "$S/RichStyle.swift" "$S/RichTextView.swift" "$S/RichLayoutManager.swift" "$S/RichTextView+Paste.swift" "$S/RichTextView+Table.swift" "$S/RichTextView+Menu.swift" "$S/RichTextView+Keyboard.swift" "$S/SourceLineNumbers.swift" "$S/MarkdownHighlighter.swift" "$S/EditorAction.swift" "$S/DocLanguage.swift" "$S/MathRenderer.swift" "$S/HTMLExport.swift" "$S/WordExport.swift" "$S/Engine.swift" "$S/Planner.swift" "$S/MarkdownDocument.swift" "$S/FileDeletionWatch.swift" "$S/SiriIntelligence.swift"
"$OUT/editor_test"
