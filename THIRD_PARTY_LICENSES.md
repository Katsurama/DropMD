# 第三方组件与许可证

DropMD 本身以 MIT 许可证发布（见 LICENSE）。它使用了以下开源组件，感谢所有作者。

- Pandoc 3.9.0.2 — GPL-2.0-or-later — https://pandoc.org/ ，源代码：https://github.com/jgm/pandoc 。Pandoc 作为独立程序随附（位于程序内部的 pandoc 文件夹），DropMD 通过命令行调用它。
- markdown-it 15.0.2 — MIT — https://github.com/markdown-it/markdown-it （编辑器预览）
- KaTeX 0.18.9 — MIT — https://katex.org/ （编辑器预览中的数学公式，含字体文件）
- RapidOCR 内置的 PP-OCRv6 模型 — Apache-2.0 — 随 PyPI 包 rapidocr 分发。
- 高精度模式的识别模型不随程序分发，由用户同意后从模型作者的官方渠道下载，许可证见各模型页面。
