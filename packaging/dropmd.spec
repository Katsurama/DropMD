# -*- mode: python ; coding: utf-8 -*-
# PyInstaller 打包配置：把 Python 转换引擎打包为命令行程序 dist/dropmd-engine/，
# 再由 macos/build_app.sh 放进 DropMD.app，供 Swift 界面调用。
# 用法（在项目根目录）：
#   pyinstaller packaging/dropmd.spec --noconfirm
# 若 packaging/pandoc/ 下有 pandoc 可执行文件，会一并打包。

import os
import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_all, collect_data_files, copy_metadata, get_package_paths

ROOT = Path(SPECPATH).parent
IS_MAC = sys.platform == "darwin"
NAME = "dropmd-engine"

datas = [
    (str(ROOT / "packaging" / "samples"), "packaging/samples"),
    (str(ROOT / "packaging" / "pandoc_plain_images.lua"), "packaging"),
    (str(ROOT / "THIRD_PARTY_LICENSES.md"), "."),
    (str(ROOT / "LICENSE"), "."),
]
binaries = []
hiddenimports = []

pandoc_dir = ROOT / "packaging" / "pandoc"
if pandoc_dir.is_dir():
    for f in pandoc_dir.iterdir():
        binaries.append((str(f), "pandoc"))

freeze_list = ROOT / "build" / "requirements-frozen.txt"
if freeze_list.is_file():
    datas.append((str(freeze_list), "."))

# 这些包含有模型配置、字体、资源文件，或在运行时动态导入子模块
for pkg in [
    "markitdown",
    "magika",
    "docling",
    "docling_core",
    "docling_parse",
    "docling_ibm_models",
    "rapidocr",
]:
    d, b, h = collect_all(pkg)
    datas += d
    binaries += b
    hiddenimports += h

datas += collect_data_files("transformers", include_py_files=False)

# torchvision 0.29 起原生扩展改名为 _C_stable / image_stable，PyInstaller 自带的钩子仍按旧名 _C 查找，
# 导致扩展没有被打包（运行时报 “operator torchvision::nms does not exist”）。这里显式收集。
_tv_dir = Path(get_package_paths("torchvision")[1])
for _ext in ("*.so", "*.dylib", "*.pyd"):
    for _f in _tv_dir.glob(_ext):
        binaries.append((str(_f), "torchvision"))

# 运行时通过 importlib.metadata 检查版本的包
for pkg in [
    "markitdown", "magika", "docling", "docling-core", "docling-parse", "docling-ibm-models",
    "rapidocr", "onnxruntime", "ocrmac", "transformers", "tokenizers", "huggingface-hub", "safetensors", "torch",
    "torchvision", "tqdm", "regex", "requests", "packaging", "filelock", "numpy", "pyyaml",
    "pydantic", "pydantic-settings", "pillow", "accelerate", "mammoth", "openpyxl",
    "python-pptx", "pdfminer.six", "pandas", "beautifulsoup4", "markdownify",
]:
    try:
        datas += copy_metadata(pkg)
    except Exception:
        pass

excludes = [
    "tkinter", "matplotlib", "IPython", "jupyter", "notebook", "pytest",
    "PySide6", "shiboken6", "PyQt5", "PyQt6", "easyocr",
]
if IS_MAC:
    d, b, h = collect_all("ocrmac")
    datas += d
    binaries += b
    hiddenimports += h + ["Vision", "Quartz", "objc"]

a = Analysis(
    [str(ROOT / "packaging" / "run_dropmd.py")],
    pathex=[str(ROOT / "src")],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    excludes=excludes,
    noarchive=False,
    # transformers 在运行时扫描自身目录下的 .py 文件来发现模型类，
    # 因此除了字节码外还要附带源文件，否则会报 “Could not import module 'AutoImageProcessor'”
    module_collection_mode={"transformers": "pyz+py"},
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name=NAME,
    console=True,
    upx=False,
)
coll = COLLECT(exe, a.binaries, a.datas, name=NAME, upx=False)

