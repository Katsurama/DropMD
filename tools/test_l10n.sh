#!/bin/bash
# 英文、日文界面测试：源码中要翻译的文字（String(localized:) 和 SwiftUI 中的文字）都要在 en.lproj、ja.lproj 中有译文，
# 译文的占位符（%@ / %lld）与原文一致，也没有源码中已不用的旧条目。需要 macOS。用法：tools/test_l10n.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# 编译器提取要翻译的文字（与 Xcode 生成翻译表时用的是同一个功能）
swiftc -c -wmo -parse-as-library -module-name DropMD -target arm64-apple-macos14 macos/Sources/DropMD/*.swift \
  -o "$OUT/DropMD.o" -emit-localized-strings -emit-localized-strings-path "$OUT" 2>/dev/null
for l in en ja; do plutil -convert json -o "$OUT/$l.json" macos/Resources/$l.lproj/Localizable.strings; done
python3 - "$OUT" <<'PY'
import glob, json, re, sys
out = sys.argv[1]
keys = {e["key"] for f in glob.glob(out + "/*.stringsdata")
        for t in json.load(open(f))["tables"].values() for e in t}
fmt = lambda s: sorted(re.findall(r"%(?:\d\$)?(?:@|lld|ld|d|lf|f)", s))
errors = []
for lang, name in [("en", "英文"), ("ja", "日文")]:
    tr = json.load(open(f"{out}/{lang}.json"))
    errors += [f"{name}缺少译文：{k!r}" for k in sorted(keys - tr.keys())]
    errors += [f"{name}多余的旧条目：{k!r}" for k in sorted(tr.keys() - keys)]
    errors += [f"{name}占位符不一致：{k!r} → {v!r}" for k, v in tr.items() if fmt(k) != fmt(v)]
print("\n".join(errors) or f"英文、日文界面：{len(keys)} 条文字都有译文")
sys.exit(1 if errors else 0)
PY
