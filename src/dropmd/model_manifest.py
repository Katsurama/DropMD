"""高精度模型的固定版本文件清单（由 tools/measure_model_sizes.py 于 2026-10-12 从 Hugging Face 生成）。

App 下载模型时按此清单逐个下载文件，并用这里记录的哈希值校验，
不依赖运行时查询 Hugging Face 接口，也不需要信任服务器返回的校验值。
- sha256：大文件（Git LFS）的 SHA-256
- blob_id：小文件的 Git 文件哈希（SHA-1("blob <大小>\\0" + 内容)）
"""

FILES: dict[str, list[dict]] = {
    # docling-project/docling-layout-heron @ 8f39ad3c0b4c58e9c2d2c84a38465abf757272d8
    "layout": [
        {"path": "README.md", "size": 3219, "blob_id": "2c5b32c47fb9789ed49606988f58bc4741a731ab"},
        {"path": "config.json", "size": 3268, "blob_id": "98434d37ace2399b824d685b0795ab7a68e53dd2"},
        {"path": "docling_heron_400.png", "size": 96925, "blob_id": "d7a3a823e847c4b091ef0094bf9840129f167a62"},
        {"path": "model.safetensors", "size": 171658996,
         "sha256": "00333a43451945aaf89db8ca9c0a17e75d1537c17db60fdb91aa95f4c7929e0c"},
        {"path": "preprocessor_config.json", "size": 444, "blob_id": "fcdff16b42e5ebc51d28f59184490c6eff91a88b"},
    ],
    # docling-project/docling-models @ fc0f2d45e2218ea24bce5045f58a389aed16dc23（标签 v2.3.0）
    "table": [
        {"path": "README.md", "size": 3413, "blob_id": "887b06ffad8cc669c554c6bebd703ba7bd11a417"},
        {"path": "config.json", "size": 41, "blob_id": "4dc84c9101238bb955158144660155da99438490"},
        {"path": "model_artifacts/tableformer/accurate/tableformer_accurate.safetensors", "size": 212758388,
         "sha256": "2a7d6c924b3cd12fb99a09280ca9c33a89c5d60b93253617d2e088c1a40374d9"},
        {"path": "model_artifacts/tableformer/accurate/tm_config.json", "size": 7060,
         "blob_id": "5036aa114b9393f607440cb0f6cc54229b5b30e1"},
        {"path": "model_artifacts/tableformer/fast/tableformer_fast.safetensors", "size": 145453276,
         "sha256": "3119563aab5a7c96fda4d621119b63fd8806272b86c30936d15507616422f718"},
        {"path": "model_artifacts/tableformer/fast/tm_config.json", "size": 7060,
         "blob_id": "d02c5889d288b8baefd42e9e4da094f0cea07bbe"},
    ],
    # docling-project/CodeFormulaV2 @ ecedbe111d15c2dc60bfd4a823cbe80127b58af4
    "formula": [
        {"path": "README.md", "size": 1511, "blob_id": "70e88257bb1fb46b470fd1efbb163a9ac967c575"},
        {"path": "added_tokens.json", "size": 975, "blob_id": "c9d4d39e1c5e9247a895a404fdfd7eece995e3fc"},
        {"path": "chat_template.json", "size": 422, "blob_id": "acc2acf81c603bcdaec1b6806b592b44f130ce30"},
        {"path": "config.json", "size": 2638, "blob_id": "ac931358b512fd683deed6ce07d154d4947576a0"},
        {"path": "generation_config.json", "size": 169, "blob_id": "f34e02c8b42f0a0d3c6eac76e4f0e84819028516"},
        {"path": "model.safetensors", "size": 630993616,
         "sha256": "4b04e77af34c4e682a7ab1617628340d658f3c3dcd12456dd2a7fff805cf79d2"},
        {"path": "preprocessor_config.json", "size": 486, "blob_id": "893236748032d4bf033823d6a4a0d62b78b6bc0e"},
        {"path": "processor_config.json", "size": 68, "blob_id": "b3b1deadd0e6e18c2070fdb0c29074892ea58ffe"},
        {"path": "special_tokens_map.json", "size": 1071, "blob_id": "62eb0df50b48277dc8824b4f6117c1684794c6b8"},
        {"path": "tokenizer.json", "size": 7160031, "blob_id": "120f755869b80a9ad41aea3ba95acff83051886e"},
        {"path": "tokenizer_config.json", "size": 24952, "blob_id": "94ec944dbd1cf1eb40cfdec02d433ab3439bbc71"},
        {"path": "vocab.json", "size": 1612747, "blob_id": "3d43e13943cfbdbd6f1d50aad78c7ea229bb15a6"},
    ],
}
