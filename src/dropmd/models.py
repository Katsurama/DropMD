"""高精度模式所需识别模型的清单与检查。

模型由 macOS 界面（ModelDownloader.swift）在用户同意后下载，引擎本身不联网。

模型来源：Hugging Face 上 Docling 官方账号 docling-project。
OCR 不需要下载：macOS 使用系统自带的 Apple Vision；RapidOCR 的 PP-OCRv6
多语言模型随 PyPI 安装包 rapidocr 一起分发，已打包在程序内。

版本固定为具体的提交号；大小由 tools/measure_model_sizes.py 实测（2026-10-12）。
"""

from __future__ import annotations

from dataclasses import dataclass

from .errors import tr
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
            "layout", tr("版面分析模型（Docling Heron）", "Layout analysis model (Docling Heron)", "版面分析模型（Docling Heron）"),
            "https://huggingface.co/docling-project/docling-layout-heron",
            size_mb=172,
            repo_id="docling-project/docling-layout-heron",
            revision="8f39ad3c0b4c58e9c2d2c84a38465abf757272d8",
            marker="docling-project--docling-layout-heron/config.json",
        ),
        Component(
            "table", tr("表格结构识别模型（TableFormer）", "Table structure model (TableFormer)", "表格結構辨識模型（TableFormer）"),
            "https://huggingface.co/docling-project/docling-models",
            size_mb=358,
            repo_id="docling-project/docling-models",
            revision="fc0f2d45e2218ea24bce5045f58a389aed16dc23",  # 标签 v2.3.0
            marker="docling-project--docling-models/model_artifacts/tableformer/accurate/tm_config.json",
        ),
        Component(
            "formula", tr("数学公式识别模型（CodeFormulaV2）", "Math formula model (CodeFormulaV2)", "數學公式辨識模型（CodeFormulaV2）"),
            "https://huggingface.co/docling-project/CodeFormulaV2",
            size_mb=640,
            repo_id="docling-project/CodeFormulaV2",
            revision="ecedbe111d15c2dc60bfd4a823cbe80127b58af4",
            marker="docling-project--CodeFormulaV2/config.json",
        ),
        Component(
            "xiaomi", tr("文档识别模型（Xiaomi-OCR-0）", "Document recognition model (Xiaomi-OCR-0)", "文件辨識模型（Xiaomi-OCR-0）"),
            "https://huggingface.co/xiaomi-research/Xiaomi-OCR-0",
            size_mb=1767,
            repo_id="xiaomi-research/Xiaomi-OCR-0",
            revision="bbd8cf8d21f256b3644b44cb860f3a7cecb93c30",
            marker="xiaomi-research--Xiaomi-OCR-0/config.json",
        ),
    ]
}


def required_components(formulas: bool, xiaomi: bool = False) -> list[str]:
    if xiaomi:
        return ["xiaomi"]  # 不经过 Docling，也不需要它的模型
    keys = ["layout", "table"]
    if formulas:
        keys.append("formula")
    return keys


def is_installed(key: str) -> bool:
    return (models_dir() / COMPONENTS[key].marker).is_file()


def missing_components(keys: list[str]) -> list[Component]:
    return [COMPONENTS[k] for k in keys if not is_installed(k)]

