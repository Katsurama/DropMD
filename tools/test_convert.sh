#!/bin/bash
# 文件转换后处理测试（不需要转换引擎）。用法：tools/test_convert.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONPATH=src PYTHONDONTWRITEBYTECODE=1 DROPMD_LANG=zh
python3 - <<'EOF'
from dropmd.converters import fill_empty_table_headers as fill

cases = [
    ("空表头", "|  |  |\n| --- | --- |\n| 项目 | 数量 |\n| 苹果 | 3 |",
     "| 项目 | 数量 |\n| --- | --- |\n| 苹果 | 3 |"),
    ("已有表头不动", "| 名称 | 说明 |\n| --- | --- |\n| a | b |",
     "| 名称 | 说明 |\n| --- | --- |\n| a | b |"),
    ("只有空表头不动", "|  |\n| --- |", "|  |\n| --- |"),
    ("正文中的表格", "前文\n\n|  |  |\n| :-- | --: |\n| x | y |\n\n后文",
     "前文\n\n| x | y |\n| :-- | --: |\n\n后文"),
]
failed = 0
for name, src, want in cases:
    got = fill(src)
    ok = got == want
    failed += not ok
    print("ok  " if ok else "FAIL", name, "" if ok else f"\n     got:  {got!r}\n     want: {want!r}")
# Xiaomi-OCR-0 的输出：表格、公式转成普通 Markdown
from dropmd.xiaomi import clean as xclean
for name, src, want in [
    ("OTSL 表格", "前文\n\n<fcel>名<fcel>值<nl><fcel>a|b<ecel><nl>\n\n后文", "前文\n\n| 名 | 值 |\n| --- | --- |\n| a\\|b |  |\n\n后文"),
    ("合并单元格重复内容", "<fcel>A<lcel><fcel>C<nl><fcel>D<ucel><ucel><nl><xcel><fcel>F<nl>",
     "| A | A | C |\n| --- | --- | --- |\n| D | A | C |\n| D | F |  |"),
    ("行数不齐补空格", "<fcel>a<fcel>b<nl><fcel>c", "| a | b |\n| --- | --- |\n| c |  |"),
    ("表格前后同段的文字不丢", "表1 <fcel>a<nl> 注", "表1\n\n| a |\n| --- |\n\n注"),
    ("同段两张表：表间文字不丢、不合成一张", "<fcel>A<fcel>B<nl><fcel>1<fcel>2<nl>中间说明文字\n<fcel>C<fcel>D<nl><fcel>3<fcel>4<nl>",
     "| A | B |\n| --- | --- |\n| 1 | 2 |\n\n中间说明文字\n\n| C | D |\n| --- | --- |\n| 3 | 4 |"),
    ("行内公式", r"设 \( x+1 \) 和 $\(y\)$ 成立", "设 $x+1$ 和 $y$ 成立"),
    ("独立公式", "\\[\na=b\n\\]", "$$a=b$$"),
    ("代码块不动", "```\n\\(x\\) <fcel>a\n\n<nl>\n```", "```\n\\(x\\) <fcel>a\n\n<nl>\n```"),
    ("无空行代码块不动", "```\n\\(x\\) <fcel>a<nl>\n```", "```\n\\(x\\) <fcel>a<nl>\n```"),
    ("页末没闭合的代码块不动", "前文 \\(y\\)\n\n```\n\\(x\\)", "前文 $y$\n\n```\n\\(x\\)"),
    ("普通文字不动", "价格 $5 和 <b> 不变", "价格 $5 和 <b> 不变"),
]:
    got = xclean(src)
    ok = got == want
    failed += not ok
    print("ok  " if ok else "FAIL", name, "" if ok else f"\n     got:  {got!r}\n     want: {want!r}")
# 读不了的 PDF：三种引擎的英文报错都换成同一句话；加了密码的仍说密码
from dropmd.errors import describe
for cls, msg, want in [
    ("FileConversionException", "File conversion failed after 1 attempts:\n - PdfConverter threw PSEOF with message: Unexpected EOF\n", "PDF 文件已损坏或格式无效。"),
    ("ConversionError", "Conversion failed for: a.pdf with status: failure. Errors: docling-parse could not load document abc", "PDF 文件已损坏或格式无效。"),
    ("PdfiumError", "Failed to load document (PDFium: Data format error).", "PDF 文件已损坏或格式无效。"),
    ("PdfiumError", "Failed to load document (PDFium: Incorrect password error).", "文件已加密或设有密码，无法转换。请先解除密码保护。"),
]:
    got = describe(type(cls, (Exception,), {})(msg))
    ok = got == want
    failed += not ok
    print("ok  " if ok else "FAIL", "读不了的 PDF", cls, "" if ok else f"\n     got:  {got!r}")
# 引擎提示跟着界面语言：简体、繁体、英文
import subprocess, sys, os
for lang, want in [("zh", "找不到文件，可能已被移动或删除。"), ("zh-Hant", "找不到檔案，可能已被移動或刪除。"),
                   ("en", "File not found. It may have been moved or deleted.")]:
    got = subprocess.run([sys.executable, "-c", "from dropmd.errors import describe; print(describe(FileNotFoundError()))"],
                         env={**os.environ, "DROPMD_LANG": lang}, capture_output=True, text=True).stdout.strip()
    ok = got == want
    failed += not ok
    print("ok  " if ok else "FAIL", f"引擎提示 {lang}", "" if ok else f"\n     got:  {got!r}")
# 同进程内动态切换 DROPMD_LANG 时，errors 与 models 也应即时切换语言
from dropmd.models import COMPONENTS as _COMPS
_orig_lang = os.environ.get("DROPMD_LANG")
try:
    os.environ["DROPMD_LANG"] = "en"
    ok = describe(FileNotFoundError()).startswith("File not found") and _COMPS["layout"].title.startswith("Layout analysis")
    os.environ["DROPMD_LANG"] = "zh-Hant"
    ok = ok and "找不到檔案" in describe(FileNotFoundError()) and "辨識" in _COMPS["table"].title
    failed += not ok
    print("ok  " if ok else "FAIL", "同进程动态切换语言")
finally:
    if _orig_lang is None:
        os.environ.pop("DROPMD_LANG", None)
    else:
        os.environ["DROPMD_LANG"] = _orig_lang
print("全部通过" if not failed else f"失败 {failed} 项")
raise SystemExit(1 if failed else 0)
EOF
python3 tools/test_conversion_transactions.py
