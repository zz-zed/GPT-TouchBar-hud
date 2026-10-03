"""Loopback-only streaming fixtures; no GitHub or user application interaction."""
import http.server
import os
import subprocess
import sys
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    retries = 0
    payload = b"update-progress-fixture".ljust(64 * 1024, b"x") * 16

    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == "/checksums":
            body = ("0" * 64 + "  GPT-TouchBar-HUD-0.1.38-arm64.dmg\n").encode()
        else:
            body = self.payload
        status = 200
        if self.path == "/bad":
            status = 503
        if self.path == "/retry.dmg":
            type(self).retries += 1
            if self.retries == 1:
                status = 503
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for start in range(0, len(body), 64 * 1024):
                self.wfile.write(body[start : start + 64 * 1024])
                self.wfile.flush()
                time.sleep(0.12 if self.path == "/retry.dmg" else 0.06)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, UPDATE_TEST_BASE_URL=f"http://127.0.0.1:{server.server_port}")
    try:
        result = subprocess.run([sys.argv[1]], env=env, timeout=45, check=False)
        sys.exit(result.returncode)
    finally:
        server.shutdown()
        server.server_close()
