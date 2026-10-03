#!/usr/bin/env python3
"""Manual HTTP regression fixture; run explicitly, binds only to loopback."""
import argparse
import hashlib
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

# Stable 8 MiB payload; no user files, credentials or external servers.
PAYLOAD = bytes(range(256)) * (8 * 1024 * 1024 // 256)


class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.respond(head_only=True)

    def do_GET(self):
        self.respond(head_only=False)

    def log_message(self, format, *args):
        # Do not log URLs/query strings or headers.
        pass

    def respond(self, head_only):
        route = urlsplit(self.path).path
        if route == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/file.bin")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if route == "/rate-limit":
            self.send_response(429)
            self.send_header("Retry-After", "1")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if route not in ("/file.bin", "/no-range", "/changed", "/disconnect", "/unknown-length", "/filename"):
            self.send_error(404)
            return
        body = PAYLOAD if route != "/changed" else PAYLOAD[::-1]
        start, end = 0, len(body) - 1
        range_header = self.headers.get("Range")
        use_range = range_header and route not in ("/no-range", "/unknown-length")
        if use_range:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", range_header)
            if not match:
                self.send_error(400)
                return
            start = int(match[1])
            end = min(int(match[2]) if match[2] else end, end)
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(body)}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        self.send_response(206 if use_range else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("ETag", '"' + hashlib.sha256(body).hexdigest() + '"')
        if route != "/no-range":
            self.send_header("Accept-Ranges", "bytes")
        if use_range:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(body)}")
        if route == "/filename":
            self.send_header("Content-Disposition", "attachment; filename*=UTF-8''%E6%B8%AC%E8%A9%A6.bin")
        if route != "/unknown-length":
            self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        if head_only:
            return
        data = body[start:end + 1]
        if route == "/disconnect":
            data = data[:max(1, len(data) // 2)]
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8877)
    args = parser.parse_args()
    print(f"Manual fixture listening on http://127.0.0.1:{args.port}; stop with Control-C")
    print("file.bin SHA256:", hashlib.sha256(PAYLOAD).hexdigest())
    print("changed SHA256:", hashlib.sha256(PAYLOAD[::-1]).hexdigest())
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
