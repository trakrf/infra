"""Ephemeral plain-HTTP server for the unit's cert fetch.

The unit only speaks plain HTTP and does not follow redirects, so a hosted
endpoint behind Cloudflare is out. It is in BLE range, which in practice means
on the provisioning host's LAN, so we serve from here for the life of one run.
Files live in memory under a random path token; anything else is a 404.
"""

from __future__ import annotations

import secrets
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def lan_ip_for(peer: str) -> str:
    """The local address the kernel would use to reach `peer` (no packet sent)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((peer, 9))
        return s.getsockname()[0]


class CertServer:
    def __init__(self, files: dict[str, bytes], host: str, port: int = 0):
        self._files = dict(files)
        self._token = secrets.token_hex(8)
        self.fetched: set[str] = set()
        self.log: list[str] = []
        self._cond = threading.Condition()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 -- stdlib name
                prefix = f"/{outer._token}/"
                name = self.path[len(prefix) :] if self.path.startswith(prefix) else None
                body = outer._files.get(name) if name else None
                with outer._cond:
                    outer.log.append(f"{self.client_address[0]} GET {name or self.path} "
                                     f"-> {200 if body is not None else 404}")
                if body is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                with outer._cond:
                    outer.fetched.add(name)
                    outer._cond.notify_all()

            def log_message(self, *args):
                pass

        self._httpd = ThreadingHTTPServer((host, port), Handler)
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        h, p = self._httpd.server_address[:2]
        self.base_url = f"http://{h}:{p}/{self._token}/"

    def wait_all(self, timeout: float) -> bool:
        with self._cond:
            return self._cond.wait_for(lambda: self.fetched >= set(self._files), timeout)

    def __enter__(self) -> CertServer:
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()
