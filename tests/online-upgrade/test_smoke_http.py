import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/kokawu-smoke-http.sh'


class HttpSmokeTests(unittest.TestCase):
    def run_case(self, failure=None):
        visits = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, code, body, headers=None):
                self.send_response(code)
                for key, value in (headers or {}).items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(body.encode())

            def do_POST(self):
                data = self.rfile.read(int(self.headers['Content-Length']))
                if failure == 'login' or b'luci_password=test' not in data:
                    self.reply(403, '<html>login failed</html>')
                else:
                    self.reply(302, '', {'Set-Cookie': 'sysauth_http=testsession; Path=/'})

            def do_GET(self):
                visits.append(self.path)
                if self.path == '/cgi-bin/luci/':
                    self.reply(403, '<html>luci_username</html>',
                               {'X-LuCI-Login-Required': 'yes'} if failure != 'generic403' else {})
                    return
                if self.headers.get('Cookie') != 'sysauth_http=testsession':
                    self.reply(403, 'missing cookie')
                    return
                if failure == 'server':
                    self.reply(500, '<html>server error</html>')
                elif failure == 'render':
                    self.reply(200, '<html>No module named math</html>')
                elif failure == 'loginform':
                    self.reply(200, '<html><input name="luci_password"></html>')
                elif failure == 'upgrade' and self.path.endswith('kokawu-upgrade'):
                    self.reply(404, '<html>missing plugin</html>')
                else:
                    self.reply(200, '<html>authenticated page</html>')

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as work:
                result = subprocess.run(['sh', str(SCRIPT)], env=dict(
                    os.environ, SMOKE_PASSWORD='test', SMOKE_HTTP_DIR=work,
                    SMOKE_BASE_URL=f'http://127.0.0.1:{server.server_port}'),
                    capture_output=True, text=True, timeout=10)
                self.assertFalse((Path(work) / 'cookies').exists())
                return result, visits
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_login_and_both_authenticated_pages(self):
        result, visits = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(visits, ['/cgi-bin/luci/', '/cgi-bin/luci/admin/status/overview',
                                 '/cgi-bin/luci/admin/system/kokawu-upgrade'])

    def test_errors_are_not_treated_as_login_success(self):
        for failure in ['generic403', 'login', 'server', 'render', 'loginform', 'upgrade']:
            with self.subTest(failure=failure):
                result, _ = self.run_case(failure)
                self.assertNotEqual(result.returncode, 0)
