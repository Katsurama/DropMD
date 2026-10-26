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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/zh-Hans.lproj"
cp "$BIN" "$APP/Contents/MacOS/DropMD"
# 去掉调试信息：其中记录了编译时中间文件的完整路径
strip -S "$APP/Contents/MacOS/DropMD"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 软件更新的来源：由 GitHub Actions 提供的仓库名（owner/repo），源码中不写死
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :DropMDUpdateRepository string $GITHUB_REPOSITORY" "$APP/Contents/Info.plist"
fi
# 只提供简体中文本地化，使系统菜单（关于、隐藏、退出等）也显示为中文
printf '"CFBundleDisplayName" = "DropMD";\n' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

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
cp "$ROOT/THIRD_PARTY_LICENSES.md" "$APP/Contents/Resources/THIRD_PARTY_LICENSES.md"
cp Resources/Credits.html "$APP/Contents/Resources/Credits.html"   # “关于 DropMD”中的开源致谢

# 本地临时签名（ad-hoc）。没有 Apple 开发者证书，首次打开需在“隐私与安全性”中允许。
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP" || echo "警告：签名校验未通过（不影响本地运行）"
echo "已生成 $APP"
