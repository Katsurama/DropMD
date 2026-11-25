"""转换调度：根据文件类型和用户选择的模式调用相应的引擎。

- 快速模式：MarkItDown（Word / Excel / PowerPoint / HTML / CSV / 文字型 PDF），
  Word / PowerPoint 里的图片导出到单独文件夹并在 Markdown 中引用
- Word 可选 Pandoc：还原排版更好，图片同样导出
- 高精度模式（仅对 PDF 生效）：Docling + OCR（Apple Vision 或 RapidOCR），见 hq.py；
  也可以选 Xiaomi-OCR-0，见 xiaomi.py

原始文件只会以只读方式打开，绝不会被修改。
"""

from __future__ import annotations

import base64
import ctypes
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote

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
    on_page: object = None  # Xiaomi-OCR-0 每页要几十秒，用它报告进度
    inline_images: bool = False  # 快捷指令只返回单个 Markdown 文件


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


_UNSAFE_IN_LINK = re.compile(r"[\s#%?\[\]()<>\\]+")


def _images_prefix(dst: Path) -> str:
    return _UNSAFE_IN_LINK.sub("_", dst.stem) + "_images"


def _free_images_name(dst: Path) -> str:
    prefix = name = _images_prefix(dst)
    other_links = []
    for other in dst.parent.iterdir():
        if other != dst and other.suffix.lower() == ".md" and _images_prefix(other) == prefix and other.is_file():
            with suppress(OSError):
                other_links.append(unquote(other.read_text(encoding="utf-8", errors="ignore")))
    n = 2
    while os.path.lexists(dst.parent / name) or any(f"{name}/" in text for text in other_links):
        name, n = f"{prefix}_{n}", n + 1
    return name


def _publish_media(src: Path, dst: Path) -> None:
    # POSIX rename alone silently replaces an existing empty directory.
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        ok = libc.renamex_np(os.fsencode(src), os.fsencode(dst), ctypes.c_uint(0x4))  # RENAME_EXCL
    else:
        ok = libc.renameat2(-100, os.fsencode(src), -100, os.fsencode(dst), ctypes.c_uint(1))  # AT_FDCWD, RENAME_NOREPLACE
    if ok != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), str(dst))


def _entry_id(st: os.stat_result) -> list[int] | None:
    if stat.S_ISDIR(st.st_mode):
        return [st.st_dev, st.st_ino]
    if stat.S_ISREG(st.st_mode):
        return [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns]
    return None


def _remove_owned_media(folder: Path, entries: dict, root_id: list[int]) -> None:
    # Directory descriptors keep traversal in the verified tree, not a replacement symlink.
    def remove(parent, name, prefix, expected):
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        try:
            if _entry_id(os.fstat(fd)) != expected:
                return
            for child in os.listdir(fd):
                key = prefix + child
                owned = entries.get(key)
                with suppress(OSError):
                    if isinstance(owned, list) and len(owned) == 2:
                        remove(fd, child, key + "/", owned)
                    elif owned is not None and _entry_id(os.stat(child, dir_fd=fd, follow_symlinks=False)) == owned:
                        os.unlink(child, dir_fd=fd)
            if _entry_id(os.stat(name, dir_fd=parent, follow_symlinks=False)) == expected:
                os.rmdir(name, dir_fd=parent)   # Non-empty directories stay.
        finally:
            os.close(fd)

    remove(None, folder, "", root_id)


def _commit(tmp: Path, dst: Path, media: Path) -> None:
    if not stat.S_ISREG(tmp.lstat().st_mode) or media.is_symlink():
        raise ValueError("Unexpected entry in staged output")
    entries = {}
    if media.is_dir():
        text = tmp.read_text(encoding="utf-8")
        fixed = text.replace(media.name + "\\", media.name + "/")
        if fixed != text:
            tmp.write_text(fixed, encoding="utf-8")
        for p in media.rglob("*"):
            identity = _entry_id(p.lstat())
            if identity is None:
                raise ValueError("Unexpected entry in staged media")
            entries[p.relative_to(media).as_posix()] = identity
    if not any(len(v) == 4 for v in entries.values()):
        tmp.replace(dst)
        return

    # Old media can still be linked from other documents. Never reuse or delete it.
    published = dst.parent / media.name
    root_id = _entry_id(media.lstat())
    try:
        _publish_media(media, published)
        tmp.replace(dst)
    finally:
        # If rename committed the Markdown, it already references published images even if stopped now.
        if tmp.exists() and not media.exists():
            with suppress(OSError):
                _remove_owned_media(published, entries, root_id)


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


