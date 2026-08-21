#!/usr/bin/env python3
"""Drive the real sink over loopback and grade what it captured.

Every case starts `sink.py` as a subprocess, POSTs a body to the URL it
prints, and then asserts on both halves of its contract: the body landed
in the run directory byte for byte, and the answer the client got back
parses as a well-formed Messages-API response.

Standard library only, and no syntax newer than Python 3.9, so a stock
macOS `/usr/bin/python3` runs it with nothing installed.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request

PAYLOAD_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir)

SINK = os.path.join(PAYLOAD_DIR, "sink.py")

# The sink is a loose script rather than a package member, so this import
# cannot join the block above: the path entry has to exist first.
sys.path.insert(0, PAYLOAD_DIR)

import sink

FAILURES = []


def check(condition, description):
    if condition:
        print("PASS  " + description)
    else:
        print("FAIL  " + description)
        FAILURES.append(description)


def start_sink(run_dir):
    """Start the sink and return the process plus the URL it printed."""
    process = subprocess.Popen(
        [sys.executable, SINK, "--run-dir", run_dir, "--timeout", "30"],
        stdout=subprocess.PIPE,
        universal_newlines=True,
    )
    url = process.stdout.readline().strip()
    return process, url


def post(url, body):
    request = urllib.request.Request(
        url + "/v1/messages",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.headers.get("Content-Type"), response.read()


def parse_stream(payload):
    """Return the ordered event names of an SSE payload, or None if malformed."""
    names = []
    for block in payload.decode("utf-8").split("\n\n"):
        if not block.strip():
            continue
        lines = block.split("\n")
        if len(lines) != 2:
            return None
        if not lines[0].startswith("event: ") or not lines[1].startswith("data: "):
            return None
        name = lines[0][len("event: ") :]
        try:
            data = json.loads(lines[1][len("data: ") :])
        except ValueError:
            return None
        if data.get("type") != name:
            return None
        names.append(name)
    return names


def head(url, path):
    request = urllib.request.Request(url + path, method="HEAD")
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.status


def run_case(label, body, expected_type, preflight=False):
    run_dir = tempfile.mkdtemp(prefix="sink-test-")
    try:
        process, url = start_sink(run_dir)
        check(url.startswith("http://127.0.0.1:"), label + ": sink URL is loopback")
        if preflight:
            check(head(url, "/api/hello") == 200, label + ": preflight HEAD answered")
        content_type, payload = post(url, body)
        check(process.wait(timeout=30) == 0, label + ": sink exits 0")

        captured = os.path.join(run_dir, sink.DEFAULT_BODY_FILE)
        check(os.path.exists(captured), label + ": captured body file exists")
        with open(captured, "rb") as handle:
            check(handle.read() == body, label + ": captured body is verbatim")

        check(
            content_type == expected_type,
            label + ": response Content-Type is " + expected_type,
        )
        return payload
    finally:
        shutil.rmtree(run_dir, ignore_errors=True)


def test_streaming_request():
    body = json.dumps(
        {
            "model": "claude-test",
            "stream": True,
            "max_tokens": 16,
            "messages": [{"role": "user", "content": "critique these rules"}],
        }
    ).encode("utf-8")
    payload = run_case("streaming", body, "text/event-stream", preflight=True)
    names = parse_stream(payload)
    check(names is not None, "streaming: response parses as SSE")
    check(
        names is not None and names[0] == "message_start",
        "streaming: stream opens with message_start",
    )
    check(
        names is not None and names[-1] == "message_stop",
        "streaming: stream closes with message_stop",
    )


def test_non_streaming_request():
    body = json.dumps(
        {
            "model": "claude-test",
            "max_tokens": 16,
            "messages": [{"role": "user", "content": "critique these rules"}],
        }
    ).encode("utf-8")
    payload = run_case("non-streaming", body, "application/json")
    try:
        message = json.loads(payload.decode("utf-8"))
    except ValueError:
        message = None
    check(message is not None, "non-streaming: response parses as JSON")
    check(
        message is not None and message.get("type") == "message",
        "non-streaming: response is a Messages-API message",
    )


def main():
    test_streaming_request()
    test_non_streaming_request()
    if FAILURES:
        print("\n%d failure(s)" % len(FAILURES))
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
