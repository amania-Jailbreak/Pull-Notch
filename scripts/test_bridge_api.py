#!/usr/bin/env python3
"""Manual smoke test for Pull Notch's local bridge API.

Start Pull Notch first, then run:

    python3 scripts/test_bridge_api.py

The script sends JSON newline requests to localhost:38591 and starts a small
localhost POST receiver so the button in the generated page has a target.
"""

from __future__ import annotations

import argparse
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


BRIDGE_HOST = "127.0.0.1"
BRIDGE_PORT = 38591
POST_HOST = "127.0.0.1"
POST_PORT = 3000


class PostReceiver(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length).decode("utf-8")

        try:
            body: Any = json.loads(raw_body) if raw_body else None
        except json.JSONDecodeError:
            body = raw_body

        print(f"POST {self.path}: {body}")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}\n')

    def log_message(self, format: str, *args: Any) -> None:
        return


def start_post_receiver() -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((POST_HOST, POST_PORT), PostReceiver)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(f"POST receiver listening on http://{POST_HOST}:{POST_PORT}/deploy")
    return server


def send_bridge_request(payload: dict[str, Any]) -> dict[str, Any]:
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n"

    with socket.create_connection((BRIDGE_HOST, BRIDGE_PORT), timeout=5) as sock:
        sock.sendall(encoded)
        response = read_line(sock)

    decoded = json.loads(response.decode("utf-8"))
    print(f"{payload['method']}: {decoded}")
    return decoded


def read_line(sock: socket.socket) -> bytes:
    chunks: list[bytes] = []

    while True:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("Bridge closed the connection before sending a response")

        chunks.append(chunk)
        data = b"".join(chunks)
        if b"\n" in data:
            return data.split(b"\n", 1)[0]


def assert_ok(response: dict[str, Any]) -> None:
    if not response.get("ok"):
        raise RuntimeError(f"Bridge request failed: {response}")


def run_smoke_test(keep_alive: bool) -> None:
    server = start_post_receiver()

    try:
        assert_ok(send_bridge_request({"id": "ping", "method": "ping"}))

        assert_ok(send_bridge_request({
            "id": "widget",
            "method": "setWidget",
            "clientID": "python-smoke",
            "widget": {
                "id": "progress",
                "title": "Python Smoke",
                "placement": "trailing",
                "kind": "circularProgress",
                "systemName": "testtube.2",
                "progress": 0.72,
                "isActive": True,
                "text": "72%",
            },
        }))

        assert_ok(send_bridge_request({
            "id": "page",
            "method": "setPage",
            "clientID": "python-smoke",
            "page": {
                "id": "panel",
                "title": "Python Test",
                "preferredWidth": 420,
                "elements": [
                    {"type": "headline", "text": "Python Bridge Test"},
                    {"type": "text", "text": "Edit the message, then press POST."},
                    {"type": "progress", "label": "Progress", "value": 0.72},
                    {
                        "type": "textField",
                        "id": "message",
                        "label": "Message",
                        "placeholder": "Hello from Pull Notch",
                    },
                    {
                        "type": "button",
                        "title": "POST",
                        "systemName": "paperplane.fill",
                        "postURL": f"http://localhost:{POST_PORT}/deploy",
                        "body": {"message": "$message", "source": "python-smoke"},
                    },
                ],
            },
        }))

        assert_ok(send_bridge_request({
            "id": "open",
            "method": "openPlayer",
        }))

        print("Smoke test payloads sent. Open Pull Notch, switch to 'Python Test', and press POST.")
        if keep_alive:
            print("Press Ctrl+C to stop the POST receiver.")
            while True:
                time.sleep(1)
    finally:
        if not keep_alive:
            server.shutdown()


def main() -> None:
    parser = argparse.ArgumentParser(description="Smoke test Pull Notch bridge API")
    parser.add_argument(
        "--no-keep-alive",
        action="store_true",
        help="exit immediately after sending bridge requests",
    )
    args = parser.parse_args()

    run_smoke_test(keep_alive=not args.no_keep_alive)


if __name__ == "__main__":
    main()
