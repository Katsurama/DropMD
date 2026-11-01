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


def _chain(exc: BaseException) -> list[BaseException]:
    out, e = [], exc
    while e is not None and len(out) < 8:
        out.append(e)
        e = e.__cause__ or e.__context__
    return out


def describe_download(exc: BaseException) -> str:
    """模型下载失败时给用户看的原因（会沿异常链查找真正的网络错误）。"""
    chain = _chain(exc)
    names = " ".join(type(e).__name__ for e in chain)
    text = " ".join(f"{type(e).__name__}: {e}" for e in chain)
    low = text.lower()
    status = None
    for e in chain:
        resp = getattr(e, "response", None)
        code = getattr(resp, "status_code", None)
        if isinstance(code, int):
            status = code
            break

    if isinstance(exc, InterruptedError):
        return tr("已取消下载。", "Download canceled.")
    if isinstance(exc, OSError) and getattr(exc, "errno", None) == errno.ENOSPC:
        return tr("磁盘空间不足，请清理空间后重试。", "Not enough disk space. Free up some space and try again.")
    if status in (401, 403):
        reason = tr(f"服务器拒绝访问（HTTP {status}）。可能是所在网络屏蔽了 huggingface.co。", f"The server refused access (HTTP {status}). Your network may block huggingface.co.")
    elif status == 429:
        reason = tr("请求过于频繁（HTTP 429），请稍后再试。", "Too many requests (HTTP 429). Please try again later.")
    elif status is not None and status >= 500:
        reason = tr(f"Hugging Face 服务器暂时出错（HTTP {status}），请稍后再试。", f"The Hugging Face server has a temporary problem (HTTP {status}). Please try again later.")
    elif status == 404:
        reason = tr("服务器上找不到模型文件（HTTP 404）。", "Model file not found on the server (HTTP 404).")
    elif "proxy" in low:
        reason = tr("代理连接失败。请检查代理设置（程序会使用系统代理，但不支持“自动代理配置 PAC”）。", "The proxy connection failed. Check your proxy settings (the system proxy is used, but automatic proxy configuration (PAC) isn't supported).")
    elif "ssl" in low or "certificate" in low:
        reason = tr("安全连接（SSL 证书）验证失败。可能是网络中有拦截 HTTPS 的代理或安全软件。", "The secure connection (SSL certificate) couldn't be verified. A proxy or security software on your network may be intercepting HTTPS.")
    elif "timeout" in low or "timed out" in low:
        reason = tr("连接超时。网络较慢或无法访问 huggingface.co。", "The connection timed out. The network is slow or can't reach huggingface.co.")
    elif ("nodename" in low or "name or service" in low or "getaddrinfo" in low
          or "name resolution" in low or "dns" in low):
        reason = tr("无法解析 huggingface.co 的地址（DNS 失败）。请检查网络连接。", "Can't look up the address of huggingface.co (DNS failed). Check your network connection.")
    elif ("connect" in low or "connection" in low or "network" in low
          or "LocalEntryNotFoundError" in names or "OfflineModeIsEnabled" in names):
        reason = tr("无法连接 huggingface.co。请确认网络正常，以及所在网络能访问 Hugging Face。", "Can't connect to huggingface.co. Make sure your network works and can reach Hugging Face.")
    elif isinstance(exc, PermissionError):
        reason = tr("没有权限写入模型文件夹。", "No permission to write to the models folder.")
    else:
        reason = tr("下载过程中出错。", "Something went wrong while downloading.")
    last = chain[-1]
    detail = f"{type(last).__name__}: {str(last).strip().splitlines()[0][:160]}" if str(last).strip() else type(last).__name__
    return reason + tr(f"\n（技术信息：{detail}）", f"\n(Technical details: {detail})")
