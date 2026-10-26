"""把各种异常转换成中文说明。"""

from __future__ import annotations

import errno
import subprocess


class ConversionError(Exception):
    """带中文说明的转换错误。"""


def _name(exc: BaseException) -> str:
    return type(exc).__name__


def describe(exc: BaseException) -> str:
    """返回适合展示给用户的中文错误原因。"""
    if isinstance(exc, ConversionError):
        return str(exc)

    from .netguard import NetworkBlockedError

    if isinstance(exc, NetworkBlockedError):
        return "转换过程中检测到联网尝试，已为保护隐私而阻止。请确认已下载高精度模型。"
    if isinstance(exc, FileNotFoundError):
        return "找不到文件，可能已被移动或删除。"
    if isinstance(exc, PermissionError):
        return "没有权限读取源文件或写入输出文件夹（文件可能正被其他程序打开）。"
    if isinstance(exc, IsADirectoryError):
        return "路径是文件夹而不是文件。"
    if isinstance(exc, MemoryError):
        return "内存不足，文件可能过大。"
    if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
        return "磁盘空间不足。"
    if isinstance(exc, UnicodeDecodeError):
        return "无法识别文件的文字编码。"
    if isinstance(exc, subprocess.TimeoutExpired):
        return "转换超时，文件可能过大或已损坏。"

    name = _name(exc)
    msg = str(exc)
    low = (name + " " + msg).lower()

    if "password" in low or "encrypt" in low:
        return "文件已加密或设有密码，无法转换。请先解除密码保护。"
    if name == "UnsupportedFormatException":
        return "不支持此文件格式，或文件内容与扩展名不符。"
    if name == "MissingDependencyException":
        return "缺少处理该格式所需的组件。"
    if name in ("BadZipFile", "BadZipfile") or "not a zip file" in low:
        return "文件已损坏或不是有效的 Office 文档（.docx/.xlsx/.pptx 本质上是 ZIP 压缩包）。"
    if "pdfsyntaxerror" in low or "no /root object" in low or "invalid pdf" in low:
        return "PDF 文件已损坏或格式无效。"

    detail = msg.strip().splitlines()[0][:200] if msg.strip() else ""
    return f"转换失败（{name}）" + (f"：{detail}" if detail else "")


def _chain(exc: BaseException) -> list[BaseException]:
    out, e = [], exc
    while e is not None and len(out) < 8:
        out.append(e)
        e = e.__cause__ or e.__context__
    return out


def describe_download(exc: BaseException) -> str:
    """模型下载失败时的中文原因（会沿异常链查找真正的网络错误）。"""
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
        return "已取消下载。"
    if isinstance(exc, OSError) and getattr(exc, "errno", None) == errno.ENOSPC:
        return "磁盘空间不足，请清理空间后重试。"
    if status in (401, 403):
        reason = f"服务器拒绝访问（HTTP {status}）。可能是所在网络屏蔽了 huggingface.co。"
    elif status == 429:
        reason = "请求过于频繁（HTTP 429），请稍后再试。"
    elif status is not None and status >= 500:
        reason = f"Hugging Face 服务器暂时出错（HTTP {status}），请稍后再试。"
    elif status == 404:
        reason = "服务器上找不到模型文件（HTTP 404）。"
    elif "proxy" in low:
        reason = "代理连接失败。请检查代理设置（程序会使用系统代理，但不支持“自动代理配置 PAC”）。"
    elif "ssl" in low or "certificate" in low:
        reason = "安全连接（SSL 证书）验证失败。可能是网络中有拦截 HTTPS 的代理或安全软件。"
    elif "timeout" in low or "timed out" in low:
        reason = "连接超时。网络较慢或无法访问 huggingface.co。"
    elif ("nodename" in low or "name or service" in low or "getaddrinfo" in low
          or "name resolution" in low or "dns" in low):
        reason = "无法解析 huggingface.co 的地址（DNS 失败）。请检查网络连接。"
    elif ("connect" in low or "connection" in low or "network" in low
          or "LocalEntryNotFoundError" in names or "OfflineModeIsEnabled" in names):
        reason = "无法连接 huggingface.co。请确认网络正常，以及所在网络能访问 Hugging Face。"
    elif isinstance(exc, PermissionError):
        reason = "没有权限写入模型文件夹。"
    else:
        reason = "下载过程中出错。"
    last = chain[-1]
    detail = f"{type(last).__name__}: {str(last).strip().splitlines()[0][:160]}" if str(last).strip() else type(last).__name__
    return f"{reason}\n（技术信息：{detail}）"
