#!/usr/bin/env python3
"""Drive the real proxy over loopback against a fake upstream.

Every case starts `ch-proxy.py` as a subprocess pointed at an in-process
plain-HTTP upstream, sends traffic through the port it prints, and then
grades both what the client received and what landed on disk.

Standard library only, and no syntax newer than Python 3.9, so a stock
macOS `/usr/bin/python3` runs it with nothing installed.
"""

import gzip
import http.client
import http.server
import importlib.util
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

PROXY = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, "bin", "ch-proxy.py"
)

REQUEST_FILES = [
    "request.json",
    "request.body",
    "response.headers.json",
    "response.body",
]

BINARY_BODY = bytes(range(256)) * 4

GZIP_BODY = gzip.compress(b'{"type":"message","content":[]}')

ERROR_BODY = (
    b'{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'
)

SSE_EVENTS = [b"event: first\ndata: {}\n\n", b"event: second\ndata: {}\n\n"]

CHUNKED_REQUEST_BODY = b"5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"

FAILURES = []


def check(condition, description):
    if condition:
        print("PASS  " + description)
    else:
        print("FAIL  " + description)
        FAILURES.append(description)


class Upstream(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        http.server.ThreadingHTTPServer.__init__(
            self, ("127.0.0.1", 0), UpstreamHandler
        )
        self.received = []
        self.release_stream = threading.Event()
        self.stream_finished = threading.Event()
        self.barrier = threading.Barrier(2, timeout=5)


class UpstreamHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_any(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        self.server.received.append(
            (self.command, self.path, list(self.headers.items()), body)
        )
        if self.path.endswith("/sse"):
            self._sse()
        elif self.path.endswith("/concurrent"):
            try:
                self.server.barrier.wait()
                self._reply(200, b"together", "text/plain")
            except threading.BrokenBarrierError:
                self._reply(504, b"serialized", "text/plain")
        elif self.path.endswith("/error"):
            self._reply(529, ERROR_BODY, "application/json")
        elif self.path.endswith("/gzip"):
            self._reply(
                200, GZIP_BODY, "application/json", [("Content-Encoding", "gzip")]
            )
        else:
            self._reply(200, BINARY_BODY, "application/octet-stream")

    do_GET = do_any
    do_POST = do_any
    do_HEAD = do_any

    def _reply(self, status, payload, content_type, extra=()):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for name, value in extra:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self._chunk(SSE_EVENTS[0])
        self.server.release_stream.wait(5)
        self._chunk(SSE_EVENTS[1])
        self.wfile.write(b"0\r\n\r\n")
        self.server.stream_finished.set()

    def _chunk(self, data):
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    def log_message(self, fmt, *args):
        pass


def start_upstream():
    upstream = Upstream()
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    return upstream


def start_proxy(upstream_url, capture_dir):
    process = subprocess.Popen(
        [
            sys.executable,
            PROXY,
            "--upstream",
            upstream_url,
            "--capture-dir",
            capture_dir,
            "--name",
            "test session [harness-proxy]",
            "--cwd",
            "/somewhere",
            "--repo",
            "some-repo",
            "--",
            "claude",
            "--name",
            "test session [harness-proxy]",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    port = int(process.stdout.readline().strip())
    return process, port


def request(port, method, path, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    connection.request(method, path, body=body, headers=headers or {})
    response = connection.getresponse()
    payload = response.read()
    connection.close()
    return response, payload


def chunk(data):
    return b"%x\r\n%s\r\n" % (len(data), data)


def raw_request(port, data):
    """Send `data` as the whole request and return everything read back."""
    connection = socket.create_connection(("127.0.0.1", port), timeout=15)
    connection.sendall(data)
    received = []
    while True:
        part = connection.recv(65536)
        if not part:
            break
        received.append(part)
    connection.close()
    return b"".join(received)


def request_dirs(capture_dir):
    return sorted(
        entry
        for entry in os.listdir(capture_dir)
        if os.path.isdir(os.path.join(capture_dir, entry))
    )


def read(path, mode="rb"):
    with open(path, mode) as handle:
        return handle.read()


def finished_meta(directory):
    """Read request.json once the proxy has written its final version.

    The client holds the whole response before the proxy records the end
    of the exchange, so the final write can trail the client by a moment.
    """
    path = os.path.join(directory, "request.json")
    deadline = time.time() + 5
    while True:
        meta = json.loads(read(path, "r"))
        if "ended_at" in meta or time.time() > deadline:
            return meta
        time.sleep(0.05)


def main():
    sandbox = tempfile.mkdtemp(prefix="ch-proxy-test.")
    upstream = start_upstream()
    upstream_url = "http://127.0.0.1:%d/base" % upstream.server_address[1]
    capture_dir = os.path.join(sandbox, "session")
    process, port = start_proxy(upstream_url, capture_dir)
    try:
        run_cases(upstream, port, capture_dir)
        run_fail_open(port, capture_dir)
        run_unreachable_upstream(sandbox)
        run_connect_failure(sandbox)
        run_bad_upstream(sandbox)
    finally:
        process.terminate()
        process.wait()
        upstream.shutdown()
    if FAILURES:
        print("\n%d failure(s); sandbox left at %s" % (len(FAILURES), sandbox))
        return 1
    shutil.rmtree(sandbox)
    print("\nall passed")
    return 0


def run_cases(upstream, port, capture_dir):
    session = json.loads(read(os.path.join(capture_dir, "session.json"), "r"))
    check(
        session.get("name") == "test session [harness-proxy]",
        "session.json carries the name",
    )
    check(session.get("port") == port, "session.json carries the bound port")
    check(session.get("cwd") == "/somewhere", "session.json carries the cwd")
    check(session.get("repo") == "some-repo", "session.json carries the repo")
    check(
        session.get("argv") == ["claude", "--name", "test session [harness-proxy]"],
        "session.json carries the claude argv",
    )
    check(bool(session.get("started_at")), "session.json carries the start time")
    check(
        "session_header" not in session,
        "session.json has no session header before one is seen",
    )

    credentials = {
        "Authorization": "Bearer sk-test-secret",
        "x-api-key": "sk-ant-test",
        "Accept-Encoding": "gzip, deflate, br",
        "Content-Type": "application/octet-stream",
    }
    response, payload = request(
        port, "POST", "/v1/messages?beta=true", BINARY_BODY, credentials
    )
    check(
        response.status == 200 and payload == BINARY_BODY,
        "a POST round-trips its response body",
    )
    method, path, received_headers, received_body = upstream.received[-1]
    check(
        path == "/base/v1/messages?beta=true",
        "the path is appended to the upstream base path",
    )
    check(received_body == BINARY_BODY, "upstream receives the request body unchanged")
    received = dict((name.lower(), value) for name, value in received_headers)
    for name, value in credentials.items():
        check(
            received.get(name.lower()) == value, "upstream receives %s unchanged" % name
        )

    first = os.path.join(capture_dir, "000001")
    check(
        all(os.path.isfile(os.path.join(first, name)) for name in REQUEST_FILES),
        "the first request directory holds all four files",
    )
    check(
        read(os.path.join(first, "request.body")) == BINARY_BODY,
        "request.body is the wire bytes",
    )
    check(
        read(os.path.join(first, "response.body")) == BINARY_BODY,
        "response.body is the wire bytes",
    )
    meta = finished_meta(first)
    check(meta.get("method") == "POST", "request.json carries the method")
    check(meta.get("path") == "/v1/messages?beta=true", "request.json carries the path")
    check(meta.get("status") == 200, "request.json carries the response status")
    check(
        bool(meta.get("started_at")) and bool(meta.get("ended_at")),
        "request.json carries both timestamps",
    )
    check(
        ["Authorization", "Bearer sk-test-secret"] in meta.get("headers", []),
        "request.json keeps credential headers as they arrived",
    )

    response, payload = request(
        port, "GET", "/gzip", headers={"Accept-Encoding": "gzip"}
    )
    check(payload == GZIP_BODY, "a gzip response reaches the client still compressed")
    check(
        response.getheader("Content-Encoding") == "gzip",
        "Content-Encoding passes through",
    )
    check(
        read(os.path.join(capture_dir, "000002", "response.body")) == GZIP_BODY,
        "response.body keeps the gzip bytes",
    )

    response, payload = request(port, "HEAD", "/api/hello")
    check(
        response.status == 200 and payload == b"",
        "a HEAD request is answered without a body",
    )
    check(
        all(
            os.path.isfile(os.path.join(capture_dir, "000003", name))
            for name in REQUEST_FILES
        ),
        "a non-messages path produces all four files",
    )
    head_meta = json.loads(
        read(os.path.join(capture_dir, "000003", "request.json"), "r")
    )
    check(
        head_meta.get("method") == "HEAD" and head_meta.get("path") == "/api/hello",
        "request.json records a HEAD path",
    )

    response, payload = request(port, "POST", "/error", b"{}")
    check(
        response.status == 529 and payload == ERROR_BODY,
        "an upstream error reaches the client verbatim",
    )

    request(port, "GET", "/one", headers={"X-Claude-Code-Session-Id": "session-a"})
    request(port, "GET", "/two", headers={"X-Claude-Code-Session-Id": "session-b"})
    session = json.loads(read(os.path.join(capture_dir, "session.json"), "r"))
    check(
        session.get("session_header")
        == {"name": "X-Claude-Code-Session-Id", "value": "session-a"},
        "session.json gains the first *session* header only",
    )

    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    connection.request("POST", "/sse", body=b"{}")
    response = connection.getresponse()
    first_event = response.read1(4096)
    check(
        first_event.startswith(b"event: first")
        and not upstream.stream_finished.is_set(),
        "an SSE event arrives before upstream finishes the response",
    )
    upstream.release_stream.set()
    rest = response.read()
    connection.close()
    check(
        first_event + rest == b"".join(SSE_EVENTS),
        "the rest of the SSE stream follows",
    )
    sse_dir = request_dirs(capture_dir)[-1]
    check(
        read(os.path.join(capture_dir, sse_dir, "response.body"))
        == chunk(SSE_EVENTS[0]) + chunk(SSE_EVENTS[1]) + b"0\r\n\r\n",
        "response.body holds the event stream with its chunked framing",
    )

    reply = raw_request(
        port,
        b"POST /chunked HTTP/1.1\r\nHost: client\r\nTransfer-Encoding: chunked\r\n"
        b"Content-Length: 3\r\nConnection: close\r\n\r\n" + CHUNKED_REQUEST_BODY,
    )
    check(reply.startswith(b"HTTP/1.1 200 "), "a chunked request is answered")
    check(
        upstream.received[-1][3] == b"hello world",
        "a chunked request with a stale Content-Length reaches upstream whole",
    )
    chunked_dir = os.path.join(capture_dir, request_dirs(capture_dir)[-1])
    check(
        read(os.path.join(chunked_dir, "request.body")) == CHUNKED_REQUEST_BODY,
        "request.body holds a chunked request with its chunked framing",
    )
    check(
        ["Content-Length", "3"] in finished_meta(chunked_dir).get("headers", []),
        "request.json keeps the Content-Length the client sent",
    )

    malformed = [
        ("a non-numeric Content-Length", b"Content-Length: abc\r\n\r\n", b""),
        ("a negative Content-Length", b"Content-Length: -1\r\n\r\nhello", b""),
        (
            "a non-hex chunk size",
            b"Transfer-Encoding: chunked\r\n\r\n" + chunk(b"hello") + b"zz\r\n",
            chunk(b"hello") + b"zz\r\n",
        ),
    ]
    for description, framing, recorded in malformed:
        received_before = len(upstream.received)
        reply = raw_request(
            port, b"POST /malformed HTTP/1.1\r\nHost: client\r\n" + framing
        )
        check(
            reply.startswith(b"HTTP/1.1 400 "),
            "a request with %s is answered with a 400" % description,
        )
        check(
            len(upstream.received) == received_before,
            "a request with %s is not forwarded" % description,
        )
        malformed_dir = os.path.join(capture_dir, request_dirs(capture_dir)[-1])
        check(
            all(
                os.path.isfile(os.path.join(malformed_dir, name))
                for name in REQUEST_FILES
            ),
            "a request with %s produces all four files" % description,
        )
        check(
            read(os.path.join(malformed_dir, "request.body")) == recorded,
            "request.body holds what was read of a request with %s" % description,
        )
        meta = finished_meta(malformed_dir)
        check(
            meta.get("status") == 400
            and meta.get("error", "").startswith("MalformedRequest"),
            "request.json records the 400 and the error for %s" % description,
        )

    results = []

    def concurrent():
        response, payload = request(port, "GET", "/concurrent")
        results.append(payload)

    threads = [threading.Thread(target=concurrent) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    check(
        results == [b"together", b"together"],
        "two simultaneous requests are in flight at once",
    )

    names = request_dirs(capture_dir)
    check(
        names == ["%06d" % n for n in range(1, len(names) + 1)],
        "request directories are numbered 1..n",
    )


def run_fail_open(port, capture_dir):
    os.chmod(capture_dir, 0o500)
    try:
        response, payload = request(port, "POST", "/v1/messages", BINARY_BODY)
        check(
            response.status == 200 and payload == BINARY_BODY,
            "a disk error does not alter the response",
        )
    finally:
        os.chmod(capture_dir, 0o700)


def run_unreachable_upstream(sandbox):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    closed_port = listener.getsockname()[1]
    listener.close()
    process, port = start_proxy(
        "http://127.0.0.1:%d" % closed_port, os.path.join(sandbox, "unreachable")
    )
    try:
        response, payload = request(port, "GET", "/v1/models")
        check(response.status == 502, "an unreachable upstream is answered with a 502")
    finally:
        process.terminate()
        process.wait()


def load_proxy():
    spec = importlib.util.spec_from_file_location("ch_proxy", PROXY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_bad_upstream(sandbox):
    module = load_proxy()
    for upstream in ["http://example.com:abc/path", "ftp://example.com"]:
        try:
            server = module.CaptureServer(
                ("127.0.0.1", 0), module.ProxyHandler, upstream, sandbox, {}
            )
            server.server_close()
            message = None
        except ValueError as error:
            message = str(error)
        check(
            message == "upstream must be an http or https URL: %r" % upstream,
            "an upstream of %s is rejected as not an http or https URL" % upstream,
        )


def run_connect_failure(sandbox):
    """Serve in-process, with building the upstream connection raising.

    Nothing a subprocess can be handed makes `connect_upstream` raise, so
    this case loads the proxy as a module and overrides that one method.
    """
    module = load_proxy()

    class FailingServer(module.CaptureServer):
        def connect_upstream(self):
            raise ssl.SSLError("no usable trust store")

    capture_dir = os.path.join(sandbox, "connect-failure")
    os.makedirs(capture_dir)
    server = FailingServer(
        ("127.0.0.1", 0),
        module.ProxyHandler,
        "https://upstream.invalid",
        capture_dir,
        {"name": "connect failure"},
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        response, payload = request(server.server_address[1], "GET", "/v1/models")
        check(
            response.status == 502,
            "a failure building the upstream connection is answered with a 502",
        )
        meta = finished_meta(os.path.join(capture_dir, "000001"))
        check(
            "ended_at" in meta,
            "a failure building the upstream connection still stamps ended_at",
        )
        check(
            meta.get("error", "").startswith("SSLError"),
            "a failure building the upstream connection is recorded as the error",
        )
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    sys.exit(main())
