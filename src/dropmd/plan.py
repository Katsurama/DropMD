"""收集输入文件并规划输出路径。"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

# 支持的扩展名及其显示名称
SUPPORTED_EXTS: dict[str, str] = {
    ".docx": "Word",
    ".xlsx": "Excel",
    ".pptx": "PowerPoint",
    ".html": "HTML",
    ".htm": "HTML",
    ".pdf": "PDF",
    ".csv": "CSV",
}


@dataclass(frozen=True)
class InputFile:
    path: Path
    # 指定输出文件夹时使用的相对路径（拖入文件夹时保留其子目录结构）
    rel: Path


@dataclass
class Job:
    src: Path
    dst: Path


def is_supported(path: Path) -> bool:
    name = path.name
    if name.startswith("~$") or name.startswith("."):
        return False  # Office 临时文件、隐藏文件
    return path.suffix.lower() in SUPPORTED_EXTS


def collect(paths: list[Path]) -> tuple[list[InputFile], int]:
    """展开文件夹，返回支持的文件列表和被忽略的文件数。"""
    found: list[InputFile] = []
    skipped = 0
    for p in paths:
        p = Path(p)
        if p.is_dir():
            base = p.parent
            for root, dirs, files in os.walk(p):
                dirs[:] = sorted(d for d in dirs if not d.startswith("."))
                for f in sorted(files):
                    fp = Path(root) / f
                    if is_supported(fp):
                        found.append(InputFile(fp, fp.relative_to(base)))
                    else:
                        skipped += 1
        elif p.is_file():
            if is_supported(p):
                found.append(InputFile(p, Path(p.name)))
            else:
                skipped += 1
    return found, skipped


def plan(files: list[InputFile], out_dir: Path | None) -> list[Job]:
    """为每个输入文件决定输出的 .md 路径。

    默认输出到源文件所在文件夹，文件名相同、扩展名为 .md。
    若同一批次中两个文件会得到同一个输出名（例如 a.docx 与 a.pdf），
    后者改为 ``a_pdf.md``，避免互相覆盖。
    """
    jobs: list[Job] = []
    used: set[str] = set()
    for f in files:
        if out_dir is None:
            dst = f.path.with_suffix(".md")
        else:
            dst = (out_dir / f.rel).with_suffix(".md")
        key = os.path.normcase(str(dst))
        if key in used:
            dst = dst.with_name(f"{f.path.stem}_{f.path.suffix.lstrip('.').lower()}.md")
            key = os.path.normcase(str(dst))
        used.add(key)
        jobs.append(Job(f.path, dst))
    return jobs
