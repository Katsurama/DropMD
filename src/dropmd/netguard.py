"""网络防护：在进程内阻止一切对外网络连接。

DropMD 的所有转换都在本机完成。为了从技术上保证这一点（而不仅仅是“承诺”），
程序启动时会替换 Python 的 socket 连接函数：除本机回环地址（127.0.0.1 / ::1）
以外的任何连接都会被拒绝。

唯一的例外是用户在弹窗中明确同意后下载高精度模式的识别模型，
此时代码会在 ``allow_network()`` 上下文中短暂放行。
"""

from __future__ import annotations

import contextlib
import ipaddress
import socket
import threading

_lock = threading.Lock()
_allow_depth = 0
_installed = False

_orig_connect = socket.socket.connect
_orig_connect_ex = socket.socket.connect_ex
_orig_getaddrinfo = socket.getaddrinfo


class NetworkBlockedError(ConnectionRefusedError):
    """在未经允许的情况下尝试联网时抛出。"""


def _is_allowed() -> bool:
    return _allow_depth > 0


def _is_loopback_host(host) -> bool:
    if host is None:
        return True
    if isinstance(host, bytes):
        host = host.decode("ascii", "ignore")
    host = str(host).strip("[]")
    if host in ("localhost", ""):
        return True
    try:
        return ipaddress.ip_address(host.split("%", 1)[0]).is_loopback
    except ValueError:
        return False


def _check(sock: socket.socket, address) -> None:
    if _is_allowed():
        return
    family = getattr(sock, "family", None)
    if family not in (socket.AF_INET, socket.AF_INET6):
        return  # UNIX 域套接字等本机进程间通信不受限制
    host = address[0] if isinstance(address, tuple) and address else address
    if not _is_loopback_host(host):
        raise NetworkBlockedError(f"已阻止联网尝试：{host}")


def _guarded_connect(self, address):
    _check(self, address)
    return _orig_connect(self, address)


def _guarded_connect_ex(self, address):
    _check(self, address)
    return _orig_connect_ex(self, address)


def _guarded_getaddrinfo(host, *args, **kwargs):
    if not _is_allowed() and not _is_loopback_host(host):
        raise NetworkBlockedError(f"已阻止域名解析：{host}")
    return _orig_getaddrinfo(host, *args, **kwargs)


def install() -> None:
    """安装网络防护（可重复调用）。"""
    global _installed
    with _lock:
        if _installed:
            return
        socket.socket.connect = _guarded_connect
        socket.socket.connect_ex = _guarded_connect_ex
        socket.getaddrinfo = _guarded_getaddrinfo
        _installed = True


def is_installed() -> bool:
    return _installed


@contextlib.contextmanager
def allow_network():
    """临时允许联网。仅用于用户同意后的模型下载。"""
    global _allow_depth
    with _lock:
        _allow_depth += 1
    try:
        yield
    finally:
        with _lock:
            _allow_depth -= 1
