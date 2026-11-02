import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import subprocess
import threading
import unittest

BINARY = Path(__file__).resolve().parents[2] / '.build/debug/weclaw'


class Handler(BaseHTTPRequestHandler):
    def respond(self):
        length = int(self.headers.get('Content-Length', '0'))
        body = json.loads(self.rfile.read(length)) if length else None
        payload = json.dumps({'method': self.command, 'path': self.path, 'body': body}).encode()
        self.send_response(409 if self.path == '/send' else 200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PATCH = do_DELETE = respond

    def log_message(self, *_args):
        pass


class CLITest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(('127.0.0.1', 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def run_cli(self, *args):
        env = {**os.environ, 'WECLAW_CLI_PORT': str(self.server.server_port)}
        return subprocess.run([str(BINARY), *args], capture_output=True, text=True, env=env)

    def test_status(self):
        result = self.run_cli('status')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['path'], '/health')

    def test_send_error_and_absolute_path(self):
        result = self.run_cli('send', '中文 file.mov')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertEqual(json.loads(result.stderr)['body']['file_path'], str(Path('中文 file.mov').resolve()))

    def test_schedule_and_validation(self):
        result = self.run_cli('schedule', '60', 'a', 'b')
        self.assertEqual(result.returncode, 0)
        body = json.loads(result.stdout)['body']
        self.assertEqual(body['delay_seconds'], 60)
        self.assertEqual(len(body['items']), 2)
        result = self.run_cli('schedule', '0', 'a')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stderr)['ok'])

    def test_plan_actions(self):
        plan = 'a1b2c3d4-0000-0000-0000-000000000000'
        for command, extra, method, suffix in [('show', [], 'GET', ''), ('cancel', [], 'DELETE', ''), ('send-now', [], 'POST', '/send-now'), ('reschedule', ['30'], 'PATCH', '')]:
            result = self.run_cli(command, plan, *extra)
            self.assertEqual(result.returncode, 0)
            response = json.loads(result.stdout)
            self.assertEqual(response['method'], method)
            self.assertEqual(response['path'], '/scheduled-sends/' + plan.upper() + suffix)
            if command == 'reschedule':
                self.assertEqual(response['body'], {'delay_seconds': 30})


if __name__ == '__main__':
    unittest.main()
