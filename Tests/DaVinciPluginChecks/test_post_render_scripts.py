import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
DELIVER_DIR = ROOT / "davinci-resolve" / "Deliver"


def load_script(module_name, file_name):
    spec = importlib.util.spec_from_file_location(module_name, DELIVER_DIR / file_name)
    if spec is None or spec.loader is None:
        raise RuntimeError("无法加载 {}".format(file_name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PYTHON = load_script("weclaw_send_python", "WeClawSend_Python.py")


class FakeResponse:
    def __init__(self, body=b'{"ok":true,"status":"sent"}'):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self):
        return self.body


class PostCapture:
    def __init__(self, response_body=b'{"ok":true,"status":"sent"}'):
        self.request = None
        self.timeout = None
        self.response_body = response_body

    def __call__(self, request, timeout):
        self.request = request
        self.timeout = timeout
        return FakeResponse(self.response_body)


class PostRenderScriptTests(unittest.TestCase):
    def test_completion_states(self):
        self.assertTrue(PYTHON.completed("Complete", 100))
        self.assertFalse(PYTHON.completed("Complete", 99))
        self.assertTrue(PYTHON.failed("Cancelled"))

    def test_send_claim_prevents_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "output.mp4"
            source.write_bytes(b"video")

            with (
                mock.patch.object(PYTHON, "SEND_STATE_DIR", str(Path(directory) / "state")),
                mock.patch.object(PYTHON, "log"),
            ):
                claim = PYTHON.claim_send(str(source))
                self.assertIsNotNone(claim)
                self.assertIsNone(PYTHON.claim_send(str(source)))
                PYTHON.complete_send_claim(claim)
                self.assertIsNone(PYTHON.claim_send(str(source)))

    def test_posts_current_weclaw_send_contract(self):
        capture = PostCapture()
        with (
            mock.patch.object(PYTHON.urllib.request, "urlopen", capture),
            mock.patch.object(PYTHON, "log"),
        ):
            result = PYTHON.post_to_weclaw_send("/tmp/output.mp4", "output.mp4")

        self.assertEqual(result["status"], "sent")
        self.assertEqual(capture.timeout, 900)
        self.assertEqual(capture.request.full_url, "http://127.0.0.1:18790/send")
        self.assertEqual(
            json.loads(capture.request.data.decode("utf-8")),
            {"file_path": "/tmp/output.mp4", "file_name": "output.mp4"},
        )

    def test_reads_configured_size_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "output.mp4"
            source.write_bytes(b"video")
            capture = PostCapture(b'{"ok":true,"max_send_bytes":4}')
            with mock.patch.object(PYTHON.urllib.request, "urlopen", capture):
                max_send_bytes = PYTHON.current_max_send_bytes()

            self.assertEqual(max_send_bytes, 4)
            with (
                mock.patch.object(PYTHON, "log"),
                mock.patch.object(PYTHON, "notify"),
            ):
                self.assertTrue(PYTHON.send_file_too_large(str(source), max_send_bytes))

    def test_lua_script_exists_and_mentions_curl(self):
        lua = (DELIVER_DIR / "WeClawSend_Lua.lua").read_text(encoding="utf-8")
        self.assertIn("/usr/bin/curl", lua)
        self.assertIn("127.0.0.1:18790", lua)
        self.assertNotIn("python3", lua.lower())

    def test_installer_both_mode_and_legacy_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["HOME"] = directory
            target = (
                Path(directory)
                / "Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver"
            )
            target.mkdir(parents=True)
            for legacy in (
                "WeClawSend.lua",
                "weclaw_postrender_send.py",
                "自动发送ClawBot_M4V文件.py",
                "自动发送ClawBot_MP4视频.lua",
            ):
                (target / legacy).write_text("legacy", encoding="utf-8")

            subprocess.run(
                [str(ROOT / "scripts" / "install-davinci-plugin.sh"), "both"],
                check=True,
                capture_output=True,
                env=environment,
                text=True,
            )

            for name in ("WeClawSend_Lua.lua", "WeClawSend_Python.py"):
                installed = target / name
                self.assertEqual(installed.read_bytes(), (DELIVER_DIR / name).read_bytes())
                self.assertEqual(stat.S_IMODE(installed.stat().st_mode), 0o644)

            for legacy in (
                "WeClawSend.lua",
                "weclaw_postrender_send.py",
                "自动发送ClawBot_M4V文件.py",
                "自动发送ClawBot_MP4视频.lua",
            ):
                self.assertFalse((target / legacy).exists())

    def test_installer_lua_only(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["HOME"] = directory
            target = (
                Path(directory)
                / "Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver"
            )
            subprocess.run(
                [str(ROOT / "scripts" / "install-davinci-plugin.sh"), "lua"],
                check=True,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertTrue((target / "WeClawSend_Lua.lua").exists())
            self.assertFalse((target / "WeClawSend_Python.py").exists())


if __name__ == "__main__":
    unittest.main()
