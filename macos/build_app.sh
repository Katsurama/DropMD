#!/bin/bash
# 构建 DropMD.app（SwiftUI 界面 + 本机转换引擎）并生成 .dmg。
# 前提：已在项目根目录执行 pyinstaller packaging/dropmd.spec，
#       生成了 dist/dropmd-engine/。
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="$ROOT/dist/DropMD.app"

# Xcode 27 默认的新编译方式会把 SDK 版本记成 14，用原来的编译方式（Xcode 26 本来就是这个）
FLAGS=(-c release --arch arm64)
if swift build --help 2>/dev/null | grep -q -- "--build-system"; then FLAGS+=(--build-system native); fi
# 程序里记录的源码路径改成相对路径，发布的程序中不出现构建机器上的文件夹（如用户名）
FLAGS+=(-Xswiftc -file-prefix-map -Xswiftc "$PWD=DropMD")
swift build "${FLAGS[@]}" --product DropMD
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/DropMD"
# 系统按程序记录的 SDK 版本决定是否启用 Liquid Glass；记录成旧版本时界面会退回旧样式
SDK_MAJOR="$(vtool -show-build "$BIN" | awk '$1 == "sdk" { split($2, v, "."); print v[1]; exit }')"
if [ "${SDK_MAJOR:-0}" -lt 26 ]; then
  echo "错误：程序记录的 SDK 版本为 ${SDK_MAJOR:-未知}，Liquid Glass 不会启用（需要 Xcode 26 或更高）" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/zh-Hant.lproj"
cp "$BIN" "$APP/Contents/MacOS/DropMD"
# 去掉调试信息：其中记录了编译时中间文件的完整路径
strip -S "$APP/Contents/MacOS/DropMD"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 软件更新的来源：由 GitHub Actions 提供的仓库名（owner/repo），源码中不写死
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :DropMDUpdateRepository string $GITHUB_REPOSITORY" "$APP/Contents/Info.plist"
fi
# 界面语言：中文（源码中的原文，简体）和英文（en.lproj 中的译文）。系统菜单（关于、隐藏、退出等）跟着显示对应语言。
# 繁体中文系统也显示中文界面（还没有繁体译文，界面文字是简体）；系统语言里都没有时用英文（Info.plist 的 CFBundleDevelopmentRegion）
# 中文的翻译表是“原文 = 原文”：没有本语言的翻译表时，系统会改用英文（开发语言）的译文
plutil -convert json -o - Resources/en.lproj/Localizable.strings | python3 -c '
import json, sys
for k in json.load(sys.stdin):
    e = json.dumps(k, ensure_ascii=False)
    print(e, "=", e + ";")' > "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"
for l in zh-Hans zh-Hant; do
  printf '"CFBundleDisplayName" = "DropMD";\n' > "$APP/Contents/Resources/$l.lproj/InfoPlist.strings"
done
cp "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings" "$APP/Contents/Resources/zh-Hant.lproj/"
cp -R Resources/en.lproj "$APP/Contents/Resources/en.lproj"

# 图标：Icon Composer 格式（Resources/AppIcon.icon），系统自动生成浅色、深色、透明、着色四种样式。
# 编译结果（Assets.car：macOS 26 起使用；AppIcon.icns：旧系统、安装盘使用）已提交在 Resources/AppIcon.compiled，
# 因为 GitHub 构建机上 Xcode 26 的 actool 编译这个图标时会崩溃。改图标后在本机运行 make_icon.sh 重新生成。
cp Resources/AppIcon.compiled/Assets.car Resources/AppIcon.compiled/AppIcon.icns "$APP/Contents/Resources/"

# 转换引擎
cp -R "$ROOT/dist/dropmd-engine" "$APP/Contents/Resources/engine"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

# Markdown 预览资源（markdown-it、KaTeX，均已随源码提供，不联网加载）与帮助文档
cp -R Resources/preview "$APP/Contents/Resources/preview"
cp "$ROOT/docs/使用说明.md" "$APP/Contents/Resources/使用说明.md"
cp "$ROOT/docs/User Guide.md" "$APP/Contents/Resources/User Guide.md"
cp "$ROOT/THIRD_PARTY_LICENSES.md" "$APP/Contents/Resources/THIRD_PARTY_LICENSES.md"
# “关于 DropMD”中的开源致谢：按界面语言放进 .lproj（放在 Resources 根目录时系统总是先用它）
cp Resources/Credits.html "$APP/Contents/Resources/zh-Hans.lproj/Credits.html"
cp Resources/Credits.html "$APP/Contents/Resources/zh-Hant.lproj/Credits.html"
# MiSans 字体（构建时由 tools/fetch_fonts.sh 从小米官网下载，不在仓库中）
[ -f "$ROOT/build/fonts/MiSans-Regular.otf" ] || { echo "错误：缺少 MiSans 字体，先运行 tools/fetch_fonts.sh" >&2; exit 1; }
mkdir -p "$APP/Contents/Resources/fonts"
cp "$ROOT"/build/fonts/*.otf "$APP/Contents/Resources/fonts/"

# Quick Look 预览扩展（访达里按空格预览 Markdown，显示上面的预览页面）。
# 扩展没有 main，由系统的 NSExtensionMain 启动；与 App 共用 DocLanguage、Markdown*.swift（符号链接）
QL="$APP/Contents/PlugIns/DropMDQuickLook.appex"
mkdir -p "$QL/Contents/MacOS" "$QL/Contents/Resources"
swiftc -O -parse-as-library -module-name DropMDQuickLook -target arm64-apple-macos14 -file-prefix-map "$PWD=DropMD" \
  Sources/DropMDQuickLook/*.swift -Xlinker -e -Xlinker _NSExtensionMain -o "$QL/Contents/MacOS/DropMDQuickLook"
strip -S "$QL/Contents/MacOS/DropMDQuickLook"
cp Resources/QuickLook-Info.plist "$QL/Contents/Info.plist"
for k in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Add :$k string $(/usr/libexec/PlistBuddy -c "Print :$k" Resources/Info.plist)" "$QL/Contents/Info.plist"
done
# 沙盒中的扩展读不到 App 本体的文件，预览页面和字体各放一份（约 20 MB）
cp -R "$APP/Contents/Resources/preview" "$APP/Contents/Resources/fonts" "$QL/Contents/Resources/"
for l in en zh-Hans zh-Hant; do
  mkdir -p "$QL/Contents/Resources/$l.lproj"
  cp "$APP/Contents/Resources/$l.lproj/Localizable.strings" "$QL/Contents/Resources/$l.lproj/"
done
codesign --force --sign - --entitlements Resources/QuickLook.entitlements "$QL"

# 本地临时签名（ad-hoc）。没有 Apple 开发者证书，首次打开需在“隐私与安全性”中允许。
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP" || echo "警告：签名校验未通过（不影响本地运行）"
echo "已生成 $APP"
