#!/bin/bash
# 下载 MiSans 字体（小米官方，免费商用）放进 App：简体用 MiSans，繁体用 MiSans TC，各取正文和粗体。
# 字体文件不放进公开仓库：MiSans 许可不允许单独分发字体文件，只能嵌入在软件中，并在软件中注明。
# 已下载且校验通过时不再下载。用法：tools/fetch_fonts.sh [目标文件夹，默认 build/fonts]
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-build/fonts}"
mkdir -p "$DEST"

# 官网的文件被替换时，校验会失败，构建停止，不会悄悄打包进别的文件
SUMS="8e9caa6f34f27c6baad1ecf0058cc13e1801efff698bc23e6e0b095d9a9ed9cb  MiSans-Regular.otf
575d0481f579785fab27754a337ad77118a17ba3353210ed84c8af4e96e86247  MiSans-Bold.otf
2ce7ac121db57ad6c370174fdfdd6d938246e47280eb6102f44c5c4949159e9e  MisansTC-Regular.otf
993d04bf9fc54a465c2583e3cedae3a7b9d72060895fe8ccd1870b5eb39da1e4  MisansTC-Bold.otf"

check() { (cd "$DEST" && echo "$SUMS" | shasum -a 256 -c --quiet - >/dev/null 2>&1); }
if check; then echo "MiSans 已就绪：$DEST"; exit 0; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/MiSans.zip" https://hyperos.mi.com/font-download/MiSans.zip
curl -fsSL -o "$TMP/MiSans_TC.zip" https://hyperos.mi.com/font-download/MiSans_TC.zip
unzip -o -q -j "$TMP/MiSans.zip" "MiSans/otf/MiSans-Regular.otf" "MiSans/otf/MiSans-Bold.otf" -d "$DEST"
unzip -o -q -j "$TMP/MiSans_TC.zip" "MiSans TC/otf/MisansTC-Regular.otf" "MiSans TC/otf/MisansTC-Bold.otf" -d "$DEST"
(cd "$DEST" && echo "$SUMS" | shasum -a 256 -c -)
echo "MiSans 已下载：$DEST"
