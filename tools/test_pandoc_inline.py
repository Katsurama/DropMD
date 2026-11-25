"""Check the Shortcuts engine request against a real DOCX and Pandoc."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
sample = root / "packaging/samples/sample.docx"
pandoc_dir = Path(sys.argv[1]).resolve().parent
with tempfile.TemporaryDirectory() as tmp:
    out = Path(tmp) / "out" / "sample.md"
    request = {"jobs": [{"src": str(sample), "dst": str(out)}],
               "options": {"mode": "fast", "word_engine": "pandoc", "inline_images": True}}
    raw = subprocess.check_output([sys.executable, "-m", "dropmd", "--engine", "convert"],
        input=json.dumps(request), text=True, cwd=root,
        env={**os.environ, "PYTHONPATH": str(root / "src"), "PYTHONDONTWRITEBYTECODE": "1",
             "PATH": str(pandoc_dir) + os.pathsep + os.environ.get("PATH", ""),
             "DROPMD_DATA_DIR": str(Path(tmp) / "data")})
    events = [json.loads(line) for line in raw.splitlines()]
    assert any(e.get("event") == "result" and e.get("ok") for e in events), events
    assert list(out.parent.iterdir()) == [out], "Shortcuts output should not need a media directory"
    media = re.findall(r"!\[[^\]]*\]\(data:image/png;base64,([A-Za-z0-9+/=]+)\)", out.read_text(encoding="utf-8"))
    assert len(media) == 1, "Expected one inline Markdown image"
    with zipfile.ZipFile(sample) as docx:
        assert base64.b64decode(media[0], validate=True) == docx.read("word/media/image1.png")
print("Pandoc inline image passed")
