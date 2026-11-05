"""转换调度：根据文件类型和用户选择的模式调用相应的引擎。

- 快速模式：MarkItDown（Word / Excel / PowerPoint / HTML / CSV / 文字型 PDF），
  Word / PowerPoint 里的图片导出到单独文件夹并在 Markdown 中引用
- Word 可选 Pandoc：还原排版更好，图片同样导出
- 高精度模式（仅对 PDF 生效）：Docling + OCR（Apple Vision 或 RapidOCR），见 hq.py

原始文件只会以只读方式打开，绝不会被修改。
"""

from __future__ import annotations

import base64
import re
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path

from .errors import ConversionError, tr
from .paths import pandoc_path, resource_root

MODE_FAST = "fast"
MODE_HQ = "hq"
WORD_MARKITDOWN = "markitdown"
WORD_PANDOC = "pandoc"


@dataclass
class Options:
    mode: str = MODE_FAST
    word_engine: str = WORD_MARKITDOWN
    ocr_engine: str = ""  # 空字符串表示使用默认引擎（RapidOCR）
    vision_lang: str = "zh-Hans"  # Apple Vision 的主要语言：zh-Hans / zh-Hant / ja-JP
    formulas: bool = False


_md_lock = threading.Lock()
_md_instance = None


def _markitdown():
    global _md_instance
    with _md_lock:
        if _md_instance is None:
            from markitdown import MarkItDown

            # 不启用第三方插件，不配置任何在线服务（LLM、Azure 文档智能等）
            _md_instance = MarkItDown(enable_plugins=False)
        return _md_instance


_UNSAFE_IN_LINK = re.compile(r"[\s#%?\[\]()<>]+")


def images_dir_name(dst: Path) -> str:
    """图片文件夹名：<文件名>_images，去掉会破坏 Markdown 链接的字符。

    “a b.md”和“a_b.md”清理后同名：别的文档正在用的文件夹不共用，否则重新转换会删掉它的图片。
    """
    stem = _UNSAFE_IN_LINK.sub("_", dst.stem)
    others = []
    for p in dst.parent.glob("*.md"):
        if p.stem != dst.stem and _UNSAFE_IN_LINK.sub("_", p.stem) == stem:
            try:
                others.append(p.read_text(encoding="utf-8", errors="ignore"))
            except OSError:  # 名字以 .md 结尾的文件夹、读不了的文件：不影响转换
                pass
    name, n = f"{stem}_images", 2
    while any(f"{name}/" in text for text in others):
        name, n = f"{stem}_images_{n}", n + 1
    return name


def _write_text(dst: Path, text: str) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".part")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    tmp.replace(dst)


def _check_paths(src: Path, dst: Path) -> None:
    if not src.is_file():
        raise FileNotFoundError(str(src))
    if dst.suffix.lower() != ".md":
        raise ConversionError(tr("内部错误：输出文件必须是 .md。", "Internal error: the output file must be .md.", "內部錯誤：輸出檔案必須是 .md。"))
    try:
        if dst.exists() and dst.samefile(src):
            raise ConversionError(tr("输出文件与源文件相同，已跳过以保护原文件。", "The output file is the same as the source file; skipped to protect the original.", "輸出檔案與來源檔案相同，已略過以保護原檔案。"))
    except OSError:
        pass


_DATA_URI_IMG = re.compile(r"!\[([^\]]*)\]\(data:image/([A-Za-z0-9.+-]+);base64,([^)\s]*)\)")
# Word / HTML 表格没有标题行时，MarkItDown 会加一行空表头；把第一行内容提上来当表头
_EMPTY_HEADER = re.compile(r"^(\|(?:[ \t]*\|)+)\n(\|(?:[ \t]*:?-+:?[ \t]*\|)+)\n(\|.*\|)$", re.M)


def fill_empty_table_headers(text: str) -> str:
    return _EMPTY_HEADER.sub(r"\3\n\2", text)


_OUR_IMAGE = re.compile(r"image\d+\.[A-Za-z0-9.+-]+")


