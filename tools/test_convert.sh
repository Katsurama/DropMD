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
    (Path(d) / "报告 1.md").write_text("![Image](%E6%8A%A5%E5%91%8A_1_images/image_000000_ab12.png)")
    ok = images_dir_name(Path(d) / "报告_1.md") == "报告_1_images_2"
    failed += not ok
    print("ok  " if ok else "FAIL", "高精度模式编码过的路径也不共用文件夹")
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
# Xiaomi-OCR-0 的输出：表格、公式转成普通 Markdown
from dropmd.xiaomi import clean as xclean
for name, src, want in [
    ("OTSL 表格", "前文\n\n<fcel>名<fcel>值<nl><fcel>a|b<ecel><nl>\n\n后文", "前文\n\n| 名 | 值 |\n| --- | --- |\n| a\\|b |  |\n\n后文"),
    ("合并单元格重复内容", "<fcel>A<lcel><fcel>C<nl><fcel>D<ucel><ucel><nl><xcel><fcel>F<nl>",
     "| A | A | C |\n| --- | --- | --- |\n| D | A | C |\n| D | F |  |"),
    ("行数不齐补空格", "<fcel>a<fcel>b<nl><fcel>c", "| a | b |\n| --- | --- |\n| c |  |"),
    ("表格前后同段的文字不丢", "表1 <fcel>a<nl> 注", "表1\n\n| a |\n| --- |\n\n注"),
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
# 转换中点“停止”（界面结束引擎的进程组）：正在跑的 Pandoc 要一起结束，不能事后在文件夹里留下 .md.part
import json, signal, time
with tempfile.TemporaryDirectory() as d:
    fake = Path(d) / "bin"
    fake.mkdir()
    # 假的 Pandoc：过 2 秒才把结果写到最后一个参数（.md.part）
    (fake / "pandoc").write_text('#!/bin/sh\nsleep 2\nfor a; do last="$a"; done\necho hi > "$last"\n')
    (fake / "pandoc").chmod(0o755)
    (Path(d) / "w.docx").write_bytes(b"x")
    job = {"jobs": [{"src": str(Path(d) / "w.docx"), "dst": str(Path(d) / "w.md")}], "options": {"word_engine": "pandoc"}}
    env = {**os.environ, "PATH": f"{fake}:{os.environ['PATH']}", "DROPMD_DATA_DIR": str(Path(d) / "data"), "PYTHONPATH": "src"}
    p = subprocess.Popen([sys.executable, "-m", "dropmd", "--engine", "convert"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    p.stdin.write(json.dumps(job).encode()); p.stdin.close()
    first = p.stdout.readline()   # {"event":"start"}：已经开始转换（引擎没起来时是空的，不能算通过）
    time.sleep(0.5)
    try:   # 和 Engine.swift 的 terminate 一样：结束整个进程组，没有这个组时只结束引擎
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        p.terminate()
    p.wait()
    time.sleep(2.5)
    left = sorted(x.name for x in Path(d).iterdir() if x.name.startswith("w.md"))
    ok = b'"start"' in first and left == []
    failed += not ok
    print("ok  " if ok else "FAIL", "停止时 Pandoc 一起结束", "" if ok else f"\n     引擎第一行：{first!r}，留下了：{left}")
# 重新转换（Pandoc、高精度模式）后删掉新 .md 不再用的旧图片：只删本程序命名的；
# 还在用的不删，包括高精度模式里中文路径被编码的；用户自己放的不动
from dropmd.converters import DOCLING_IMAGE, PANDOC_IMAGE, drop_unused_images
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    files = ["报告_images/media/image1.png", "报告_images/media/image2.png", "报告_images/media/我的.png",
             "报告_images/image_000000_ab12.png", "报告_images/image_000001_cd34.png"]
    for f in files:
        (root / f).parent.mkdir(parents=True, exist_ok=True)
        (root / f).write_bytes(b"x")
    dst = root / "报告.md"
    drop_unused_images(dst, "报告_images", "![](报告_images/media/image1.png)", PANDOC_IMAGE)
    drop_unused_images(dst, "报告_images", "![Image](%E6%8A%A5%E5%91%8A_images/image_000000_ab12.png)", DOCLING_IMAGE)
    left = sorted(p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file())
    want = ["报告_images/image_000000_ab12.png", "报告_images/media/image1.png", "报告_images/media/我的.png"]
    ok = left == want
    failed += not ok
    print("ok  " if ok else "FAIL", "重新转换删掉不用的旧图片", "" if ok else f"\n     left: {left!r}")
print("全部通过" if not failed else f"失败 {failed} 项")
raise SystemExit(1 if failed else 0)
EOF
