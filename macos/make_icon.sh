#!/bin/bash
# 重新生成 App 图标：图层 PNG（make_icon.swift）→ 用本机 Xcode 的 actool 编译到 Resources/AppIcon.compiled。
# 需要 Xcode 27 以上（Xcode 26 的 actool 编译这个图标会崩溃）。生成后把 Resources/AppIcon.compiled 一起提交。
set -euo pipefail
cd "$(dirname "$0")"
swift make_icon.swift
mkdir -p Resources/AppIcon.compiled
xcrun actool Resources/AppIcon.icon --compile Resources/AppIcon.compiled --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$(mktemp)" >/dev/null
ls -la Resources/AppIcon.compiled
