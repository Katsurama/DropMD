#!/bin/bash
# 文件转换后处理测试（不需要转换引擎）。用法：tools/test_convert.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHONPATH=src python3 - <<'EOF'
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
# 内嵌图片存到“文件名_images”文件夹
import tempfile
from pathlib import Path
from dropmd.converters import _save_images
with tempfile.TemporaryDirectory() as d:
    dst = Path(d) / "a b.md"
    # 上次导出的多余图片会被删掉；用户自己放的文件不动
    (Path(d) / "a_b_images").mkdir()
    (Path(d) / "a_b_images/image7.png").write_bytes(b"old")
    (Path(d) / "a_b_images/mine.png").write_bytes(b"keep")
    got = _save_images("前![图](data:image/png;base64,aGk=)后![](data:image/jpeg;base64,!!)", dst)
    want = "前![图](a_b_images/image1.png)后<!-- 图片无法读取 -->"
    ok = (got == want and (Path(d) / "a_b_images/image1.png").read_bytes() == b"hi"
          and not (Path(d) / "a_b_images/image7.png").exists() and (Path(d) / "a_b_images/mine.png").exists())
    failed += not ok
    print("ok  " if ok else "FAIL", "导出图片", "" if ok else f"\n     got:  {got!r}")
print("全部通过" if not failed else f"失败 {failed} 项")
raise SystemExit(1 if failed else 0)
EOF
