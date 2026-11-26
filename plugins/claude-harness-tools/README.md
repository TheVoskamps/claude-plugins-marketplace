# claude-harness-tools

Shows what the Claude Code harness sends to the API, by launching a
session through a local logging proxy that writes every request and
response to disk byte for byte.

## Why you would want it

The assembled system prompt reaches a session as one flat concatenation
with no provenance markers. A session cannot tell which setting injected
which text, and grepping the harness bundle yields static strings with
no indication of which is used in which context. When the harness
changes what it sends, hand-written rules and prompts go stale against
it with nothing to show the change.

A capture makes that visible. Launch two sessions identically except for
one setting, and the difference between their captures is that setting's
contribution.

## What you need first

- The `claude` CLI on `PATH`.
- `bash` and `python3`. The versions a stock macOS ships, bash 3.2 and
  Python 3.9, are enough, and nothing else is installed.

## Getting started

Ask a session for the launch command:

```text
/claude-harness-tools:claude-harness-capture
```

The skill prints the launcher's absolute path, where captures land,
their layout and how to read one. It runs nothing: a session cannot
relaunch itself through a proxy, so you start the captured session from
your own terminal.

```text
<absolute path>/bin/ch-capture [name suffix words...] [-- claude args...]
```

- Words before `--` name the session. With none, the name carries a
  date stamp instead.
- Everything after `--` reaches `claude` unchanged, and `claude`'s exit
  status is the launcher's.
- The proxy stops when the session ends, however it ends, `Ctrl-C`
  included.

What the launcher does to the session:

- **It works outside a repository.** Inside one it moves to the repo
  root and puts the repo's name, taken from `origin`, in the session
  name. Outside one, or without an `origin`, the name says `(local)`.
- **It ends the session name in `[harness-proxy]`**, so a captured
  session is recognizable in Claude Code's session list and can be
  matched to its capture by eye. A `--name` you pass after `--` replaces
  the computed name and gets the same suffix.
- **It inherits `ANTHROPIC_BASE_URL`.** Requests are forwarded to the
  value in force at launch, or to `https://api.anthropic.com` without
  one, so a session that already goes through a gateway is captured
  through that gateway. The override that points `claude` at the proxy
  applies to that `claude` process only; your shell keeps its value.

## Where captures land

Captures live under
`${XDG_STATE_HOME:-$HOME/.local/state}/claude-harness-tools/captures`,
one directory per session. The directory is named by a UTC millisecond
stamp, then the session name as a slug, and it carries that name from
the moment the session starts. The stamp sorts sessions by launch time.

Inside it, `session.json` describes the launch, `proxy.log` holds the
proxy's own diagnostics, and each request has a numbered directory, in
arrival order, with its metadata, headers and both bodies. Every path
the session requests is captured, so filter on the method and path in
each request's `request.json`.

## What a capture contains

A capture is the traffic as it crossed the wire. Nothing is parsed or
rewritten on the way through, so two captures differ only where the
traffic did. That has consequences when you read one:

- **Bodies stay compressed.** A response body is compressed whenever
  its headers carry a `Content-Encoding`; decompress a copy before
  reading it.
- **Credential headers are stored verbatim.** `request.json` holds your
  API key or token in clear. Treat a capture as sensitive, and redact a
  copy before sharing it.
- **Chunk framing is kept.** A body sent with `Transfer-Encoding:
  chunked` still has its chunk size lines in it; strip them before
  decompressing or splitting events.
- **A `502` or a `400` may be the proxy's own answer.** The proxy
  answers `502` when no upstream response exists and `400` when a
  request's body framing cannot be read, and marks either with an
  `error` in `request.json`. Every status upstream sends passes through
  unchanged.
- **A `request.json` with no `ended_at`** belongs to a request that was
  still in flight when the proxy stopped.

A failure to write a capture never changes what the session receives:
it is reported in `proxy.log`, and the response goes through as upstream
sent it.

## Limits

- **It captures the `claude` CLI, not the Claude desktop app.** The
  launcher wraps the CLI and nothing else.
- **It does no TLS interception.** None is needed: the session is
  pointed at the proxy through its base URL, so no certificate is
  installed or trusted.
- **No verb reads captures yet.** Comparing two captures or replaying
  one is done with your own tools.
- **It leaves a host `cr()` wrapper unchanged.** If your shell has one,
  the launcher stands beside it rather than replacing it.
