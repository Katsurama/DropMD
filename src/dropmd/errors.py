"""把各种异常转换成给用户看的说明（中文或英文）。"""

from __future__ import annotations

import errno
import os
import subprocess

# 界面语言：App 启动引擎时设置 DROPMD_LANG（zh、zh-Hant、en），给用户看的文字跟着用简体、繁体或英文
LANG = os.environ.get("DROPMD_LANG", "zh")
ENGLISH = LANG == "en"


def tr(zh: str, en: str, hant: str) -> str:
    return en if ENGLISH else hant if LANG == "zh-Hant" else zh


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
        return tr("转换过程中检测到联网尝试，已为保护隐私而阻止。请确认已下载高精度模型。", "A network connection was attempted during conversion and was blocked to protect your privacy. Make sure the high-accuracy models are downloaded.", "轉換過程中偵測到聯網嘗試，已為保護隱私而阻止。請確認已下載高精度模型。")
    if isinstance(exc, FileNotFoundError):
        return tr("找不到文件，可能已被移动或删除。", "File not found. It may have been moved or deleted.", "找不到檔案，可能已被移動或刪除。")
    if isinstance(exc, PermissionError):
        return tr("没有权限读取源文件或写入输出文件夹（文件可能正被其他程序打开）。", "No permission to read the file or write to the output folder (the file may be open in another app).", "沒有權限讀取來源檔案或寫入輸出資料夾（檔案可能正被其他程式開啟）。")
    if isinstance(exc, IsADirectoryError):
        return tr("路径是文件夹而不是文件。", "The path is a folder, not a file.", "路徑是資料夾而不是檔案。")
    if isinstance(exc, MemoryError):
        return tr("内存不足，文件可能过大。", "Not enough memory. The file may be too large.", "記憶體不足，檔案可能過大。")
    if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
        return tr("磁盘空间不足。", "Not enough disk space.", "磁碟空間不足。")
    if isinstance(exc, UnicodeDecodeError):
        return tr("无法识别文件的文字编码。", "Can't tell the file's text encoding.", "無法辨識檔案的文字編碼。")
    if isinstance(exc, subprocess.TimeoutExpired):
        return tr("转换超时，文件可能过大或已损坏。", "The conversion timed out. The file may be too large or damaged.", "轉換逾時，檔案可能過大或已損毀。")

    name = _name(exc)
    msg = str(exc)
    low = (name + " " + msg).lower()

    if "out of memory" in low:  # PyTorch 在 Mac GPU 上内存不够时报的是 RuntimeError
        return tr("内存不足，文件可能过大。", "Not enough memory. The file may be too large.", "記憶體不足，檔案可能過大。")
    if "password" in low or "encrypt" in low:
        return tr("文件已加密或设有密码，无法转换。请先解除密码保护。", "The file is encrypted or password-protected and can't be converted. Remove the password first.", "檔案已加密或設有密碼，無法轉換。請先解除密碼保護。")
    if name == "UnsupportedFormatException":
        return tr("不支持此文件格式，或文件内容与扩展名不符。", "This file format isn't supported, or the content doesn't match the extension.", "不支援此檔案格式，或檔案內容與副檔名不符。")
    if name == "MissingDependencyException":
        return tr("缺少处理该格式所需的组件。", "A component needed for this format is missing.", "缺少處理該格式所需的元件。")
    if name in ("BadZipFile", "BadZipfile") or "not a zip file" in low:
        return tr("文件已损坏或不是有效的 Office 文档（.docx/.xlsx/.pptx 本质上是 ZIP 压缩包）。", "The file is damaged or not a valid Office document (.docx/.xlsx/.pptx files are ZIP archives).", "檔案已損毀或不是有效的 Office 文件（.docx/.xlsx/.pptx 本質上是 ZIP 壓縮檔）。")
    # pdfminer（快速模式）、docling-parse（高精度）、PDFium（Xiaomi-OCR-0）各自的“读不了这个 PDF”
    if any(k in low for k in ("pdfsyntaxerror", "no /root object", "invalid pdf", "pseof", "could not load document", "failed to load document")):
        return tr("PDF 文件已损坏或格式无效。", "The PDF file is damaged or invalid.", "PDF 檔案已損毀或格式無效。")

    detail = msg.strip().splitlines()[0][:200] if msg.strip() else ""
    return tr(f"转换失败（{name}）", f"Conversion failed ({name})", f"轉換失敗（{name}）") + (tr("：", ": ", "：") + detail if detail else "")

