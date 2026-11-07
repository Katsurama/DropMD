# 第三方组件与许可证

DropMD 本身以 MIT 许可证发布（见 LICENSE）。它使用了以下开源组件，感谢所有作者。

- Pandoc 3.9.0.2 — GPL-2.0-or-later — https://pandoc.org/ ，源代码：https://github.com/jgm/pandoc 。Pandoc 作为独立程序随附（位于程序内部的 pandoc 文件夹），DropMD 通过命令行调用它。
- markdown-it 15.0.2 — MIT — https://github.com/markdown-it/markdown-it （编辑器预览）
- KaTeX 0.18.9 — MIT — https://katex.org/ （编辑器预览中的数学公式，含字体文件）
- markdown-it-mark 4.0.0 — MIT — https://github.com/markdown-it/markdown-it-mark （预览中的 ==高亮==）
- markdown-it-footnote 4.0.0 — MIT — https://github.com/markdown-it/markdown-it-footnote （预览中的脚注）
- MiSans、MiSans TC（正文、粗体）— 小米 MiSans 字体知识产权许可协议（免费商用；只能随软件嵌入使用，不得单独分发）— https://hyperos.mi.com/font/ 。中文显示用的字体，构建时从小米官网下载放进程序（位于程序内部的 fonts 文件夹），源码仓库中不包含字体文件。
- RapidOCR 内置的 PP-OCRv6 模型 — Apache-2.0 — 随 PyPI 包 rapidocr 分发。
- Xiaomi-OCR-0 — Apache-2.0（全文：https://www.apache.org/licenses/LICENSE-2.0）— Copyright 2026 Xiaomi Corporation — https://github.com/xiaomi-research/Xiaomi-OCR-0 ，模型：https://huggingface.co/xiaomi-research/Xiaomi-OCR-0 ，基于 Qwen3.5-0.8B-Base（Apache-2.0，https://huggingface.co/Qwen/Qwen3.5-0.8B-Base），技术报告：https://arxiv.org/abs/2609.36136 。可选的识别模型，不随程序分发，用户同意后从作者的 Hugging Face 账号下载，文件未经修改。`src/dropmd/xiaomi.py` 里的提示语和公式写法转换参考了该项目的代码（`postprocess/document.py`，Apache-2.0），并作了修改。DropMD 是独立项目，与小米没有关联，也未获其背书；名称仅用于说明使用的是哪个模型。
- 高精度模式的识别模型不随程序分发，由用户同意后从模型作者的官方渠道下载，许可证见各模型页面。
