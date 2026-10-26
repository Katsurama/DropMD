"""高精度模式所需识别模型的管理与下载。

这是 DropMD 中唯一会联网的代码。只有在用户于弹窗中明确同意后才会调用
``download()``，并且仅在 ``netguard.allow_network()`` 的范围内放行网络。

模型来源：Hugging Face 上 Docling 官方账号 docling-project。
OCR 不需要下载：macOS 使用系统自带的 Apple Vision；RapidOCR 的 PP-OCRv6
多语言模型随 PyPI 安装包 rapidocr 一起分发，已打包在程序内。

版本固定为具体的提交号；大小由 tools/measure_model_sizes.py 实测（2026-10-12）。
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import netguard
from .paths import models_dir


@dataclass(frozen=True)
class Component:
    key: str
    title: str          # 中文名称
    source: str         # 显示给用户的下载来源
    size_mb: int        # 近似下载大小（MB）
    repo_id: str = ""
    revision: str | None = None
    marker: str = ""    # 下载完成后应存在的文件（相对 models_dir）


COMPONENTS: dict[str, Component] = {
    c.key: c
    for c in [
        Component(
            "layout", "版面分析模型（Docling Heron）",
            "https://huggingface.co/docling-project/docling-layout-heron",
            size_mb=172,
            repo_id="docling-project/docling-layout-heron",
            revision="8f39ad3c0b4c58e9c2d2c84a38465abf757272d8",
            marker="docling-project--docling-layout-heron/config.json",
        ),
        Component(
            "table", "表格结构识别模型（TableFormer）",
            "https://huggingface.co/docling-project/docling-models",
            size_mb=358,
            repo_id="docling-project/docling-models",
            revision="fc0f2d45e2218ea24bce5045f58a389aed16dc23",  # 标签 v2.3.0
            marker="docling-project--docling-models/model_artifacts/tableformer/accurate/tm_config.json",
        ),
        Component(
            "formula", "数学公式识别模型（CodeFormulaV2）",
            "https://huggingface.co/docling-project/CodeFormulaV2",
            size_mb=640,
            repo_id="docling-project/CodeFormulaV2",
            revision="ecedbe111d15c2dc60bfd4a823cbe80127b58af4",
            marker="docling-project--CodeFormulaV2/config.json",
        ),
    ]
}


def required_components(formulas: bool) -> list[str]:
    keys = ["layout", "table"]
    if formulas:
        keys.append("formula")
    return keys


def is_installed(key: str) -> bool:
    return (models_dir() / COMPONENTS[key].marker).is_file()


def missing_components(keys: list[str]) -> list[Component]:
    return [COMPONENTS[k] for k in keys if not is_installed(k)]


def _system_proxies() -> dict[str, str]:
    """读取 macOS 系统代理设置（“系统设置 → 网络 → 代理”中手动填写的 HTTP/HTTPS/SOCKS 代理）。"""
    import urllib.request

    try:
        return {k: v for k, v in urllib.request.getproxies().items() if k in ("http", "https", "all", "no")}
    except Exception:  # noqa: BLE001
        return {}


def _download_hf(c: Component, dest: Path) -> None:
    import sys

    from huggingface_hub import snapshot_download

    proxies = _system_proxies()
    # 图形界面启动的程序拿不到终端里的代理环境变量，这里把系统代理显式传给下载组件
    for scheme, url in proxies.items():
        if scheme == "no":
            os.environ.setdefault("NO_PROXY", url)
        else:
            os.environ.setdefault(f"{scheme.upper()}_PROXY", url)
    print(f"下载 {c.repo_id}@{c.revision}，代理：{proxies or '无'}", file=sys.stderr, flush=True)
    snapshot_download(repo_id=c.repo_id, revision=c.revision, local_dir=dest)


def download(
    keys: list[str],
    on_progress: Callable[[int, int, str], None] | None = None,
    cancelled: Callable[[], bool] = lambda: False,
) -> None:
    """下载指定的模型组件。调用前必须已经取得用户同意。"""
    # Hugging Face 客户端的遥测默认关闭，这里再次显式关闭。
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"
    base = models_dir()
    todo = [COMPONENTS[k] for k in keys if not is_installed(k)]
    with netguard.allow_network():
        for i, c in enumerate(todo):
            if cancelled():
                raise InterruptedError("已取消下载")
            if on_progress:
                on_progress(i, len(todo), c.title)
            tmp = base / (c.repo_id.replace("/", "--") + ".partial")
            final = base / c.repo_id.replace("/", "--")
            _download_hf(c, tmp)
            if final.exists():
                shutil.rmtree(final)
            tmp.rename(final)
            if not is_installed(c.key):
                raise RuntimeError(f"{c.title} 下载后未找到预期文件，请重试。")
    if on_progress:
        on_progress(len(todo), len(todo), "")
