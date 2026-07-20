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


M4V = load_script("weclaw_davinci_m4v", "自动发送ClawBot_M4V文件.py")
MP4 = load_script("weclaw_davinci_mp4", "自动发送ClawBot_MP4视频.py")


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
        for module in (M4V, MP4):
            with self.subTest(mode=module.SEND_MODE):
                self.assertTrue(module.completed("Complete", 100))
                self.assertFalse(module.completed("Complete", 99))
                self.assertTrue(module.failed("Cancelled"))

    def test_send_claim_prevents_duplicates(self):
        for module in (M4V, MP4):
            with self.subTest(mode=module.SEND_MODE), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "output.mp4"
                source.write_bytes(b"video")

                with (
                    mock.patch.object(module, "SEND_STATE_DIR", str(Path(directory) / "state")),
                    mock.patch.object(module, "log"),
                ):
                    claim = module.claim_send(str(source))
                    self.assertIsNotNone(claim)
                    self.assertIsNone(module.claim_send(str(source)))
                    module.complete_send_claim(claim)
                    self.assertIsNone(module.claim_send(str(source)))

    def test_send_claim_rejects_completion_race(self):
        for module in (M4V, MP4):
            with self.subTest(mode=module.SEND_MODE), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "output.mp4"
                source.write_bytes(b"video")

                with (
                    mock.patch.object(module, "SEND_STATE_DIR", str(Path(directory) / "state")),
                    mock.patch.object(module, "log"),
                ):
                    first_claim = module.claim_send(str(source))
                    self.assertIsNotNone(first_claim)
                    create_claim_lock = module.create_claim_lock

                    def complete_then_create(lock_path, file_path):
                        module.complete_send_claim(first_claim)
                        create_claim_lock(lock_path, file_path)

                    with mock.patch.object(
                        module,
                        "create_claim_lock",
                        side_effect=complete_then_create,
                    ):
                        self.assertIsNone(module.claim_send(str(source)))

                    lock_path, sent_path = first_claim
                    self.assertFalse(Path(lock_path).exists())
                    self.assertTrue(Path(sent_path).exists())

    def test_rotates_large_log_and_removes_expired_send_markers(self):
        for module in (M4V, MP4):
            with self.subTest(mode=module.SEND_MODE), tempfile.TemporaryDirectory() as directory:
                log_path = Path(directory) / "postrender.log"
                state_dir = Path(directory) / "state"
                state_dir.mkdir()
                log_path.write_bytes(b"x" * 20)
                expired = state_dir / "expired.sent"
                current = state_dir / "current.sent"
                lock = state_dir / "current.lock"
                for path in (expired, current, lock):
                    path.write_text("state", encoding="utf-8")
                expired_time = 10
                os.utime(expired, (expired_time, expired_time))

                with (
                    mock.patch.object(module, "LOG_PATH", str(log_path)),
                    mock.patch.object(module, "LOG_MAX_BYTES", 10),
                    mock.patch.object(module, "SEND_STATE_DIR", str(state_dir)),
                ):
                    module.log("new entry")
                    module.cleanup_send_state()

                self.assertTrue(Path(str(log_path) + ".1").exists())
                self.assertIn("new entry", log_path.read_text(encoding="utf-8"))
                self.assertFalse(expired.exists())
                self.assertTrue(current.exists())
                self.assertTrue(lock.exists())

    def test_m4v_script_copies_output_with_m4v_name(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "output.mp4"
            source.write_bytes(b"video")

            with (
                mock.patch.object(M4V, "SEND_CACHE_DIR", str(Path(directory) / "cache")),
                mock.patch.object(M4V, "log"),
            ):
                send_path, send_name = M4V.m4v_send_file(str(source))

            self.assertEqual(send_name, "output.m4v")
            self.assertEqual(Path(send_path).suffix, ".m4v")
            self.assertEqual(Path(send_path).read_bytes(), b"video")

    def test_mp4_script_rejects_non_mp4_output(self):
        with self.assertRaisesRegex(RuntimeError, "只支持 .mp4"):
            MP4.mp4_video_file("/tmp/output.mov")

    def test_posts_current_weclaw_send_contract(self):
        for module in (M4V, MP4):
            with self.subTest(mode=module.SEND_MODE):
                capture = PostCapture()
                with (
                    mock.patch.object(module.urllib.request, "urlopen", capture),
                    mock.patch.object(module, "log"),
                ):
                    result = module.post_to_weclaw_send("/tmp/output.mp4", "output.mp4")

                self.assertEqual(result["status"], "sent")
                self.assertEqual(capture.timeout, 900)
                self.assertEqual(capture.request.full_url, "http://127.0.0.1:18790/send")
                self.assertEqual(
                    json.loads(capture.request.data.decode("utf-8")),
                    {"file_path": "/tmp/output.mp4", "file_name": "output.mp4"},
                )

    def test_reads_configured_size_limit_before_copying_or_sending(self):
        for module in (M4V, MP4):
            with self.subTest(mode=module.SEND_MODE), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "output.mp4"
                source.write_bytes(b"video")
                capture = PostCapture(b'{"ok":true,"max_send_bytes":4}')
                with mock.patch.object(module.urllib.request, "urlopen", capture):
                    max_send_bytes = module.current_max_send_bytes()

                self.assertEqual(max_send_bytes, 4)
                self.assertEqual(capture.timeout, 3)
                self.assertEqual(capture.request.full_url, "http://127.0.0.1:18790/health")
                with (
                    mock.patch.object(module, "log"),
                    mock.patch.object(module, "notify"),
                ):
                    self.assertTrue(module.send_file_too_large(str(source), max_send_bytes))

    def test_installer_copies_both_scripts_with_expected_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["HOME"] = directory
            subprocess.run(
                [str(ROOT / "scripts" / "install-davinci-plugin.sh")],
                check=True,
                capture_output=True,
                env=environment,
                text=True,
            )
            target = (
                Path(directory)
                / "Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver"
            )

            for name in ("自动发送ClawBot_M4V文件.py", "自动发送ClawBot_MP4视频.py"):
                installed = target / name
                self.assertEqual(installed.read_bytes(), (DELIVER_DIR / name).read_bytes())
                self.assertEqual(stat.S_IMODE(installed.stat().st_mode), 0o644)

            installed_version = target / ".weclaw-send-version"
            self.assertEqual(installed_version.read_text(encoding="utf-8"), "1.6.4\n")
            self.assertEqual(stat.S_IMODE(installed_version.stat().st_mode), 0o644)


if __name__ == "__main__":
    unittest.main()
