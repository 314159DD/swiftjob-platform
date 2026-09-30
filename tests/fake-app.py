"""Test double for tests/smoke-test.test.sh: one server playing web and API, misbehaving on request.

MODE=good | foreign-cors | internal-redirect
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = os.environ.get("MODE", "good")
WEB = os.environ["WEB"]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_OPTIONS(self):
        origin = self.headers.get("Origin", "")
        self.send_response(200)
        if origin == WEB or MODE == "foreign-cors":
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/api/health"):
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Strict-Transport-Security", "max-age=31536000")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/auth/callback"):
            target = "http://0.0.0.0:3000/auth/login" if MODE == "internal-redirect" else f"{WEB}/auth/login?error=smoke"
            self.send_response(307)
            self.send_header("Location", target)
            self.end_headers()
        else:
            self.send_response(200)
            self.end_headers()


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
