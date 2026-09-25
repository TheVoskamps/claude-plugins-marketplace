---
name: claude-harness-capture
description: Show how to launch a Claude Code session through a local logging proxy that writes every API request and response to disk verbatim, where the captures land, their layout, and how to read one. Prints instructions only; runs nothing.
---

You are running the `/claude-harness-tools:claude-harness-capture`
skill. Tell the user how to capture a Claude Code session's API traffic
and how to read the result. Run nothing: a session cannot relaunch
itself through a proxy, so the user starts the captured session from
their own terminal.

## The launch command

The launcher is `bin/ch-capture` in this plugin: two directories above
this skill's base directory, then `bin/ch-capture`. Print it as an
absolute path resolved from the base directory the harness showed when
it loaded this skill. The bare name `ch-capture` and a
`${CLAUDE_PLUGIN_ROOT}` spelling both fail in the user's terminal,
because neither the plugin's `bin/` nor that variable exists there.

```text
<absolute path>/bin/ch-capture [name suffix words...] [-- claude args...]
```

- It moves to the repo root when started inside a git repo.
- Words before `--` name the session; with none, the suffix is a
  `date '+%b%d-%H:%M'` stamp. The session is named
  `<suffix> <repo> [harness-proxy]`, where `<repo>` is the last path
  segment of the `origin` URL minus `.git`, or `(local)` outside a repo
  or without an `origin`.
- Everything after `--` reaches `claude` verbatim. A `--name <v>` or
  `--name=<v>` there replaces the computed name with
  `<v> [harness-proxy]`.
- Requests are forwarded to the `ANTHROPIC_BASE_URL` in force at launch,
  else `https://api.anthropic.com`. The override pointing `claude` at
  the proxy is set for the `claude` child only, and the proxy stops on
  every exit, `Ctrl-C` included.

To isolate one setting's contribution, launch two sessions identically
except for that setting and compare their captures.

## Where captures land

The capture root is
`${XDG_STATE_HOME:-$HOME/.local/state}/claude-harness-tools/captures`.
Each session gets one directory, `<stamp>-<slug>`: a UTC stamp to the
millisecond such as `20260924T153012.123Z`, then the session name
lowercased, with every run of characters other than `a-z` and `0-9`
turned into one `-` and a leading or trailing `-` dropped, so
`my run widget [harness-proxy]` becomes `my-run-widget-harness-proxy`.

```text
<stamp>-<slug>/
  session.json        name, port, cwd, repo, argv, upstream, started_at;
                      session_header once a request carries a header
                      whose name contains "session"
  proxy.log           the proxy's own diagnostics and access log
  000001/             one directory per request, numbered in arrival order
    request.json      method, path, headers, started_at, ended_at, status;
                      error when forwarding or relaying the request failed
    request.body      the request body as received
    response.headers.json   status, reason, and headers from upstream
    response.body     the response body as forwarded
  000002/
  ...
```

Every path is logged, not only `/v1/messages`; filter on `method` and
`path` in `request.json`. `session_header` joins the capture to the
session's transcript under `~/.claude/projects/`.

## Reading a capture

Say these plainly, because each one surprises a first reader:

- **Nothing is parsed or rewritten.** The bodies are the bytes on the
  wire. Parse them in a separate step, never in place.
- **A chunked body keeps its framing.** When `request.json`'s headers or
  `response.headers.json` carry `Transfer-Encoding: chunked`, the body
  is a series of chunks, each a hex size line, that many bytes and a
  CRLF, ended by a `0` size line, any trailer lines and a blank line.
  Strip the framing first, before decompressing or splitting events.
  The exception is a response that has no body whatever its headers
  say, which is one to a `HEAD` request and any `1xx`, `204` or `304`:
  its `response.body` is empty, even beside a `Transfer-Encoding:
  chunked` that upstream sent.
- **Bodies may be compressed.** `Accept-Encoding` is forwarded
  unchanged, so a body is compressed whenever `response.headers.json`
  carries a `Content-Encoding`. Decompress before reading, for example
  `gunzip -c response.body` for `gzip`.
- **A streamed response is the raw event stream.** Split it on blank
  lines into `event:`/`data:` records and join the `content_block_delta`
  payloads to reassemble the message.
- **Credentials are stored as they arrived.** `request.json` holds the
  `Authorization` or `x-api-key` header in clear. Redact a copy before
  sharing or analysing it, and never edit the original.
- **A `request.json` without `ended_at`** belongs to a request that was
  still in flight when the proxy stopped.
- **A 502 may be the proxy's own.** When forwarding fails before
  upstream answers, the proxy answers `502 Bad Gateway` itself:
  `request.json` then carries an `error`, and `response.body` opens with
  `ch-proxy: upstream request failed:`, or is empty for a `HEAD`. An
  upstream 502 has upstream's body, and an `error` only when relaying it
  failed part-way.
