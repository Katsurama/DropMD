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
    dst.write_text("上次转换的结果")
    got = _save_images("前![图](data:image/png;base64,aGk=)后![](data:image/jpeg;base64,!!)", dst)
    want = "前![图](a_b_images/image1.png)后<!-- 图片无法读取 -->"
    ok = (got == want and (Path(d) / "a_b_images/image1.png").read_bytes() == b"hi"
          and not (Path(d) / "a_b_images/image7.png").exists() and (Path(d) / "a_b_images/mine.png").exists())
    failed += not ok
    print("ok  " if ok else "FAIL", "导出图片", "" if ok else f"\n     got:  {got!r}")
    # .md 还不存在：同名文件夹里用户自己的 image1.png 不删、不覆盖
    dst2 = Path(d) / "c.md"
    (Path(d) / "c_images").mkdir()
    (Path(d) / "c_images/image1.png").write_bytes(b"mine")
    got = _save_images("![](data:image/png;base64,aGk=)", dst2)
    ok = (got == "![](c_images/image2.png)" and (Path(d) / "c_images/image1.png").read_bytes() == b"mine"
          and (Path(d) / "c_images/image2.png").read_bytes() == b"hi")
    failed += not ok
    print("ok  " if ok else "FAIL", "不动用户的图片", "" if ok else f"\n     got:  {got!r}")
# “s t.md”和“s_t.md”清理后同名：各用各的文件夹，重新转换一个不影响另一个
with tempfile.TemporaryDirectory() as d:
    img = "![](data:image/png;base64,aGk=)"
    a, b = Path(d) / "s t.md", Path(d) / "s_t.md"
    a.write_text(_save_images(img, a))
    b.write_text(_save_images(img, b))
    keep_a = (Path(d) / "s_t_images/image1.png").exists()
    a2 = _save_images(img, a)
    b2 = _save_images(img, b)
    ok = (keep_a and a.read_text() == "![](s_t_images/image1.png)" == a2
          and b.read_text() == "![](s_t_images_2/image1.png)" == b2
          and (Path(d) / "s_t_images/image1.png").exists() and (Path(d) / "s_t_images_2/image1.png").exists())
    failed += not ok
    print("ok  " if ok else "FAIL", "清理后同名的文档不共用文件夹", "" if ok else f"\n     got:  {a.read_text()!r} {b.read_text()!r}")
# 名字以 .md 结尾的文件夹不影响转换；没提取到内容时不动上次的图片
with tempfile.TemporaryDirectory() as d:
    from dropmd.converters import images_dir_name, convert_markitdown
    from dropmd.errors import ConversionError
    import dropmd.converters as conv
    (Path(d) / "m_n.md").mkdir()
    ok = images_dir_name(Path(d) / "m n.md") == "m_n_images"
    failed += not ok
    print("ok  " if ok else "FAIL", "名字以 .md 结尾的文件夹")
    src, dst = Path(d) / "e.html", Path(d) / "e.md"
    src.write_text("x")
    dst.write_text("![](e_images/image1.png)")
    (Path(d) / "e_images").mkdir()
    (Path(d) / "e_images/image1.png").write_bytes(b"old")
    class _Empty:
        markdown = " "
    conv._markitdown = lambda: type("M", (), {"convert_local": lambda self, *a, **k: _Empty()})()
    try:
        convert_markitdown(src, dst)
        ok = False
    except ConversionError:
        ok = (Path(d) / "e_images/image1.png").exists() and dst.read_text() == "![](e_images/image1.png)"
    failed += not ok
    print("ok  " if ok else "FAIL", "转换失败不动上次的图片")
# 引擎提示跟着界面语言：简体、繁体、英文
import subprocess, sys, os
for lang, want in [("zh", "找不到文件，可能已被移动或删除。"), ("zh-Hant", "找不到檔案，可能已被移動或刪除。"),
                   ("en", "File not found. It may have been moved or deleted.")]:
    got = subprocess.run([sys.executable, "-c", "from dropmd.errors import describe; print(describe(FileNotFoundError()))"],
                         env={**os.environ, "DROPMD_LANG": lang}, capture_output=True, text=True).stdout.strip()
    ok = got == want
    failed += not ok
    print("ok  " if ok else "FAIL", f"引擎提示 {lang}", "" if ok else f"\n     got:  {got!r}")
print("全部通过" if not failed else f"失败 {failed} 项")
raise SystemExit(1 if failed else 0)
EOF
