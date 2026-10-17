"""Local deterministic HTTP server for moonfetch_vs_copas.lua.

    python server.py [port]        (default 8765)
"""
import gzip
import hashlib
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, urlsplit

BLOCK = bytes(i % 251 for i in range(251))


def pattern(n):
    return (BLOCK * (n // 251 + 1))[:n]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def handle_any(self):
        u = urlsplit(self.path)
        parts = [p for p in u.path.split("/") if p]
        head = parts[0] if parts else ""
        body = self.read_body()
        info = {
            "method": self.command,
            "args": dict(parse_qsl(u.query)),
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "len": len(body),
            "sha1": hashlib.sha1(body).hexdigest(),
        }
        if head in ("get", "anything", "headers"):
            self.send(200, info)
        elif head == "echo":
            self.send(200, body, "application/octet-stream")
        elif head == "status":
            self.send(int(parts[1]), {"status": int(parts[1])})
        elif head == "bytes":
            self.send(200, pattern(int(parts[1])), "application/octet-stream")
        elif head == "delay":
            time.sleep(int(parts[1]) / 1000)
            self.send(200, info)
        elif head == "gzip":
            self.send(200, gzip.compress(json.dumps({"gzipped": True}).encode()),
                      extra={"Content-Encoding": "gzip"})
        elif head == "redirect":
            self.send(302, b"", extra={"Location": "/get?redirected=1"})
        elif head == "utf8":
            self.send(200, "Привет, мир! ✓".encode(), "text/plain; charset=utf-8")
        else:
            self.send(404, {"error": "not found"})

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = handle_any


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 256

    def handle_error(self, request, client_address):
        pass  # clients dropping keep-alive / timed-out connections


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    srv = Server(("127.0.0.1", port), Handler)
    print(f"listening on http://127.0.0.1:{port}", flush=True)
    srv.serve_forever()
