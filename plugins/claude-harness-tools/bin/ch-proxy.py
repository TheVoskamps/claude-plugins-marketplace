#!/usr/bin/env python3
"""Logging reverse proxy between a Claude Code session and its API.

The client speaks plain HTTP to a loopback port this proxy binds; the
proxy opens its own connection to the upstream base URL, forwards the
request, and streams the response back. Every request, whatever its
path, is written to disk raw beneath the capture directory: the request
headers as received, the response headers as upstream sent them, before
any hop-by-hop header is dropped, and both bodies with only their chunked
transfer framing removed. No body is decompressed, re-serialized or
redacted on the way through, so two captures differ only where the
traffic did.

Recording fails open. A disk or serialization error is reported on
stderr and never alters the response the client receives, and an
upstream response of any status is forwarded as it arrived.

Standard library only, and no syntax newer than Python 3.9, so a stock
macOS `/usr/bin/python3` runs it with nothing installed.
"""

import argparse
import datetime
import http.client
import http.server
import json
import os
import ssl
import sys
import threading
import urllib.parse

CHUNK_SIZE = 64 * 1024

UPSTREAM_TIMEOUT = 600.0

REQUEST_DIR_FORMAT = "%06d"

SESSION_FILE = "session.json"

# What writing a capture file can raise: the filesystem, and `json` on a
# value it cannot encode. Every one is reported and swallowed, so a
# recording failure never reaches the client.
RECORDING_ERRORS = (OSError, TypeError, ValueError)

# Headers that describe one connection rather than the message, so each
# leg of the proxy sets its own. The `Proxy-Authorization` family is
# absent on purpose: every credential header reaches upstream as it
# arrived. `Expect` is here because the client-side server has already
# answered `100-continue` by the time the request is forwarded, and the
# forwarded body is sent without waiting.
HOP_BY_HOP = frozenset(
    [
        "connection",
        "expect",
        "keep-alive",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ]
)


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec="milliseconds"
    )


def _warn(message):
    sys.stderr.write("ch-proxy: %s\n" % message)
    sys.stderr.flush()


def _write_json(path, payload):
    """Replace `path` with `payload`, never leaving `path` half-written."""
    temporary = path + ".tmp"
    with open(temporary, "w") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def _body_less(method, status):
    return method == "HEAD" or 100 <= status < 200 or status in (204, 304)


class Recorder:
    """Write one request's capture files, swallowing every write error.

    Each method is a fail-open boundary: whatever goes wrong while
    writing is reported on stderr and the proxy carries on forwarding.
    """

    def __init__(self, directory):
        self.directory = directory
        self.meta = {}
        self._body = None
        self._body_failed = False

    def _guard(self, action, what):
        try:
            action()
        except RECORDING_ERRORS as error:
            _warn("could not write %s in %s: %s" % (what, self.directory, error))

    def start(self, meta, body):
        """Create the request directory and write request.json and request.body.

        The directory must not exist yet: one that does is reported as a
        recording error, and neither file is written.
        """
        self.meta = meta

        def write():
            os.makedirs(self.directory)
            _write_json(os.path.join(self.directory, "request.json"), self.meta)
            with open(os.path.join(self.directory, "request.body"), "wb") as handle:
                handle.write(body)

        self._guard(write, "the request")

    def response_headers(self, status, reason, headers):
        """Write response.headers.json and hold `status` for request.json."""
        self.meta["status"] = status
        payload = {"status": status, "reason": reason, "headers": headers}
        path = os.path.join(self.directory, "response.headers.json")
        self._guard(lambda: _write_json(path, payload), "response.headers.json")

    def response_chunk(self, data):
        """Append `data` to response.body, opening the file on first use.

        The first failed write ends recording of this body, so the failure
        is reported once and no later chunk lands after a missing one.
        """
        if self._body_failed:
            return

        def write():
            if self._body is None:
                self._body = open(os.path.join(self.directory, "response.body"), "wb")
            self._body.write(data)
            self._body.flush()

        try:
            write()
        except RECORDING_ERRORS as error:
            self._body_failed = True
            _warn("could not write response.body in %s: %s" % (self.directory, error))

    def finish(self, error=None):
        """Close the capture: stamp `ended_at` and any `error` into request.json.

        Call it once per request, after the last chunk. It creates an empty
        response.body when no chunk arrived, so a request directory recorded
        without error holds all four files.
        """
        self.meta["ended_at"] = _now()
        if error is not None:
            self.meta["error"] = error
        if self._body is None:
            self.response_chunk(b"")
        if self._body is not None:
            self._guard(self._body.close, "response.body")
        path = os.path.join(self.directory, "request.json")
        self._guard(lambda: _write_json(path, self.meta), "request.json")


