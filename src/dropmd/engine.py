"""供 macOS Swift 界面调用的命令行引擎。

协议：标准输出只输出 JSON（每行一个对象），日志等其他输出一律重定向到标准错误。

  dropmd-engine --engine status [--formula]
      → {"version", "pandoc", "ocr_engines", "default_ocr", "models_dir",
         "missing": [{"key","title","source","size_mb","repo_id","revision","folder","marker"}]}
      macOS 界面用这些信息通过系统网络（URLSession）自行下载模型。

  dropmd-engine --engine download --keys layout,table[,formula]
      （仅在用户于界面中同意后调用）
      → {"event":"progress","i","n","title"} ... {"event":"done","ok",["error"]}

  dropmd-engine --engine convert   （从标准输入读取一个 JSON 对象）
      输入：{"jobs":[{"src","dst"}], "options":{"mode","word_engine","ocr_engine","vision_lang","formulas"}}
      → {"event":"start","index"} / {"event":"result","index","ok","info"} ... {"event":"finished"}

取消：界面直接结束本进程即可。输出先写入 .part 临时文件，不会留下半个 .md。
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


class _Out:
    def __init__(self):
        # 保存真正的标准输出，然后把文件描述符 1 指向标准错误，
        # 这样任何库（包括原生代码）的打印都不会混入 JSON。
        self._f = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
        sys.stdout.flush()
        os.dup2(2, 1)
        sys.stdout = sys.stderr

    def send(self, obj: dict) -> None:
        self._f.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self._f.flush()


def _status(out: _Out, args: list[str]) -> int:
    from . import __version__, hq, models
    from .model_manifest import FILES
    from .paths import models_dir, pandoc_path

    keys = models.required_components("--formula" in args)
    out.send({
        "version": __version__,
        "pandoc": bool(pandoc_path()),
        "ocr_engines": hq.available_ocr_engines(),
        "default_ocr": hq.default_ocr_engine(),
        "models_dir": str(models_dir()),
        "missing": [
            {"key": c.key, "title": c.title, "source": c.source, "size_mb": c.size_mb,
             "repo_id": c.repo_id, "revision": c.revision or "main",
             "folder": c.repo_id.replace("/", "--"), "marker": c.marker,
             "files": FILES.get(c.key, [])}
            for c in models.missing_components(keys)
        ],
    })
    return 0


def _download(out: _Out, args: list[str]) -> int:
    import traceback

    from . import models
    from .errors import describe_download

    keys: list[str] = []
    if "--keys" in args:
        i = args.index("--keys")
        keys = [k for k in (args[i + 1] if i + 1 < len(args) else "").split(",") if k]
    keys = [k for k in keys if k in models.COMPONENTS]
    try:
        models.download(
            keys,
            lambda i, n, t: out.send({"event": "progress", "i": i, "n": n, "title": t}),
        )
        out.send({"event": "done", "ok": True})
        return 0
    except Exception as exc:  # noqa: BLE001
        print("模型下载失败：", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        out.send({"event": "done", "ok": False, "error": describe_download(exc)})
        return 1


def _convert(out: _Out) -> int:
    from .converters import Options, convert
    from .errors import describe

    req = json.loads(sys.stdin.read() or "{}")
    o = req.get("options", {})
    options = Options(
        mode=o.get("mode", "fast"),
        word_engine=o.get("word_engine", "markitdown"),
        ocr_engine=o.get("ocr_engine", ""),
        vision_lang=o.get("vision_lang", "zh-Hans"),
        formulas=bool(o.get("formulas", False)),
    )
    for i, job in enumerate(req.get("jobs", [])):
        out.send({"event": "start", "index": i})
        try:
            info = convert(Path(job["src"]), Path(job["dst"]), options)
            out.send({"event": "result", "index": i, "ok": True, "info": info})
        except Exception as exc:  # noqa: BLE001 — 任何错误都以中文反馈
            out.send({"event": "result", "index": i, "ok": False, "info": describe(exc)})
    out.send({"event": "finished"})
    return 0


def run(args: list[str]) -> int:
    import datetime

    out = _Out()
    cmd = args[0] if args else ""
    print(f"===== {datetime.datetime.now():%Y-%m-%d %H:%M:%S} dropmd-engine {' '.join(args)}", file=sys.stderr, flush=True)
    if cmd == "status":
        return _status(out, args[1:])
    if cmd == "download":
        return _download(out, args[1:])
    if cmd == "convert":
        return _convert(out)
    out.send({"error": f"未知命令：{cmd}"})
    return 2
