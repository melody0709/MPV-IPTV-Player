from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


HOST = "127.0.0.1"
PORT = 18991


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _headers_ok(self) -> bool:
        return all(
            (
                self.headers.get("User-Agent") == "IntegrationUA/9.0",
                self.headers.get("Referer") == "https://ref.integration/",
                self.headers.get("Origin") == "https://origin.integration",
                self.headers.get("Cookie") == "sid=integration",
            )
        )

    def _write(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlsplit(self.path).path
        headers_ok = self._headers_ok()
        print(
            json.dumps(
                {
                    "path": path,
                    "query": parse_qs(urlsplit(self.path).query),
                    "headers_ok": headers_ok,
                    "cookie_present": self.headers.get("Cookie") is not None,
                },
                ensure_ascii=True,
            ),
            flush=True,
        )

        if not headers_ok:
            self._write(403, b"missing source headers", "text/plain")
            return

        if path == "/start":
            self.send_response(302)
            self.send_header("Location", "/master.m3u8?session=short-lived")
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return

        if path == "/master.m3u8":
            playlist = (
                "#EXTM3U\n"
                "#EXT-X-VERSION:3\n"
                "#EXT-X-TARGETDURATION:1\n"
                "#EXT-X-MEDIA-SEQUENCE:0\n"
                "#EXTINF:0.1,\n"
                "segment.ts?session=short-lived\n"
                "#EXT-X-ENDLIST\n"
            ).encode("ascii")
            self._write(200, playlist, "application/vnd.apple.mpegurl")
            return

        if path == "/segment.ts":
            null_packet = bytes((0x47, 0x1F, 0xFF, 0x10)) + bytes((0xFF,)) * 184
            self._write(200, null_packet * 8, "video/mp2t")
            return

        self._write(404, b"not found", "text/plain")


if __name__ == "__main__":
    print(json.dumps({"ready": True, "host": HOST, "port": PORT}), flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
