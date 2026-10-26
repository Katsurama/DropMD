"""路径相关的工具函数：应用数据目录、内置 Pandoc 的位置等。"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

APP_NAME = "DropMD"


def is_frozen() -> bool:
    return bool(getattr(sys, "frozen", False))


def resource_root() -> Path:
    """打包后为 PyInstaller 的资源目录，开发时为项目根目录。"""
    if is_frozen():
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
    return Path(__file__).resolve().parents[2]


def data_dir() -> Path:
    """存放识别模型等数据的目录（不会写入任何用户文档目录）。"""
    override = os.environ.get("DROPMD_DATA_DIR")
    if override:
        base = Path(override)
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support" / APP_NAME
    else:  # 仅用于在 Linux 上开发/测试引擎
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / APP_NAME
    base.mkdir(parents=True, exist_ok=True)
    return base


def models_dir() -> Path:
    d = data_dir() / "models"
    d.mkdir(parents=True, exist_ok=True)
    return d


def pandoc_path() -> str | None:
    """优先使用随程序附带的 Pandoc，其次使用系统中已安装的 Pandoc。"""
    bundled = resource_root() / "pandoc" / "pandoc"
    if bundled.is_file():
        return str(bundled)
    return shutil.which("pandoc")
