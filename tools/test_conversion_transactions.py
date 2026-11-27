"""Lightweight tests for conversion commits (no OCR models or Pandoc installed)."""

import ctypes
import errno
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from enum import Enum
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import quote

from dropmd import converters as conv, hq, netguard
from dropmd.errors import ConversionError


IMAGE = "![img](data:image/png;base64,aGk=)"


class ConversionTransactions(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.src, self.dst = self.root / "报告 1.html", self.root / "报告 1.md"
        self.src.write_text("source")
        self.part = self.dst.with_suffix(".md.part")

    def run_markitdown(self, markdown=IMAGE, inline_images=False):
        render = SimpleNamespace(convert_local=lambda *a, **k: SimpleNamespace(markdown=markdown))
        with patch.object(conv, "_markitdown", return_value=render):
            return conv.convert(self.src, self.dst, conv.Options(inline_images=inline_images))

    def exported_image(self):
        return self.root / re.search(r"!\[img\]\(([^)]+)\)", self.dst.read_text())[1]

    def assert_no_stage(self):
        self.assertEqual(list(self.root.glob(".dropmd-*")), [])

    def test_part_file_directory_and_symlink_are_not_temporary(self):
        self.part.write_text("keep file")
        self.run_markitdown()
        self.assertEqual(self.part.read_text(), "keep file")
        self.part.unlink()
        self.part.mkdir()
        (self.part / "user.txt").write_text("keep nested file")
        with patch.object(conv, "_markitdown", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                conv.convert(self.src, self.dst, conv.Options())
        self.assertEqual((self.part / "user.txt").read_text(), "keep nested file")
        self.part.rename(self.root / "user dir")
        self.part.symlink_to(self.root / "user dir", target_is_directory=True)
        self.run_markitdown()
        self.assertTrue(self.part.is_symlink())
        self.assertEqual((self.part / "user.txt").read_text(), "keep nested file")
        self.assert_no_stage()

    def test_inline_markitdown_keeps_data_uri_without_sidecar(self):
        self.run_markitdown(inline_images=True)
        self.assertEqual(self.dst.read_text(), IMAGE + "\n")
        self.assertEqual(set(self.root.iterdir()), {self.src, self.dst})

    def test_commit_failure_rolls_back_new_media_without_touching_old(self):
        self.run_markitdown()
        old = self.exported_image()
        old_md = self.dst.read_bytes()
        with patch.object(Path, "replace", side_effect=PermissionError("fail atomic replace")):
            with self.assertRaises(PermissionError):
                self.run_markitdown()
        self.assertEqual(self.dst.read_bytes(), old_md)
        self.assertEqual(old.read_bytes(), b"hi")
        self.assertEqual(list(self.root.glob("*_images*")), [old.parent])
        self.assert_no_stage()

    def test_stop_after_atomic_replace_keeps_new_media(self):
        self.run_markitdown()
        actual_replace = Path.replace

        def committed_then_stop(path, dst):
            actual_replace(path, dst)
            raise SystemExit(143)

        with patch.object(Path, "replace", new=committed_then_stop):
            with self.assertRaises(SystemExit):
                self.run_markitdown()
        self.assertEqual(self.exported_image().read_bytes(), b"hi")
        self.assert_no_stage()

    def test_missing_markdown_does_not_publish_staged_media(self):
        self.dst.write_text("old")

        def render_only_image(_src, _dst, media, _opts):
            media.mkdir()
            (media / "image1.png").touch()

        with patch.object(conv, "_render", side_effect=render_only_image):
            with self.assertRaises(FileNotFoundError):
                self.run_markitdown()
        self.assertEqual(self.dst.read_text(), "old")
        self.assertEqual(list(self.root.glob("*_images*")), [])
        self.assert_no_stage()

    def test_reconversion_never_removes_previously_committed_media(self):
        legacy = self.root / "报告_1_images"
        legacy.mkdir()
        (legacy / "image1.png").write_bytes(b"untagged")
        self.dst.write_text("![](报告_1_images/image1.png)")
        self.run_markitdown(IMAGE * 2)
        old = self.exported_image()
        user_image = old.parent / "image99.png"
        user_image.write_bytes(b"user")
        replaced = old.parent / "image2.png"
        replaced.write_bytes(b"user replacement")
        user_dir = old.parent / "my folder"
        user_dir.mkdir()
        self.run_markitdown()
        self.assertEqual(old.read_bytes(), b"hi")
        self.assertNotEqual(self.exported_image(), old)
        self.assertEqual(user_image.read_bytes(), b"user")
        self.assertEqual(replaced.read_bytes(), b"user replacement")
        self.assertTrue(user_dir.is_dir())
        self.assertEqual((legacy / "image1.png").read_bytes(), b"untagged")
        self.assertEqual(self.exported_image().read_bytes(), b"hi")

    def test_linked_existing_folder_is_neither_followed_nor_removed(self):
        user = self.root / "user"
        user.mkdir()
        (user / "image1.png").write_bytes(b"user")
        sidecar = self.root / "报告_1_images"
        sidecar.symlink_to(user, target_is_directory=True)
        self.dst.write_text("![](报告_1_images/image1.png)")
        self.run_markitdown()
        self.assertTrue(sidecar.is_symlink())
        self.assertEqual((user / "image1.png").read_bytes(), b"user")
        self.assertEqual(self.exported_image().parent.name, "报告_1_images_2")

    def test_sidecar_claim_at_commit_never_replaces_empty_user_dir(self):
        original_publish = conv._publish_media

        def claim_first(src, dst):
            dst.mkdir()
            original_publish(src, dst)

        self.dst.write_text("old")
        with patch.object(conv, "_publish_media", side_effect=claim_first):
            with self.assertRaises(FileExistsError):
                self.run_markitdown()
        self.assertTrue((self.root / "报告_1_images").is_dir())
        self.assertEqual(self.dst.read_text(), "old")
        self.assert_no_stage()

    def test_markdown_with_shared_assets_keeps_the_old_media(self):
        self.run_markitdown()
        old = self.exported_image()
        (self.root / "copy.MD").write_text(f"![]({quote(old.relative_to(self.root).as_posix())})")
        self.run_markitdown()
        self.assertEqual(old.read_bytes(), b"hi")
        self.assertNotEqual(self.exported_image(), old)

    def test_docling_partial_never_exports_or_commits(self):
        class Status(Enum):
            SUCCESS = "success"
            PARTIAL_SUCCESS = "partial_success"

        fake_modules = {
            "docling.datamodel.base_models": SimpleNamespace(ConversionStatus=Status),
            "docling_core.types.doc": SimpleNamespace(ImageRefMode=SimpleNamespace(REFERENCED=1)),
        }
        self.src = self.root / "old.pdf"
        self.src.write_bytes(b"dummy")
        self.dst.write_text("old markdown")
        old_media = self.root / "报告_1_images"
        old_media.mkdir()
        (old_media / "image_000000_ab12.png").write_bytes(b"old image")
        doc = SimpleNamespace(save_as_markdown=lambda *a, **k: self.fail("partial result exported"))
        fake = SimpleNamespace(convert=lambda *a, **k: SimpleNamespace(status=Status.PARTIAL_SUCCESS, document=doc))
        with patch.dict(sys.modules, fake_modules), patch.object(hq, "get_converter", return_value=fake):
            with self.assertRaisesRegex(ConversionError, "部分页面"):
                conv.convert(self.src, self.dst, conv.Options(mode=conv.MODE_HQ))
        self.assertEqual(self.dst.read_text(), "old markdown")
        self.assertEqual((old_media / "image_000000_ab12.png").read_bytes(), b"old image")
        self.assert_no_stage()

    def make_fake_pandoc(self):
        bindir = self.root / "bin"
        bindir.mkdir()
        fake = bindir / "pandoc"
        fake.write_text('''#!/usr/bin/env python3
from pathlib import Path
import os
import sys
import time
src = Path(sys.argv[1])
out = Path(sys.argv[-1])
media = next((s.split('=', 1)[1] for s in sys.argv if s.startswith('--extract-media=')), None)
if os.environ.get('DROPMD_INLINE_IMAGES') == '1':
    assert media is None
    out.write_text('![img](data:image/png;base64,aGk=)\\n')
    sys.exit(0)
assert media is not None
p = Path(media) / 'media' / 'image1.png'
p.parent.mkdir(parents=True)
p.write_bytes(src.read_bytes())
out.write_text(f'![img]({p.as_posix()})\\n')
if src.read_bytes() == b'stop':
    src.with_suffix('.ready').touch()
    time.sleep(30)
if src.read_bytes() == b'warn':
    print('could not extract media', file=sys.stderr)
    sys.exit(3 if '--fail-if-warnings' in sys.argv else 0)
''')
        fake.chmod(0o755)
        return fake

    def test_pandoc_interrupted_after_media_write_preserves_old_pair(self):
        fake = self.make_fake_pandoc()
        self.src = self.root / "existing.docx"
        self.src.write_bytes(b"old image")
        opts = conv.Options(word_engine=conv.WORD_PANDOC)
        with patch.object(conv, "pandoc_path", return_value=str(fake)):
            conv.convert(self.src, self.dst, opts)
        old = self.exported_image()
        old_md = self.dst.read_bytes()
        self.src.write_bytes(b"stop")
        self.part.mkdir()
        (self.part / "user").touch()
        request = {"jobs": [{"src": str(self.src), "dst": str(self.dst)}], "options": {"word_engine": "pandoc"}}
        env = {**os.environ, "PATH": f"{fake.parent}:{os.environ['PATH']}", "DROPMD_DATA_DIR": str(self.root / "data")}
        with subprocess.Popen([sys.executable, "-m", "dropmd", "--engine", "convert"], env=env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            child.stdin.write(json.dumps(request).encode())
            child.stdin.flush()
            child.stdin.close()
            child.stdin = None
            deadline = time.monotonic() + 5
            while child.poll() is None and not self.src.with_suffix(".ready").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            try:
                self.assertTrue(self.src.with_suffix(".ready").exists())
                os.killpg(child.pid, signal.SIGTERM)
                stdout, stderr = child.communicate(timeout=5)
                self.assertIn(b'"start"', stdout, stderr)
                self.assertNotIn(b'"result"', stdout)
                self.assertNotEqual(child.returncode, 0)
            finally:
                if child.poll() is None:
                    child.kill()
        self.assertEqual(self.dst.read_bytes(), old_md)
        self.assertEqual(old.read_bytes(), b"old image")
        self.assertTrue((self.part / "user").is_file())
        self.assert_no_stage()

    def test_pandoc_warnings_fail_and_inline_is_explicit(self):
        fake = self.make_fake_pandoc()
        self.src = self.root / "document.docx"
        self.src.write_bytes(b"warn")
        self.dst.write_text("old")
        options = conv.Options(word_engine=conv.WORD_PANDOC)
        with patch.object(conv, "pandoc_path", return_value=str(fake)), patch.dict(os.environ, {"DROPMD_INLINE_IMAGES": "1"}):
            with self.assertRaisesRegex(ConversionError, "could not extract media"):
                conv.convert(self.src, self.dst, options)
            self.assertEqual(self.dst.read_text(), "old")
            options.inline_images = True
            conv.convert(self.src, self.dst, options)
        self.assertEqual(self.dst.read_text(), IMAGE + "\n")
        self.assertEqual(list(self.root.glob("*_images*")), [])
        self.assert_no_stage()

    def test_publish_media_enotsup_fallback(self):
        def fail_enotsup(*_a):
            ctypes.set_errno(errno.ENOTSUP)
            return -1

        fake_libc = SimpleNamespace(renamex_np=fail_enotsup, renameat2=fail_enotsup)
        with patch.object(conv.ctypes, "CDLL", return_value=fake_libc):
            self.run_markitdown(IMAGE * 2)
            media_dir = self.exported_image().parent
            self.assertEqual((media_dir / "image1.png").read_bytes(), b"hi")
            self.assertEqual((media_dir / "image2.png").read_bytes(), b"hi")
            self.assert_no_stage()

            existing = self.root / "taken"
            existing.mkdir()
            existing_ino = existing.lstat().st_ino
            staged = self.root / "staged"
            staged.mkdir()
            (staged / "image1.png").write_bytes(b"new")
            with self.assertRaises(FileExistsError):
                conv._publish_media(staged, existing)
            self.assertEqual(existing.lstat().st_ino, existing_ino)
            self.assertEqual(list(existing.iterdir()), [])
            self.assertTrue((staged / "image1.png").is_file())

    def test_images_prefix_sanitizes_colon_and_caps_utf8_bytes(self):
        self.assertEqual(conv._images_prefix(Path("Q1:Q2.md")), "Q1_Q2_images")
        long_stem = "汉" * 83
        prefix = conv._images_prefix(Path(f"{long_stem}.md"))
        self.assertTrue(prefix.endswith("_images"))
        stem = prefix[:-len("_images")]
        self.assertLessEqual(len(stem.encode("utf-8")), 200)
        self.assertTrue(long_stem.startswith(stem))
        self.assertLessEqual(len(f"{prefix}_999".encode("utf-8")), 255)
        self.dst = self.root / f"{long_stem}.md"
        self.run_markitdown()
        self.assertEqual(self.exported_image().read_bytes(), b"hi")
        self.assert_no_stage()


class NetguardTests(unittest.TestCase):
    def setUp(self):
        saved = (
            socket.socket.connect,
            socket.socket.connect_ex,
            socket.socket.sendto,
            getattr(socket.socket, "sendmsg", None),
            socket.getaddrinfo,
            socket.gethostbyname,
            socket.gethostbyname_ex,
            socket.gethostbyaddr,
            socket.getnameinfo,
            netguard._installed,
        )

        def restore():
            (
                socket.socket.connect,
                socket.socket.connect_ex,
                socket.socket.sendto,
                orig_sendmsg,
                socket.getaddrinfo,
                socket.gethostbyname,
                socket.gethostbyname_ex,
                socket.gethostbyaddr,
                socket.getnameinfo,
                netguard._installed,
            ) = saved
            if orig_sendmsg is not None:
                socket.socket.sendmsg = orig_sendmsg

        self.addCleanup(restore)
        netguard.install()

    def test_blocks_remote_calls_and_allows_loopback(self):
        self.assertFalse(hasattr(netguard, "is_installed"))
        self.assertFalse(netguard._is_loopback_host(b"localhost\xff"))

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as tcp:
            with self.assertRaises(netguard.NetworkBlockedError):
                tcp.connect(("1.1.1.1", 80))

        with self.assertRaises(netguard.NetworkBlockedError):
            socket.getaddrinfo("example.com", 80)
        with self.assertRaises(netguard.NetworkBlockedError):
            socket.gethostbyname("example.com")
        with self.assertRaises(netguard.NetworkBlockedError):
            socket.gethostbyname(b"localhost\xff")
        with self.assertRaises(netguard.NetworkBlockedError):
            socket.gethostbyname_ex("example.com")
        with self.assertRaises(netguard.NetworkBlockedError):
            socket.gethostbyaddr("1.1.1.1")
        with self.assertRaises(netguard.NetworkBlockedError):
            socket.getnameinfo(("1.1.1.1", 80), 0)

        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            with self.assertRaises(netguard.NetworkBlockedError):
                udp.sendto(b"x", ("1.1.1.1", 53))
            if hasattr(socket.socket, "sendmsg"):
                with self.assertRaises(netguard.NetworkBlockedError):
                    udp.sendmsg([b"x"], [], 0, ("1.1.1.1", 53))

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
            srv.bind(("127.0.0.1", 0))
            port = srv.getsockname()[1]
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as cli:
                try:
                    cli.connect(("127.0.0.1", port))
                except netguard.NetworkBlockedError:
                    self.fail("loopback connect should not be blocked by netguard")
                except OSError:
                    pass


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "requires macOS Swift SDK")
class ConversionStop(unittest.TestCase):
    def test_stop_during_status_does_not_prompt_or_convert(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "source.pdf").touch()
            fake = root / "engine"
            fake.write_text('''#!/bin/sh
if [ "$2" = status ]; then
    touch "$DROPMD_TEST_STATE/ready"
    while [ -d "$DROPMD_TEST_STATE" ] && [ ! -e "$DROPMD_TEST_STATE/release" ]; do sleep .02; done
    printf '%s\\n' '{"pandoc":false,"ocr_engines":["rapidocr"],"default_ocr":"rapidocr","models_dir":"/unused","missing":[{"key":"x","title":"Model","source":"local","size_mb":1,"repo_id":"x","revision":"1","folder":"x","marker":"x"}]}'
else
    touch "$DROPMD_TEST_STATE/converted"
fi
''')
            fake.chmod(0o755)
            binary = root / "conversion_test"
            app = Path("macos/Sources/DropMD")
            subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", root / "ModuleCache",
                            "-o", binary, "tools/conversion_test/main.swift",
                            *(app / f"{name}.swift" for name in ("AppModel", "Planner", "Engine", "ModelDownloader"))],
                           check=True, timeout=120)
            try:
                subprocess.run([binary, root, "-mode", "hq", "-outputCustom", "NO"], check=True, timeout=12)
            finally:
                (root / "release").touch()  # Don't leave the fake status process waiting if the test itself fails.


if __name__ == "__main__":
    unittest.main(verbosity=2)
