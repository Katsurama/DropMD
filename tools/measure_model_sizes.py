"""查询高精度模型在 Hugging Face 上的实际大小，并生成固定版本的文件清单（仅供维护者/构建流程使用）。

输出：
- 表格：每个仓库的提交号、文件数、大小（用于 models.py 中显示给用户的大小）
- JSON：src/dropmd/model_manifest.json 的内容（文件名、大小、SHA-256 或 Git 哈希），
  App 下载时据此校验，不需要在运行时查询 Hugging Face 的接口
"""

import json
import sys
from pathlib import Path

from huggingface_hub import HfApi

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from dropmd.models import COMPONENTS  # noqa: E402

api = HfApi()
manifest = {}
print("| 仓库 | 版本 | 提交 | 文件数 | 大小 (MB) |")
print("|---|---|---|---|---|")
for c in COMPONENTS.values():
    info = api.model_info(c.repo_id, revision=c.revision, files_metadata=True)
    files = []
    for s in info.siblings:
        if s.rfilename.startswith("."):
            continue
        entry = {"path": s.rfilename, "size": s.size or 0}
        if s.lfs:
            entry["sha256"] = s.lfs.sha256
            entry["size"] = s.lfs.size
        elif s.blob_id:
            entry["blob_id"] = s.blob_id
        files.append(entry)
    manifest[c.key] = {"repo_id": c.repo_id, "revision": info.sha, "files": files}
    total = sum(f["size"] for f in files)
    print(f"| {c.repo_id} | {c.revision[:12]} | {info.sha} | {len(files)} | {total / 1e6:.1f} |")

print()
print("MANIFEST_JSON_BEGIN")
print(json.dumps(manifest, ensure_ascii=False, indent=1))
print("MANIFEST_JSON_END")
