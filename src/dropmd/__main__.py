"""转换引擎入口（由 macOS 的 Swift 界面以子进程方式调用）。

命令行参数：

  --engine status|download|convert  JSON 引擎接口（macOS Swift 界面调用，见 engine.py）

  --selftest 输出文件夹 [--hq]   转换附带的样例文件并检查结果（构建流程用）
  --download-models [--with-formula]
                                  在命令行中下载高精度模型（运行此命令即视为同意下载）
"""

from __future__ import annotations

import multiprocessing
import os
import sys


def _prepare_environment() -> None:
    # 关闭各依赖库可能存在的遥测/统计，并避免任何隐式联网
    for k, v in {
        "HF_HUB_DISABLE_TELEMETRY": "1",
        "HF_HUB_DISABLE_XET": "1",
        "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
        "DO_NOT_TRACK": "1",
        "ANONYMIZED_TELEMETRY": "False",
        "TOKENIZERS_PARALLELISM": "false",
        "TRANSFORMERS_NO_ADVISORY_WARNINGS": "1",
    }.items():
        os.environ[k] = v
    # 让 Docling 使用本机模型目录
    from .paths import models_dir

    os.environ.setdefault("DOCLING_ARTIFACTS_PATH", str(models_dir()))


# 多语言样例中每一行都必须被识别出来（简体、日文、繁体、英文）——RapidOCR
MULTILANG_EXPECT = ["简体中文", "日本語", "繁體中文", "English"]


def _selftest(out_dir: str, hq: bool) -> int:
    import socket
    from pathlib import Path

    from . import netguard
    from .converters import MODE_FAST, MODE_HQ, WORD_PANDOC, Options, convert
    from .errors import describe
    from .paths import pandoc_path, resource_root

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    samples = resource_root() / "packaging" / "samples"
    lines: list[str] = []
    failed = 0

    def check(name, ok, detail=""):
        nonlocal failed
        failed += 0 if ok else 1
        lines.append(f"[{'OK' if ok else 'NG'}] {name} {detail}")

    # 1. 网络防护必须生效
    try:
        socket.create_connection(("example.com", 443), timeout=5)
        check("netguard", False, "联网未被阻止！")
    except netguard.NetworkBlockedError:
        check("netguard", True)
    except OSError as exc:
        check("netguard", False, repr(exc))

    def run(src: Path, opts: Options, dst_name: str, expect):
        dst = out / dst_name
        expects = [expect] if isinstance(expect, str) else list(expect)
        try:
            before = src.read_bytes()
            info = convert(src, dst, opts)
            text = dst.read_text(encoding="utf-8")
            missing = [e for e in expects if e not in text]
            ok = not missing and src.read_bytes() == before
            check(dst_name, ok, info if ok else f"未找到预期文字“{'、'.join(missing)}”\n{text[:500]}")
        except Exception as exc:  # noqa: BLE001
            check(dst_name, False, describe(exc))

    # 2. 高精度模式所需的库能否正常加载（检查打包是否完整，不需要模型）
    try:
        from . import hq as hqmod

        import docling.document_converter  # noqa: F401
        for eng in hqmod.available_ocr_engines():
            hqmod._vision_options() if eng == hqmod.OCR_VISION else hqmod._rapidocr_options()
        import rapidocr  # noqa: F401
        # Docling 版面模型（RT-DETR）在运行时才加载的 transformers 组件
        from transformers import AutoImageProcessor, AutoModelForObjectDetection  # noqa: F401
        from transformers.models.rt_detr import RTDetrImageProcessor  # noqa: F401
        check("hq_imports", True, ",".join(hqmod.available_ocr_engines()))
    except Exception as exc:  # noqa: BLE001
        chain, e = [], exc
        while e is not None and len(chain) < 6:
            chain.append(repr(e))
            e = e.__cause__ or e.__context__
        try:  # 直接导入以取得原始错误
            import importlib

            importlib.import_module("transformers.models.auto.image_processing_auto")
        except Exception as e2:  # noqa: BLE001
            chain.append("direct: " + repr(e2))
        check("hq_imports", False, " <- ".join(chain))

    fast = Options(mode=MODE_FAST)
    run(samples / "sample.docx", fast, "docx_markitdown.md", "你好")
    check("markitdown_images", any((out / "docx_markitdown_images").glob("*.png")))
    run(samples / "sample.xlsx", fast, "xlsx.md", "苹果")
    run(samples / "sample.pptx", fast, "pptx.md", "スライド")
    run(samples / "sample.html", fast, "html.md", "見出し")
    run(samples / "sample_text.pdf", fast, "pdf_fast.md", "Markdown")
    if pandoc_path():
        run(samples / "sample.docx", Options(word_engine=WORD_PANDOC), "docx_pandoc.md", "你好")
        img_dir = out / "docx_pandoc_images"
        check("pandoc_images", img_dir.is_dir() and any(img_dir.rglob("*.png")))
    else:
        check("pandoc", False, "未找到 Pandoc")
    if hq:
        from . import hq as hqmod

        # RapidOCR（默认）：同一页中的简体、日文、繁体、英文都必须识别正确
        o = Options(mode=MODE_HQ, ocr_engine=hqmod.OCR_RAPID)
        run(samples / "sample_text.pdf", o, "pdf_hq_rapidocr.md", "Markdown")
        run(samples / "sample_scanned.pdf", o, "pdf_scanned_rapidocr.md", "DropMD")
        run(samples / "sample_multilang.pdf", o, "pdf_multilang_rapidocr.md", MULTILANG_EXPECT)
        # Apple Vision：按所选主要语言识别该语言及英文
        if hqmod.OCR_VISION in hqmod.available_ocr_engines():
            for lang, expect in [("zh-Hans", ["简体中文", "English"]), ("ja-JP", ["日本語", "English"]),
                                 ("zh-Hant", ["繁體中文", "English"])]:
                o = Options(mode=MODE_HQ, ocr_engine=hqmod.OCR_VISION, vision_lang=lang)
                run(samples / "sample_multilang.pdf", o, f"pdf_multilang_vision_{lang}.md", expect)
            o = Options(mode=MODE_HQ, ocr_engine=hqmod.OCR_VISION)
            run(samples / "sample_scanned.pdf", o, "pdf_scanned_vision.md", "DropMD")

    lines.append(f"失败数：{failed}")
    report = "\n".join(lines)
    (out / "selftest_report.txt").write_text(report, encoding="utf-8")
    print(report)
    return 1 if failed else 0


def main() -> int:
    multiprocessing.freeze_support()
    _prepare_environment()

    from . import netguard

    netguard.install()

    args = sys.argv[1:]
    if args[:1] == ["--engine"]:
        from .engine import run as run_engine

        return run_engine(args[1:])
    if "--selftest" in args:
        i = args.index("--selftest")
        out = args[i + 1] if i + 1 < len(args) else "selftest_out"
        return _selftest(out, "--hq" in args)
    if "--download-models" in args:
        from . import models

        keys = models.required_components("--with-formula" in args)
        models.download(keys, lambda i, n, t: print(f"[{i}/{n}] {t}", flush=True))
        return 0

    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
