# claude-harness-tools changelog

## 0.1.0 — 2026-09-27

The plugin is new. It shows what the Claude Code harness sends to the
API: launch a session through a local logging reverse proxy and every
request and response lands on disk, byte for byte, so two sessions
launched identically except for one setting can be compared.

- The `claude-harness-capture` skill prints the launch command, where
  captures land, their layout and how to read one. It runs nothing,
  because a session cannot relaunch itself through a proxy; you start
  the captured session from your own terminal.
- `ch-capture` starts the proxy, points a `claude` child at it through
  `ANTHROPIC_BASE_URL`, and stops the proxy on every exit path.
  Arguments after `--` reach `claude` unchanged, and its exit status
  is the launcher's.
- Session names end in `[harness-proxy]`, whether computed or passed
  with `--name`, so a captured session is recognizable in the session
  list.
- A session already going through a gateway is captured through that
  gateway: the upstream is the `ANTHROPIC_BASE_URL` in force at launch,
  or `https://api.anthropic.com` without one.
- Captures live under
  `${XDG_STATE_HOME:-$HOME/.local/state}/claude-harness-tools/captures`,
  one directory per session and one numbered directory per request, in
  wire order.
- Nothing is decompressed or redacted. Bodies often stay compressed and
  chunked responses keep their framing. Credential headers are stored
  as they arrived, so treat a capture as sensitive and redact a copy
  before sharing it.
- Recording fails open: a write error goes to `proxy.log` and never
  changes the response. The proxy answers only `502` when no upstream
  response exists and `400` for unreadable request framing; every
  upstream status passes through.

It needs no install beyond a stock macOS: Python 3.9's standard library
and bash 3.2.
