#!/usr/bin/env python3
"""Loopback capture sink for `claude auto-mode critique`.

Bind an ephemeral loopback port, capture the one request that carries a
body, write that body verbatim into the run directory, and exit. The
sink never makes an upstream call and never forwards anything:
`ANTHROPIC_BASE_URL` points the CLI here so the critique prompt it would
have sent to the API is captured instead, to be replayed in a Claude
Code session, which has no 4K-token answer ceiling.

The CLI opens with a bodyless `HEAD /api/hello` reachability preflight
and gives up with "Connection error" if that is not answered, so the
sink answers every bodyless request and keeps serving. Only a request
with a body is the capture, and the sink stops after it.

Standard library only, and no syntax newer than Python 3.9, so a stock
macOS `/usr/bin/python3` runs it with nothing installed.
"""

import argparse
import http.server
import json
import os
import sys

RESPONSE_TEXT = "captured"

MESSAGE_ID = "msg_auto_mode_tools_sink"

MODEL_NAME = "auto-mode-tools-sink"


def _message_object():
    """The Messages-API assistant turn both response shapes are built from."""
    return {
        "id": MESSAGE_ID,
        "type": "message",
        "role": "assistant",
        "model": MODEL_NAME,
        "content": [{"type": "text", "text": RESPONSE_TEXT}],
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": 0, "output_tokens": 1},
    }


def _sse_bytes():
    """A whole Messages-API stream, from `message_start` to `message_stop`."""
    started = _message_object()
    started["content"] = []
    started["stop_reason"] = None
    events = [
        ("message_start", {"type": "message_start", "message": started}),
        (
            "content_block_start",
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""},
            },
        ),
        (
            "content_block_delta",
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": RESPONSE_TEXT},
            },
        ),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        (
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {"output_tokens": 1},
            },
        ),
        ("message_stop", {"type": "message_stop"}),
    ]
    chunks = []
    for name, payload in events:
        data = json.dumps(payload, separators=(",", ":"))
        chunks.append("event: %s\ndata: %s\n\n" % (name, data))
    return "".join(chunks).encode("utf-8")


def _wants_stream(body):
    """Whether to answer `body` with SSE rather than a JSON message.

    A body that does not decode as UTF-8 JSON cannot be asked, and gets
    the streaming shape rather than an error: the sink has already
    captured it, and its only remaining job is to let the caller exit.
    JSON that is not an object has no `stream` key to carry and gets the
    JSON message.
    """
    try:
        parsed = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return True
    return bool(isinstance(parsed, dict) and parsed.get("stream"))


class CaptureServer(http.server.HTTPServer):
    """An `HTTPServer` that records the capture and the wait timing out."""

    def __init__(self, address, handler, body_path, timeout):
        http.server.HTTPServer.__init__(self, address, handler)
        self.body_path = body_path
        self.timeout = timeout
        self.captured = False
        self.timed_out = False

    def handle_timeout(self):
        self.timed_out = True


class CaptureHandler(http.server.BaseHTTPRequestHandler):
    """Answer bodyless preflights; write the one body request to disk."""

    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self._read_body()
        if not body:
            self._respond("application/json", b"{}")
            return
        with open(self.server.body_path, "wb") as handle:
            handle.write(body)
        self.server.captured = True
        if _wants_stream(body):
            self._respond("text/event-stream", _sse_bytes())
        else:
            payload = json.dumps(_message_object()).encode("utf-8")
            self._respond("application/json", payload)

    do_GET = do_POST
    do_PUT = do_POST

    def do_HEAD(self):
        self._respond("application/json", b"{}", send_payload=False)

    def _read_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            return self._read_chunked()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _read_chunked(self):
        parts = []
        while True:
            header = self.rfile.readline().split(b";")[0].strip()
            size = int(header or b"0", 16)
            if size == 0:
                while self.rfile.readline().strip():
                    pass
                return b"".join(parts)
            parts.append(self.rfile.read(size))
            self.rfile.read(2)

    def _respond(self, content_type, payload, send_payload=True):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        if send_payload:
            self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, fmt, *args):
        sys.stderr.write("sink: " + (fmt % args) + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Capture one `claude auto-mode critique` request body."
    )
    parser.add_argument(
        "--run-dir",
        required=True,
        help="directory the captured body and the sink URL are written to",
    )
    parser.add_argument(
        "--body-file",
        default="critique-request.json",
        help="name of the captured-body file inside the run directory",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=180.0,
        help="seconds to wait for each request before giving up",
    )
    args = parser.parse_args(argv)

    run_dir = os.path.abspath(os.path.expanduser(args.run_dir))
    os.makedirs(run_dir, exist_ok=True)

    server = CaptureServer(
        ("127.0.0.1", 0),
        CaptureHandler,
        os.path.join(run_dir, args.body_file),
        args.timeout,
    )

    url = "http://127.0.0.1:%d" % server.server_address[1]
    with open(os.path.join(run_dir, "sink-url"), "w") as handle:
        handle.write(url + "\n")
    print(url)
    sys.stdout.flush()

    while not server.captured and not server.timed_out:
        server.handle_request()
    server.server_close()

    if not server.captured:
        sys.stderr.write("sink: no request arrived within %ss\n" % args.timeout)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
