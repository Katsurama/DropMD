"""高精度模式的可选识别方式：Xiaomi-OCR-0。把 PDF 逐页画成图片交给模型，模型直接输出整页 Markdown。

不经过 Docling，所以公式和表格不需要别的模型。
shortcut: 整页模式不导出 PDF 里的图片（官方分区模式要装 PaddlePaddle），需要时可用 Docling 的版面模型截图。

模型从本机加载，不会访问网络。

模型和项目：https://github.com/xiaomi-research/Xiaomi-OCR-0 （Apache-2.0，Copyright 2026 Xiaomi Corporation）。
提示语和公式写法转换参考该项目的 postprocess/document.py，并作了修改。
"""

from __future__ import annotations

import re
from pathlib import Path

from .errors import ConversionError, tr
from .models import COMPONENTS, missing_components
from .paths import models_dir

_PROMPT = (
    "Extract all information from the main body of the document image and represent it "
    "in markdown format, ignoring headers and footers. Tables should be expressed in OTSL "
    "format, formulas in the document should be represented using LATEX format, and the "
    "parsing should be organized according to the reading order."
)
_MAX_TOKENS = 4096
_MAX_WIDTH = 2200  # 与官方服务相同：150 dpi，宽度不超过 2200

_TAG = re.compile(r"<(fcel|ecel|lcel|ucel|xcel|nl)>")
# 模型有时在 \(…\) 外面再包一层 $，要一起去掉
_MATH = [
    (re.compile(r"\$\$?\s*\\\[\s*(.*?)\s*\\\]\s*\$\$?", re.S), r"$$\1$$"),
    (re.compile(r"\$\s*\\\(\s*(.*?)\s*\\\)\s*\$"), r"$\1$"),
    (re.compile(r"\\\[\s*(.*?)\s*\\\]", re.S), r"$$\1$$"),
    (re.compile(r"\\\(\s*(.*?)\s*\\\)"), r"$\1$"),
]


def _table(block: str) -> str:
    """OTSL 表格转 Markdown 表格。合并单元格重复内容，和 Docling 输出的表格一样。"""
    parts = _TAG.split(block)
    rows: list[list[str]] = []
    row: list[str] = []
    after = ""
    for tag, text in zip(parts[1::2], parts[2::2]):
        if tag == "nl":
            if row:
                rows.append(row)
            row, after = [], text
            continue
        after = ""
        if tag == "fcel":
            row.append(" ".join(text.split()).replace("|", r"\|"))
        elif tag == "lcel":
            row.append(row[-1] if row else "")
        elif tag in ("ucel", "xcel"):
            row.append(rows[-1][len(row)] if rows and len(row) < len(rows[-1]) else "")
        else:
            row.append("")
    if row:
        rows.append(row)
    width = max(map(len, rows), default=0)
    lines = ["| " + " | ".join(r + [""] * (width - len(r))) + " |" for r in rows]
    lines[1:1] = ["| " + " | ".join(["---"] * width) + " |"] if lines else []
    return "\n\n".join(p for p in (parts[0].strip(), "\n".join(lines), after.strip()) if p)


def clean(text: str) -> str:
    """模型输出转成普通 Markdown：表格转换，公式统一用 $。代码块里的内容不动。"""
    out = []
    fence = False
    for block in re.split(r"(\n\s*\n)", text):
        if block.count("```") % 2:
            fence = not fence
        elif not fence:
            if _TAG.search(block):
                block = _table(block)
            for pattern, repl in _MATH:
                block = pattern.sub(repl, block)
        out.append(block)
    return "".join(out).strip()


_loaded = None


def _load():
    global _loaded
    if _loaded is None:
        import torch
        from transformers import AutoModelForImageTextToText, AutoProcessor

        c = COMPONENTS["xiaomi"]
        path = models_dir() / c.repo_id.replace("/", "--")
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        dtype = torch.float16 if device == "mps" else torch.float32
        processor = AutoProcessor.from_pretrained(path, local_files_only=True)
        model = AutoModelForImageTextToText.from_pretrained(path, dtype=dtype, local_files_only=True).to(device).eval()
        _loaded = processor, model, device
    return _loaded


def _read_page(image) -> tuple[str, bool]:
    """返回这一页的文字，以及是否写满了长度上限（可能被截断或在重复输出）"""
    import torch

    processor, model, device = _load()
    messages = [{"role": "user", "content": [{"type": "image", "image": image}, {"type": "text", "text": _PROMPT}]}]
    inputs = processor.apply_chat_template(
        messages, tokenize=True, add_generation_prompt=True, return_dict=True, return_tensors="pt"
    ).to(device)
    with torch.inference_mode():
        output = model.generate(**inputs, max_new_tokens=_MAX_TOKENS, do_sample=False)
    new = output[:, inputs["input_ids"].shape[1]:]
    return processor.batch_decode(new, skip_special_tokens=True)[0], new.shape[1] >= _MAX_TOKENS


def convert_pdf(src: Path, dst: Path, on_page=None) -> str:
    """转换 PDF，Markdown 写入 dst。on_page(第几页, 总页数) 在每页开始前调用。"""
    import pypdfium2

    from .converters import _write_text

    missing = missing_components(["xiaomi"])
    if missing:
        raise ConversionError(tr("高精度模型尚未下载：", "High-accuracy models aren't downloaded yet: ", "高精度模型尚未下載：") + missing[0].title)
    pdf = pypdfium2.PdfDocument(str(src))
    try:
        pages, cut = [], []
        for i in range(len(pdf)):
            if on_page:
                on_page(i + 1, len(pdf))
            page = pdf[i]
            image = page.render(scale=min(150 / 72, _MAX_WIDTH / page.get_width())).to_pil().convert("RGB")
            text, full = _read_page(image)
            pages.append(clean(text))
            if full:
                cut.append(str(i + 1))
    finally:
        pdf.close()
    body = "\n\n".join(p for p in pages if p)
    if not body:
        raise ConversionError(tr("没有识别到文字。", "No text was recognized.", "沒有辨識到文字。"))
    _write_text(dst, body + "\n")
    info = tr("Xiaomi-OCR-0；不导出图片", "Xiaomi-OCR-0; images not exported", "Xiaomi-OCR-0；不匯出圖片")
    if cut:
        pages_text = "、".join(cut)
        info += tr(f"；第 {pages_text} 页可能不完整", f"; page {pages_text} may be incomplete", f"；第 {pages_text} 頁可能不完整")
    return info