def _save_images(text: str, dst: Path) -> str:
    """把内嵌在 Markdown 中的 data URI 图片存到“文件名_images”文件夹，改为相对路径引用。"""
    folder = images_dir_name(dst)
    count = 0
    # 重新转换时先删掉上次导出的图片（只删本程序命名的 imageN.xxx），图片变少时不留多余文件。
    # .md 还不存在时，同名文件夹不是本程序建的，里面的文件一个都不动
    old = dst.parent / folder
    if old.is_dir() and dst.exists():
        for p in old.iterdir():
            if p.is_file() and _OUR_IMAGE.fullmatch(p.name):
                p.unlink()

    def save(m: re.Match) -> str:
        nonlocal count
        alt, kind, data = m.groups()
        try:
            raw = base64.b64decode(data, validate=True)
        except ValueError:
            return tr(f"<!-- 图片{('：' + alt) if alt else ''}无法读取 -->", f"<!-- Image{(': ' + alt) if alt else ''} can't be read -->", f"<!-- 圖片{('：' + alt) if alt else ''}無法讀取 -->")
        ext = {"jpeg": "jpg", "svg+xml": "svg"}.get(kind.lower(), kind.lower())
        count += 1
        while (dst.parent / folder / f"image{count}.{ext}").exists():  # 不覆盖用户自己的同名文件
            count += 1
        name = f"image{count}.{ext}"
        (dst.parent / folder).mkdir(parents=True, exist_ok=True)
        (dst.parent / folder / name).write_bytes(raw)
        return f"![{alt}]({folder}/{name})"

    return _DATA_URI_IMG.sub(save, text)


def convert_markitdown(src: Path, dst: Path) -> str:
    result = _markitdown().convert_local(str(src), keep_data_uris=True)
    text = (result.markdown or "").strip()
    if not text:  # 要在存图片之前判断：存图片时会删掉上次的图片，失败时旧的 .md 还要用
        if src.suffix.lower() == ".pdf":
            raise ConversionError(tr("未能提取到文字，可能是扫描版（图片）PDF。请改用“高精度模式”。", "No text could be extracted; this may be a scanned (image) PDF. Use High Accuracy mode instead.", "未能擷取到文字，可能是掃描版（圖片）PDF。請改用「高精度模式」。"))
        raise ConversionError(tr("文件中没有可提取的内容。", "There is no content to extract in this file.", "檔案中沒有可擷取的內容。"))
    text = fill_empty_table_headers(_save_images(text, dst))
    if src.suffix.lower() == ".pdf":
        text = text.replace("\t", " ")
    _write_text(dst, text + "\n")
    return tr("快速模式", "Fast mode", "快速模式")


_LUA_FILTER = resource_root() / "packaging" / "pandoc_plain_images.lua"


def convert_pandoc(src: Path, dst: Path) -> str:
    exe = pandoc_path()
    if not exe:
        raise ConversionError(tr("找不到 Pandoc 组件，请改用 MarkItDown 引擎。", "Pandoc can't be found. Use the MarkItDown engine instead.", "找不到 Pandoc 元件，請改用 MarkItDown 引擎。"))
    dst.parent.mkdir(parents=True, exist_ok=True)
    img_dir = images_dir_name(dst)
    tmp_name = dst.name + ".part"
    args = [
        exe, str(src),
        "--from=docx", "--to=gfm", "--wrap=none",
        "--sandbox",  # 限制 Pandoc 只读写命令行中指定的文件
        f"--extract-media={img_dir}",
        "-o", tmp_name,
    ]
    if _LUA_FILTER.is_file():
        args.insert(2, f"--lua-filter={_LUA_FILTER}")
    proc = subprocess.run(
        args, cwd=str(dst.parent), stdin=subprocess.DEVNULL,
        capture_output=True, timeout=600,
    )
    tmp = dst.parent / tmp_name
    if proc.returncode != 0:
        tmp.unlink(missing_ok=True)
        err = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise ConversionError(tr("Pandoc 转换失败：", "Pandoc failed: ", "Pandoc 轉換失敗：") + (err[-1] if err else tr("返回码 ", "exit code ", "傳回碼 ") + str(proc.returncode)))
    # 保险起见，图片引用统一使用正斜杠
    text = tmp.read_text(encoding="utf-8")
    fixed = text.replace(img_dir + "\\", img_dir + "/")
    if fixed != text:
        tmp.write_text(fixed, encoding="utf-8", newline="\n")
    tmp.replace(dst)
    media = dst.parent / img_dir
    n = sum(1 for p in media.rglob("*") if p.is_file()) if media.is_dir() else 0
    return tr(f"Pandoc；导出 {n} 张图片", f"Pandoc; {n} images exported", f"Pandoc；輸出 {n} 張圖片") if n else "Pandoc"


def convert(src: Path, dst: Path, options: Options) -> str:
    """转换单个文件，成功时返回简短说明，失败时抛出异常。"""
    _check_paths(src, dst)
    ext = src.suffix.lower()
    if ext == ".pdf" and options.mode == MODE_HQ:
        from . import hq

        dst.parent.mkdir(parents=True, exist_ok=True)
        return hq.convert_pdf(src, dst, options.ocr_engine or hq.default_ocr_engine(), options.formulas,
                              images_dir_name(dst), options.vision_lang)
    if ext == ".docx" and options.word_engine == WORD_PANDOC:
        return convert_pandoc(src, dst)
    return convert_markitdown(src, dst)
