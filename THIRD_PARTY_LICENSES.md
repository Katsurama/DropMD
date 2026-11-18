# Third-Party Components and Licenses

DropMD itself is released under the MIT License (see LICENSE). It uses the following open-source components. Thanks to all their authors.

- Pandoc 3.9.0.2 — GPL-2.0-or-later — https://pandoc.org/ , source code: https://github.com/jgm/pandoc . Pandoc is shipped as a separate program (in the pandoc folder inside the app) and DropMD runs it from the command line.
- markdown-it 15.0.2 — MIT — https://github.com/markdown-it/markdown-it (editor preview)
- KaTeX 0.18.9 — MIT — https://katex.org/ (math in the editor preview, including its font files)
- markdown-it-mark 4.0.0 — MIT — https://github.com/markdown-it/markdown-it-mark (==highlight== in the preview)
- markdown-it-footnote 4.0.0 — MIT — https://github.com/markdown-it/markdown-it-footnote (footnotes in the preview)
- MiSans, MiSans TC (Regular, Bold) — Xiaomi MiSans Font Intellectual Property License Agreement (free for commercial use; may only be embedded in software, not distributed on its own) — https://hyperos.mi.com/font/ . Used to display Chinese text. The fonts are downloaded from Xiaomi's official site at build time and placed in the app (in the fonts folder inside the app); the source repository does not contain the font files.
- PP-OCRv6 models bundled with RapidOCR — Apache-2.0 — distributed with the rapidocr package on PyPI.
- Xiaomi-OCR-0 — Apache-2.0 (full text: https://www.apache.org/licenses/LICENSE-2.0) — Copyright 2026 Xiaomi Corporation — https://github.com/xiaomi-research/Xiaomi-OCR-0 , model: https://huggingface.co/xiaomi-research/Xiaomi-OCR-0 , based on Qwen3.5-0.8B-Base (Apache-2.0, https://huggingface.co/Qwen/Qwen3.5-0.8B-Base), technical report: https://arxiv.org/abs/2609.36136 . An optional recognition model that is not shipped with the app; it is downloaded, unmodified, from the authors' Hugging Face account only after the user agrees. The prompt and formula conversion in `src/dropmd/xiaomi.py` are adapted, with changes, from that project's code (`postprocess/document.py`, Apache-2.0). DropMD is an independent project, not affiliated with or endorsed by Xiaomi; the name is used only to say which model is used.
- The models for high-accuracy mode are not shipped with the app. They are downloaded from the model authors' official sources only after the user agrees; see each model's page for its license.
