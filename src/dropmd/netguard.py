"""网络防护：在进程内阻止一切对外网络连接。

DropMD 的所有转换都在本机完成。为了从技术上保证这一点（而不仅仅是“承诺”），
程序启动时会替换 Python 的 socket 连接函数：除本机回环地址（127.0.0.1 / ::1）
以外的任何连接都会被拒绝。

高精度模式的识别模型由 macOS 界面在用户同意后下载，引擎里没有任何放行联网的代码。
"""

from __future__ import annotations

import ipaddress
import socket
import threading

_lock = threading.Lock()
_installed = False

_orig_connect = socket.socket.connect
_orig_connect_ex = socket.socket.connect_ex
_orig_sendto = socket.socket.sendto
_orig_sendmsg = getattr(socket.socket, "sendmsg", None)
_orig_getaddrinfo = socket.getaddrinfo
_orig_gethostbyname = socket.gethostbyname
_orig_gethostbyname_ex = socket.gethostbyname_ex
_orig_gethostbyaddr = socket.gethostbyaddr
_orig_getnameinfo = socket.getnameinfo


class NetworkBlockedError(ConnectionRefusedError):
    """在未经允许的情况下尝试联网时抛出。"""


def _is_loopback_host(host) -> bool:
    if host is None:
        return True
    if isinstance(host, (bytes, bytearray)):
        try:
            host = host.decode("ascii")
        except UnicodeDecodeError:
            # 忽略解码错误会把非法字节剔除成看似回环的地址，必须直接拒绝
            return False
    host = str(host).strip("[]")
    if host in ("localhost", ""):
        return True
    try:
        return ipaddress.ip_address(host.split("%", 1)[0]).is_loopback
    except ValueError:
        return False


def _check(sock: socket.socket, address) -> None:
    family = getattr(sock, "family", None)
    if family not in (socket.AF_INET, socket.AF_INET6):
        return  # UNIX 域套接字等本机进程间通信不受限制
    host = address[0] if isinstance(address, tuple) and address else address
    if not _is_loopback_host(host):
        raise NetworkBlockedError(f"已阻止联网尝试：{host}")


def _check_host(host) -> None:
    if not _is_loopback_host(host):
        raise NetworkBlockedError(f"已阻止域名解析：{host}")


def _guarded_connect(self, address):
    _check(self, address)
    return _orig_connect(self, address)


def _guarded_connect_ex(self, address):
    _check(self, address)
    return _orig_connect_ex(self, address)


def _guarded_sendto(self, *args, **kwargs):
    if len(args) >= 2:
        _check(self, args[-1])
    elif "address" in kwargs:
        _check(self, kwargs["address"])
    return _orig_sendto(self, *args, **kwargs)


def _guarded_sendmsg(self, buffers, ancdata=(), flags=0, address=None):
    if address is not None:
        _check(self, address)
    return _orig_sendmsg(self, buffers, ancdata, flags, address)


def _guarded_getaddrinfo(host, *args, **kwargs):
    _check_host(host)
    return _orig_getaddrinfo(host, *args, **kwargs)


def _guarded_gethostbyname(host):
    _check_host(host)
    return _orig_gethostbyname(host)


def _guarded_gethostbyname_ex(host):
    _check_host(host)
    return _orig_gethostbyname_ex(host)


def _guarded_gethostbyaddr(ip):
    _check_host(ip)
    return _orig_gethostbyaddr(ip)


def _guarded_getnameinfo(sockaddr, flags):
    host = sockaddr[0] if isinstance(sockaddr, tuple) and sockaddr else sockaddr
    _check_host(host)
    return _orig_getnameinfo(sockaddr, flags)


def install() -> None:
    """安装网络防护（可重复调用）。"""
    global _installed
    with _lock:
        if _installed:
            return
        socket.socket.connect = _guarded_connect
        socket.socket.connect_ex = _guarded_connect_ex
        socket.socket.sendto = _guarded_sendto
        if _orig_sendmsg is not None:
            socket.socket.sendmsg = _guarded_sendmsg
        socket.getaddrinfo = _guarded_getaddrinfo
        socket.gethostbyname = _guarded_gethostbyname
        socket.gethostbyname_ex = _guarded_gethostbyname_ex
        socket.gethostbyaddr = _guarded_gethostbyaddr
        socket.getnameinfo = _guarded_getnameinfo
        _installed = True

