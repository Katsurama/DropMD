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
# 小米的服务器在 GitHub Actions 上经常传到一半就断开（curl 退出码 18）。
# curl 自己的 --retry 会从头再下，两百多 MB 的文件很难成功；这里按已下载的字节续传，
# 直到文件大小与服务器一致。最后仍由下面的 SHA-256 校验兜底。
fetch_zip() {
  local url="$1" dest="$2" total size attempt=0 stall=0 newsize
  total=$(curl --http1.1 -fsSL --max-time 60 -r 0-0 -D - -o /dev/null "$url" \
    | tr -d '\r' \
    | awk 'tolower($1) == "content-range:" { split($3, part, "/"); print part[2]; exit }') || total=""
  case "$total" in
    ''|*[!0-9]*)
      echo "取不到文件大小：$url" >&2
      return 1
      ;;
  esac

  : > "$dest"
  while :; do
    size=$(wc -c < "$dest" | tr -d ' ')
    if [ "$size" -eq "$total" ]; then
      return 0
    fi
    if [ "$size" -gt "$total" ]; then
      : > "$dest"
      continue
    fi

    attempt=$((attempt + 1))
    if [ "$attempt" -gt 300 ]; then
      echo "下载中断次数过多：$url" >&2
      return 1
    fi
    if [ "$attempt" -gt 1 ] && [ $((attempt % 10)) -eq 0 ]; then
      echo "续传 $(basename "$dest")：$size / $total 字节"
    fi

    # 每次只连一次；连接被对端断开时 curl 返回非 0，已写下的部分留给下一轮续传
    if [ "$size" -eq 0 ]; then
      curl --http1.1 -fsSL --connect-timeout 30 --max-time 300 --retry 0 -o "$dest" "$url" || true
    else
      curl --http1.1 -fsSL --connect-timeout 30 --max-time 300 --retry 0 -C "$size" -o "$dest" "$url" || true
    fi

    newsize=$(wc -c < "$dest" | tr -d ' ')
    if [ "$newsize" -le "$size" ]; then
      # 服务器没接受续传，或文件已经坏了：清空后从头下；连续没有进展就放弃
      stall=$((stall + 1))
      if [ "$stall" -ge 10 ]; then
        echo "下载没有进展：$url" >&2
        return 1
      fi
      : > "$dest"
      sleep 2
    else
      stall=0
    fi
  done
}

# 两个字体包同时下，缩短构建时间
fetch_zip https://hyperos.mi.com/font-download/MiSans.zip "$TMP/MiSans.zip" &
pid_fonts=$!
fetch_zip https://hyperos.mi.com/font-download/MiSans_TC.zip "$TMP/MiSans_TC.zip" &
pid_fonts_tc=$!
status=0
wait "$pid_fonts" || status=1
wait "$pid_fonts_tc" || status=1
[ "$status" -eq 0 ] || exit 1
unzip -o -q -j "$TMP/MiSans.zip" "MiSans/otf/MiSans-Regular.otf" "MiSans/otf/MiSans-Bold.otf" -d "$DEST"
unzip -o -q -j "$TMP/MiSans_TC.zip" "MiSans TC/otf/MisansTC-Regular.otf" "MiSans TC/otf/MisansTC-Bold.otf" -d "$DEST"
(cd "$DEST" && echo "$SUMS" | shasum -a 256 -c -)
echo "MiSans 已下载：$DEST"
