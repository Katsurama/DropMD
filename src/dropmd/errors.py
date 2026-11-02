"""把各种异常转换成给用户看的说明（中文或英文）。"""

from __future__ import annotations

import errno
import os
import subprocess

# 界面语言：App 是英文界面时启动引擎会设置 DROPMD_LANG=en，给用户看的文字改用英文
ENGLISH = os.environ.get("DROPMD_LANG") == "en"


def tr(zh: str, en: str) -> str:
    return en if ENGLISH else zh


class ConversionError(Exception):
    """带给用户看的说明的转换错误。"""


def _name(exc: BaseException) -> str:
    return type(exc).__name__


def describe(exc: BaseException) -> str:
    """返回适合展示给用户的错误原因。"""
    if isinstance(exc, ConversionError):
        return str(exc)

    from .netguard import NetworkBlockedError

    if isinstance(exc, NetworkBlockedError):
        return tr("转换过程中检测到联网尝试，已为保护隐私而阻止。请确认已下载高精度模型。", "A network connection was attempted during conversion and was blocked to protect your privacy. Make sure the high-accuracy models are downloaded.")
    if isinstance(exc, FileNotFoundError):
        return tr("找不到文件，可能已被移动或删除。", "File not found. It may have been moved or deleted.")
    if isinstance(exc, PermissionError):
        return tr("没有权限读取源文件或写入输出文件夹（文件可能正被其他程序打开）。", "No permission to read the file or write to the output folder (the file may be open in another app).")
    if isinstance(exc, IsADirectoryError):
        return tr("路径是文件夹而不是文件。", "The path is a folder, not a file.")
    if isinstance(exc, MemoryError):
        return tr("内存不足，文件可能过大。", "Not enough memory. The file may be too large.")
    if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
        return tr("磁盘空间不足。", "Not enough disk space.")
    if isinstance(exc, UnicodeDecodeError):
        return tr("无法识别文件的文字编码。", "Can't tell the file's text encoding.")
    if isinstance(exc, subprocess.TimeoutExpired):
        return tr("转换超时，文件可能过大或已损坏。", "The conversion timed out. The file may be too large or damaged.")

    name = _name(exc)
    msg = str(exc)
    low = (name + " " + msg).lower()

    if "password" in low or "encrypt" in low:
        return tr("文件已加密或设有密码，无法转换。请先解除密码保护。", "The file is encrypted or password-protected and can't be converted. Remove the password first.")
    if name == "UnsupportedFormatException":
        return tr("不支持此文件格式，或文件内容与扩展名不符。", "This file format isn't supported, or the content doesn't match the extension.")
    if name == "MissingDependencyException":
        return tr("缺少处理该格式所需的组件。", "A component needed for this format is missing.")
    if name in ("BadZipFile", "BadZipfile") or "not a zip file" in low:
        return tr("文件已损坏或不是有效的 Office 文档（.docx/.xlsx/.pptx 本质上是 ZIP 压缩包）。", "The file is damaged or not a valid Office document (.docx/.xlsx/.pptx files are ZIP archives).")
    if "pdfsyntaxerror" in low or "no /root object" in low or "invalid pdf" in low:
        return tr("PDF 文件已损坏或格式无效。", "The PDF file is damaged or invalid.")

    detail = msg.strip().splitlines()[0][:200] if msg.strip() else ""
    return tr(f"转换失败（{name}）", f"Conversion failed ({name})") + (tr("：", ": ") + detail if detail else "")

