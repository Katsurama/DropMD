#!/bin/bash
# 在本机完整构建 DropMD（与 GitHub Actions 的“构建 DropMD”相同步骤），可选直接发布。
# 用法：
#   tools/build_local.sh                 只构建：输出 DropMD-macOS-AppleSilicon.dmg / .zip
#   tools/build_local.sh v1.2.0-beta.10  构建后创建 GitHub Release 并上传（需要 gh 已登录）
# 需要：Apple 芯片的 Mac、Xcode、Homebrew 的 python@3.12（brew install python@3.12）。
# 依赖装在 .venv/（不提交），第一次运行要下载几 GB。
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:-}"
PANDOC_VERSION="3.9.0.2"
PANDOC_SHA256="6e9eca844076bcbb599bbeebbba78a70f93b5307782b85c2c272872812c88875"
APP_ID="io.github.dropmd.app"

if [ -n "$TAG" ]; then
  case "$TAG" in v*) ;; *) echo "版本号要以 v 开头，例如 v1.2.0-beta.10"; exit 1 ;; esac
  want="${TAG#v}"
  have=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" macos/Resources/Info.plist)
  [ "$want" = "$have" ] || { echo "Info.plist 的版本是 $have，与 $TAG 不一致"; exit 1; }
  [ -z "$(git status --porcelain -- . ":!THIRD_PARTY_LICENSES.md")" ] || { echo "有未提交的修改，先提交再发布"; exit 1; }
  git fetch -q origin
  [ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}')" ] || { echo "本地与 GitHub 不一致，先推送"; exit 1; }
fi

echo "== 测试"
tools/test_codec.sh
tools/test_editor.sh
tools/test_update.sh
tools/test_convert.sh

echo "== Python 依赖（.venv）"
PY="${PYTHON:-/opt/homebrew/bin/python3.12}"
[ -x "$PY" ] || { echo "找不到 Python 3.12：brew install python@3.12"; exit 1; }
[ -x .venv/bin/python ] || "$PY" -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install -q --upgrade pip
pip install -q -r requirements.txt -r requirements-build.txt
mkdir -p build
pip freeze --exclude-editable > build/requirements-frozen.txt

echo "== Pandoc"
if [ ! -x packaging/pandoc/pandoc ] || ! packaging/pandoc/pandoc --version | grep -q "pandoc $PANDOC_VERSION"; then
  f="build/pandoc-${PANDOC_VERSION}-arm64-macOS.zip"
  curl -fsSL -o "$f" "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/$(basename "$f")"
  echo "$PANDOC_SHA256  $f" | shasum -a 256 -c -
  rm -rf build/pandoc_x && mkdir -p build/pandoc_x packaging/pandoc
  unzip -q "$f" -d build/pandoc_x
  cp build/pandoc_x/*/bin/pandoc packaging/pandoc/
  chmod +x packaging/pandoc/pandoc
fi

echo "== MiSans 字体"
tools/fetch_fonts.sh

echo "== 第三方许可证清单"
bash tools/third_party.sh "macOS"

echo "== 打包转换引擎"
pyinstaller packaging/dropmd.spec --noconfirm
dist/dropmd-engine/dropmd-engine --selftest build/st_fast
dist/dropmd-engine/dropmd-engine --engine status | python -c "import json,sys; d=json.load(sys.stdin); print(d); assert d['pandoc'] and 'vision' in d['ocr_engines']"

echo "== 组装 DropMD.app"
# 软件更新的来源：从 git 远程地址取得 owner/repo（GitHub Actions 上由 GITHUB_REPOSITORY 提供）
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')}"
case "$GITHUB_REPOSITORY" in */*) export GITHUB_REPOSITORY ;; *) echo "无法从 git 远程地址取得仓库名"; exit 1 ;; esac
macos/build_app.sh
# 许可证清单已经放进 App；仓库里只保留固定说明（与 GitHub 上的构建相同）
git checkout -q -- THIRD_PARTY_LICENSES.md

echo "== 检查程序里没有本机路径"
if grep -r -l -a -F "$HOME" dist/DropMD.app; then echo "程序里含有本机路径（$HOME），不能发布"; exit 1; fi
echo "== 启动测试"
cp packaging/samples/editor_sample.md build/示例.md
asked=$(defaults read "$APP_ID" askedAutoUpdate 2>/dev/null || true)
defaults write "$APP_ID" askedAutoUpdate -bool true
open -n -a "$PWD/dist/DropMD.app" build/示例.md
sleep 10
pid=$(pgrep -f "$PWD/dist/DropMD.app/Contents/MacOS/" | head -1 || true)
[ -n "$pid" ] || { echo "DropMD 启动失败"; exit 1; }
kill "$pid"
[ -n "$asked" ] || defaults delete "$APP_ID" askedAutoUpdate

echo "== 生成 .dmg 和 .zip"
rm -f DropMD-macOS-AppleSilicon.*
mkdir -p build/dmg
swift macos/dmg/make_background.swift build/dmg
tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff
dmgbuild -s macos/dmg/settings.py \
  -D app=dist/DropMD.app -D background=build/dmg/background.tiff \
  "DropMD" DropMD-macOS-AppleSilicon.dmg
hdiutil verify DropMD-macOS-AppleSilicon.dmg
ditto -c -k --sequesterRsrc --keepParent dist/DropMD.app DropMD-macOS-AppleSilicon.zip
shasum -a 256 DropMD-macOS-AppleSilicon.dmg > DropMD-macOS-AppleSilicon.dmg.sha256
shasum -a 256 DropMD-macOS-AppleSilicon.zip > DropMD-macOS-AppleSilicon.zip.sha256
ls -la DropMD-macOS-AppleSilicon.*

[ -n "$TAG" ] || { echo "构建完成（没有发布）。"; exit 0; }

echo "== 发布 $TAG"
# 用 1Password 插件登录 gh 时，脚本里没有 gh 函数，改用 op plugin run
GH=(gh)
if command -v op >/dev/null && [ -f "$HOME/.config/op/plugins.sh" ]; then GH=(op plugin run -- gh); fi
"${GH[@]}" release create "$TAG" \
  DropMD-macOS-AppleSilicon.dmg DropMD-macOS-AppleSilicon.dmg.sha256 \
  DropMD-macOS-AppleSilicon.zip DropMD-macOS-AppleSilicon.zip.sha256 \
  --target "$(git rev-parse HEAD)" \
  --title "DropMD $TAG" \
  --notes-file docs/发行说明.md
echo "已发布 $TAG"