def _save_images(text: str, media: Path) -> str:
    """在暂存区导出 data URI 图片，并生成提交后的相对链接。"""
    count = 0

    def save(m: re.Match) -> str:
        nonlocal count
        alt, kind, data = m.groups()
        try:
            raw = base64.b64decode(data, validate=True)
        except ValueError:
            return tr(f"<!-- 图片{('：' + alt) if alt else ''}无法读取 -->", f"<!-- Image{(': ' + alt) if alt else ''} can't be read -->", f"<!-- 圖片{('：' + alt) if alt else ''}無法讀取 -->")
        ext = {"jpeg": "jpg", "svg+xml": "svg"}.get(kind.lower(), kind.lower())
        count += 1
        name = f"image{count}.{ext}"
        media.mkdir(exist_ok=True)
        (media / name).write_bytes(raw)
        return f"![{alt}]({media.name}/{name})"

    return _DATA_URI_IMG.sub(save, text)


def convert_markitdown(src: Path, dst: Path, media: Path, inline_images: bool) -> str:
    result = _markitdown().convert_local(str(src), keep_data_uris=True)
    text = (result.markdown or "").strip()
    if not text:
        if src.suffix.lower() == ".pdf":
            raise ConversionError(tr("未能提取到文字，可能是扫描版（图片）PDF。请改用“高精度模式”。", "No text could be extracted; this may be a scanned (image) PDF. Use High Accuracy mode instead.", "未能擷取到文字，可能是掃描版（圖片）PDF。請改用「高精度模式」。"))
        raise ConversionError(tr("文件中没有可提取的内容。", "There is no content to extract in this file.", "檔案中沒有可擷取的內容。"))
    text = fill_empty_table_headers(text if inline_images else _save_images(text, media))
    if src.suffix.lower() == ".pdf":
        text = text.replace("\t", " ")
    dst.write_text(text + "\n", encoding="utf-8")
    return tr("快速模式", "Fast mode", "快速模式")


_LUA_FILTER = resource_root() / "packaging" / "pandoc_plain_images.lua"


def convert_pandoc(src: Path, dst: Path, media: Path, inline_images: bool) -> str:
    exe = pandoc_path()
    if not exe:
        raise ConversionError(tr("找不到 Pandoc 组件，请改用 MarkItDown 引擎。", "Pandoc can't be found. Use the MarkItDown engine instead.", "找不到 Pandoc 元件，請改用 MarkItDown 引擎。"))
    args = [os.path.abspath(exe), str(src.absolute()), "--from=docx", "--to=gfm", "--wrap=none", "--sandbox"]
    if not inline_images:
        # Pandoc can report media extraction failures as warnings; never commit those links.
        args.extend([f"--extract-media={media.name}", "--fail-if-warnings"])
    if _LUA_FILTER.is_file():
        args.append(f"--lua-filter={_LUA_FILTER}")
    env = os.environ.copy()
    env.pop("DROPMD_INLINE_IMAGES", None)
    if inline_images:
        env["DROPMD_INLINE_IMAGES"] = "1"
    proc = subprocess.run(
        [*args, "-o", dst.name], cwd=dst.parent, stdin=subprocess.DEVNULL,
        capture_output=True, timeout=600, env=env,
    )
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise ConversionError(tr("Pandoc 转换失败：", "Pandoc failed: ", "Pandoc 轉換失敗：") + (err[-1] if err else tr("返回码 ", "exit code ", "傳回碼 ") + str(proc.returncode)))
    n = sum(1 for p in media.rglob("*") if p.is_file())
    return tr(f"Pandoc；导出 {n} 张图片", f"Pandoc; {n} images exported", f"Pandoc；輸出 {n} 張圖片") if n else "Pandoc"


def _render(src: Path, dst: Path, media: Path, options: Options) -> str:
    ext = src.suffix.lower()
    if ext == ".pdf" and options.mode == MODE_HQ:
        from . import hq

        if options.ocr_engine == hq.OCR_XIAOMI:
            from . import xiaomi

            return xiaomi.convert_pdf(src, dst, options.on_page)
        return hq.convert_pdf(src, dst, options.ocr_engine or hq.default_ocr_engine(), options.formulas,
                              media.name, options.vision_lang)
    if ext == ".docx" and options.word_engine == WORD_PANDOC:
        return convert_pandoc(src, dst, media, options.inline_images)
    return convert_markitdown(src, dst, media, options.inline_images)


def convert(src: Path, dst: Path, options: Options) -> str:
    """每个任务在同卷独占暂存区写完，最后才替换目标 Markdown。"""
    _check_paths(src, dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".dropmd-", dir=dst.parent))
    stage_id = _entry_id(stage.lstat())
    try:
        sidecars = not options.inline_images or (src.suffix.lower() == ".pdf" and options.mode == MODE_HQ)
        tmp, media = stage / "output.md", stage / (_free_images_name(dst) if sidecars else "unused")
        info = _render(src, tmp, media, options)
        _commit(tmp, dst, media)
        return info
    finally:
        with suppress(OSError):
            if _entry_id(stage.lstat()) == stage_id:
                shutil.rmtree(stage)