class CaptureServer(http.server.ThreadingHTTPServer):
    """A threaded server holding the upstream, the counter and session.json."""

    daemon_threads = True

    def __init__(self, address, handler, upstream, capture_dir, session):
        http.server.ThreadingHTTPServer.__init__(self, address, handler)
        parsed = urllib.parse.urlsplit(upstream)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise ValueError("upstream must be an http or https URL: %r" % upstream)
        self.upstream_scheme = parsed.scheme
        self.upstream_host = parsed.hostname
        self.upstream_port = parsed.port
        self.upstream_netloc = parsed.netloc
        self.upstream_prefix = parsed.path.rstrip("/")
        self.capture_dir = capture_dir
        self.session = session
        self._counter = 0
        self._lock = threading.Lock()
        self._session_header_seen = False

    def next_request_dir(self):
        """Return the path for the next request, numbered in arrival order.

        Safe to call from concurrent handler threads. The directory is not
        created here; `Recorder.start` creates it.
        """
        with self._lock:
            self._counter += 1
            number = self._counter
        return os.path.join(self.capture_dir, REQUEST_DIR_FORMAT % number)

    def write_session(self):
        """Rewrite session.json; unlike a `Recorder` write, an error propagates."""
        _write_json(os.path.join(self.capture_dir, SESSION_FILE), self.session)

    def note_session_header(self, headers):
        """Add the first `*session*` request header seen to session.json."""
        if self._session_header_seen:
            return
        match = None
        for name, value in headers:
            if "session" in name.lower():
                match = (name, value)
                break
        if match is None:
            return
        with self._lock:
            if self._session_header_seen:
                return
            self._session_header_seen = True
            self.session["session_header"] = {"name": match[0], "value": match[1]}
            try:
                self.write_session()
            except RECORDING_ERRORS as error:
                _warn("could not update %s: %s" % (SESSION_FILE, error))

    def connect_upstream(self):
        """Return a new, not yet connected connection to the upstream host.

        Each request gets a connection of its own and must close it.
        """
        if self.upstream_scheme == "https":
            return http.client.HTTPSConnection(
                self.upstream_host,
                self.upstream_port,
                timeout=UPSTREAM_TIMEOUT,
                context=ssl.create_default_context(),
            )
        return http.client.HTTPConnection(
            self.upstream_host, self.upstream_port, timeout=UPSTREAM_TIMEOUT
        )


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    """Forward one request upstream and stream its response back."""

    protocol_version = "HTTP/1.1"

    def do_any(self):
        server = self.server
        recorder = Recorder(server.next_request_dir())
        headers = list(self.headers.items())
        server.note_session_header(headers)
        body = self._read_body()
        recorder.start(
            {
                "method": self.command,
                "path": self.path,
                "headers": headers,
                "started_at": _now(),
            },
            body,
        )

        connection = server.connect_upstream()
        try:
            response = self._send_upstream(connection, headers, body)
        except (OSError, ValueError, http.client.HTTPException) as error:
            connection.close()
            self._bad_gateway(recorder, error)
            return

        try:
            self._relay(response, recorder)
        finally:
            connection.close()

    do_GET = do_any
    do_POST = do_any
    do_PUT = do_any
    do_PATCH = do_any
    do_DELETE = do_any
    do_HEAD = do_any
    do_OPTIONS = do_any

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

    def _send_upstream(self, connection, headers, body):
        server = self.server
        connection.putrequest(
            self.command,
            server.upstream_prefix + self.path,
            skip_host=True,
            skip_accept_encoding=True,
        )
        connection.putheader("Host", server.upstream_netloc)
        has_length = False
        for name, value in headers:
            lowered = name.lower()
            if lowered == "host" or lowered in HOP_BY_HOP:
                continue
            if lowered == "content-length":
                has_length = True
            connection.putheader(name, value)
        # A chunked request body arrives de-chunked, so it goes upstream
        # framed by length instead; `Transfer-Encoding` is hop-by-hop.
        if body and not has_length:
            connection.putheader("Content-Length", str(len(body)))
        connection.endheaders(body if body else None)
        return connection.getresponse()

    def _relay(self, response, recorder):
        upstream_headers = list(response.getheaders())
        recorder.response_headers(response.status, response.reason, upstream_headers)
        has_body = not _body_less(self.command, response.status)
        chunked = has_body and response.chunked
        delimited_by_close = has_body and not chunked and response.length is None

        error = None
        try:
            self.send_response_only(response.status, response.reason)
            for name, value in upstream_headers:
                if name.lower() not in HOP_BY_HOP:
                    self.send_header(name, value)
            if chunked:
                self.send_header("Transfer-Encoding", "chunked")
            if delimited_by_close:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()

            while has_body:
                data = response.read1(CHUNK_SIZE)
                if not data:
                    break
                recorder.response_chunk(data)
                if chunked:
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                else:
                    self.wfile.write(data)
                self.wfile.flush()
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (OSError, http.client.HTTPException) as failure:
            # The status line is already out, so a failure mid-stream on
            # either leg can only end the connection, which is what tells
            # the client the body is truncated.
            error = "%s: %s" % (type(failure).__name__, failure)
            self.close_connection = True
        recorder.finish(error)

    def _bad_gateway(self, recorder, failure):
        """Answer a request that never reached upstream with a 502."""
        error = "%s: %s" % (type(failure).__name__, failure)
        payload = ("ch-proxy: upstream request failed: %s\n" % error).encode("utf-8")
        headers = [
            ("Content-Type", "text/plain; charset=utf-8"),
            ("Content-Length", str(len(payload))),
        ]
        recorder.response_headers(502, "Bad Gateway", headers)
        try:
            self.send_response_only(502, "Bad Gateway")
            for name, value in headers:
                self.send_header(name, value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
                recorder.response_chunk(payload)
        except OSError as client_failure:
            error += "; client: %s" % client_failure
            self.close_connection = True
        recorder.finish(error)

    def log_message(self, fmt, *args):
        _warn(fmt % args)


def main(argv=None):
    """Bind a loopback port, write session.json, and serve until interrupted.

    The bound port is printed as the first line on stdout, after
    session.json is written; a launcher reads that line to find the proxy.
    Everything after `--` in `argv` is recorded in session.json as the
    claude argv and is not run.
    """
    parser = argparse.ArgumentParser(
        description="Forward a Claude Code session's API traffic, writing all of it to disk."
    )
    parser.add_argument(
        "--upstream", required=True, help="base URL requests are forwarded to"
    )
    parser.add_argument(
        "--capture-dir",
        required=True,
        help="session directory the capture is written into",
    )
    parser.add_argument("--name", required=True, help="human-readable session name")
    parser.add_argument("--cwd", default=os.getcwd(), help="directory claude runs in")
    parser.add_argument(
        "--repo", default="(local)", help="repository name claude runs in"
    )
    parser.add_argument(
        "claude_argv",
        nargs=argparse.REMAINDER,
        help="after `--`, the argv claude is invoked with",
    )
    args = parser.parse_args(argv)
    claude_argv = args.claude_argv
    if claude_argv[:1] == ["--"]:
        claude_argv = claude_argv[1:]

    capture_dir = os.path.abspath(os.path.expanduser(args.capture_dir))
    os.makedirs(capture_dir, exist_ok=True)

    session = {
        "name": args.name,
        "port": None,
        "cwd": args.cwd,
        "repo": args.repo,
        "argv": claude_argv,
        "upstream": args.upstream,
        "started_at": _now(),
    }
    server = CaptureServer(
        ("127.0.0.1", 0), ProxyHandler, args.upstream, capture_dir, session
    )
    session["port"] = server.server_address[1]
    server.write_session()

    print(session["port"])
    sys.stdout.flush()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _warn("interrupted; stopping")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
