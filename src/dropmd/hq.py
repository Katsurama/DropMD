"""高精度模式：使用 Docling（版面分析 + 表格识别 + OCR + 可选公式识别）转换 PDF。

OCR 引擎：
- "rapidocr"（默认）：RapidOCR + PP-OCRv6 多语言模型（随 PyPI 包 rapidocr 分发，已打包在程序内），
  能在同一页中混合识别简体中文、繁体中文、日文、英文等；
- "vision"：Apple Vision（macOS“实况文本”所用的系统文字识别引擎），系统自带，
  但一次只能以一种东亚语言为主，需要选择“主要语言”。

所有模型都从本机加载，不会访问网络。
"""

from __future__ import annotations

import logging
import sys
import threading
from pathlib import Path

from .models import missing_components, required_components
from .paths import models_dir

_log = logging.getLogger(__name__)
_lock = threading.Lock()
_cache: dict[tuple[str, bool, str], object] = {}

OCR_VISION = "vision"
OCR_RAPID = "rapidocr"

# Apple Vision 一次只能以一种东亚语言为主（构建机实测：中文优先时日文行丢失，
# 日文优先时简体中文识别错乱），因此由用户选择“主要语言”，再加上英文。
VISION_PRIMARY = ("zh-Hans", "zh-Hant", "ja-JP")


def default_ocr_engine() -> str:
    # RapidOCR 能在同一页中同时正确识别简体、繁体、日文、英文，作为默认引擎
    return OCR_RAPID


def available_ocr_engines() -> list[str]:
    return [OCR_RAPID, OCR_VISION] if sys.platform == "darwin" else [OCR_RAPID]


def _rapidocr_options():
    import rapidocr
    from docling.datamodel.pipeline_options import RapidOcrOptions

    d = Path(rapidocr.__file__).parent / "models"
    return RapidOcrOptions(
        backend="onnxruntime",
        lang=["ch"],  # PP-OCRv6 识别模型本身是多语言的，这里只用于选择模型
        det_model_path=str(d / "PP-OCRv6_det_small.onnx"),
        cls_model_path=str(d / "ch_ppocr_mobile_v2.0_cls_mobile.onnx"),
        rec_model_path=str(d / "PP-OCRv6_rec_small.onnx"),
    )


def _vision_options(primary: str = "zh-Hans"):
    from docling.datamodel.pipeline_options import OcrMacOptions

    if primary not in VISION_PRIMARY:
        primary = "zh-Hans"
    return OcrMacOptions(lang=[primary, "en-US"], recognition="accurate", framework="vision")


def _build_converter(ocr_engine: str, formulas: bool, vision_lang: str):
    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.pipeline_options import PdfPipelineOptions
    from docling.document_converter import DocumentConverter, PdfFormatOption

    opts = PdfPipelineOptions(artifacts_path=models_dir())
    opts.enable_remote_services = False  # 禁止任何远程服务
    opts.do_ocr = True
    opts.ocr_options = _vision_options(vision_lang) if ocr_engine == OCR_VISION else _rapidocr_options()
    opts.do_table_structure = True
    opts.table_structure_options.do_cell_matching = True
    opts.do_formula_enrichment = formulas
    opts.do_picture_classification = False
    opts.do_picture_description = False
    opts.generate_picture_images = True
    opts.images_scale = 2.0

    return DocumentConverter(
        format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=opts)}
    )


def get_converter(ocr_engine: str, formulas: bool, vision_lang: str = "zh-Hans"):
    if ocr_engine not in available_ocr_engines():
        ocr_engine = default_ocr_engine()
    key = (ocr_engine, formulas, vision_lang if ocr_engine == OCR_VISION else "")
    with _lock:
        if key not in _cache:
            missing = missing_components(required_components(formulas))
            if missing:
                from .errors import ConversionError

                raise ConversionError(
                    "高精度模型尚未下载：" + "、".join(c.title for c in missing)
                )
            _cache[key] = _build_converter(ocr_engine, formulas, vision_lang)
        return _cache[key]


def convert_pdf(src: Path, dst: Path, ocr_engine: str, formulas: bool, images_dir_name: str,
                vision_lang: str = "zh-Hans") -> str:
    """转换 PDF，Markdown 写入 dst，图片写入 dst 同级的 images_dir_name 文件夹。"""
    from docling_core.types.doc import ImageRefMode

    converter = get_converter(ocr_engine, formulas, vision_lang)
    result = converter.convert(str(src), raises_on_error=True)
    doc = result.document

    tmp = dst.with_name(dst.name + ".part")
    doc.save_as_markdown(
        tmp,
        artifacts_dir=Path(images_dir_name),
        image_mode=ImageRefMode.REFERENCED,
    )
    # 保险起见，图片引用统一使用 Markdown 通用的正斜杠
    text = tmp.read_text(encoding="utf-8")
    fixed = text.replace(images_dir_name + "\\", images_dir_name + "/")
    if fixed != text:
        tmp.write_text(fixed, encoding="utf-8")
    tmp.replace(dst)

    img_dir = dst.parent / images_dir_name
    if img_dir.is_dir() and not any(img_dir.iterdir()):
        img_dir.rmdir()

    n_pics = len(getattr(doc, "pictures", []) or [])
    return f"高精度模式；导出 {n_pics} 张图片" if n_pics else "高精度模式"
