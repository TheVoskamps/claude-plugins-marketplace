# claude-harness-tools

Instruments for seeing what the Claude Code harness sends to the API.

The plugin exists because the assembled system prompt reaches a session
as one flat concatenation with no provenance markers. A session cannot
tell which setting injected which text, and grepping the harness bundle
yields static strings with no indication of which is used in which
context. When the harness changes what it sends, hand-written rules and
prompts go stale against it with nothing to show the change.

The instrument is a capture: a session launched through a local logging
reverse proxy leaves every request it assembled and every response it
received on disk, byte for byte. Two sessions launched identically
except for one setting can then be compared, and the difference between
their captures is that setting's contribution.

## Contents

- **`skills/claude-harness-capture`** — the user-facing surface. It
  prints the launch command, where captures land, their layout and how
  to read one, and runs nothing: a session cannot relaunch itself
  through a proxy, so the user starts the captured session from their
  own terminal. It prints the launcher as an absolute path resolved from
  its own base directory, because neither the plugin's `bin/` nor
  `${CLAUDE_PLUGIN_ROOT}` exists in that terminal.
- **`bin/ch-capture`** — the launcher. It starts the proxy, points a
  `claude` child at it, and stops the proxy on every exit path.
- **`bin/ch-proxy.py`** — the proxy. It forwards to an upstream base URL
  and writes the traffic beneath a capture directory.
- **`test/`** — loopback suites for both commands.

The plugin name is a bucket. A verb that reads captures — a diff of two
sessions, a replay — belongs here under the same name, and nothing
above needs renaming to make room for it.

## Where captures land

Captures are state about a session, so the root is
`${XDG_STATE_HOME:-$HOME/.local/state}/claude-harness-tools/captures`.
The launcher fixes the session directory's name — a UTC millisecond
stamp, then the slugified session name — before `claude` starts, and
creates it under that name. No directory is created under a placeholder
and renamed, so a directory listing during a session already shows the
name it will keep. The stamp orders sessions and keeps two launched in
the same second apart; the slug makes the listing readable.

## Decisions in the proxy

Each of these is a constraint the code carries; the reason is here
because the code cannot show it.

- **A reverse proxy addressed by base URL, not an HTTP `CONNECT`
  proxy.** The client speaks plain HTTP to a loopback port and the proxy
  opens its own TLS connection upstream, so no certificate is trusted
  anywhere and the one knob the harness offers, `ANTHROPIC_BASE_URL`,
  is the whole hook. This is also why TLS interception is out of scope:
  it would buy nothing the base URL does not already give.

- **Nothing is parsed, decompressed, re-serialized or redacted on the
  way through.** A parser in the hot path re-serializes JSON and
  manufactures differences between two captures that the traffic never
  had, and a capture cannot be re-taken for a session that has ended.
  The consequences are deliberate and each one surprises a first
  reader: `Accept-Encoding` goes upstream unchanged, so bodies come back
  compressed; credential headers are stored as they arrived, so
  redaction is a step applied to a copy before analysis, never a
  mutation at write time; and a chunked response keeps its chunk
  framing in `response.body`, which the proxy reads off the socket
  beneath `http.client` because `http.client` would strip it.

- **A chunked request body is forwarded length-framed.**
  `Transfer-Encoding` describes one connection, not the message, so the
  proxy de-chunks the body it received and sends it upstream under a
  `Content-Length`; `Expect: 100-continue` is dropped for the same
  reason, the client-side server having already answered it. The
  recorded `request.body` is still the wire bytes the client sent,
  framing included.

- **Threaded, with a lock-assigned counter.** A session fanning out
  subagents has several requests in flight at once, and serializing
  them changes agent scheduling and can time requests out. Request
  directories are numbered by a counter taken under a lock, so the
  directory order is wire order even across a fan-out.

- **Streamed, with a flush per chunk.** Buffering a server-sent-events
  response stalls the client until upstream closes, which changes the
  session being measured.

- **Every path is logged.** The method and path are in each request's
  metadata; filtering is the reader's job, not the proxy's.

- **Recording fails open.** A filesystem or serialization error while
  writing a capture is reported on stderr, which the launcher directs
  to `proxy.log` in the session directory, and never alters the
  response the client receives. An upstream response of any status
  passes through unchanged. The proxy answers only two failures itself:
  `502` when no upstream response exists at all, and `400` when a
  request's body framing cannot be read. The `400` guards against what
  `int()` alone would accept — a sign, underscores, surrounding
  whitespace — because a `Content-Length` of `-1` makes the body read
  wait for the client to hang up.

- **`request.json` is written twice, each time atomically.** Once at
  arrival and once at the end, through a temporary file and a rename,
  so a proxy stopped mid-request leaves the arrival version rather than
  a half-written file, and a request with no `ended_at` is one that was
  still in flight.

- **`session.json` is written before the port is printed.** The
  launcher reads the port as the proxy's first stdout line and treats
  it as the signal that the proxy is serving, so the file a reader
  opens first is complete by the time any request can arrive. The first
  request header whose name contains `session` is added to it, which is
  the join to the transcript under `~/.claude/projects/`.

- **Standard library only, and no syntax newer than Python 3.9**, so a
  stock macOS `/usr/bin/python3` runs it with nothing installed.

## Decisions in the launcher

- **`cr()`-shaped**, as `plugins/claude-vm/bin/claude-vm` is: move to
  the repo root, take the repo name from `origin`, and name the session
  from the leading words or a date stamp. Unlike `claude-vm`, a
  directory with no repo or no `origin` is fine; the repo name is then
  `(local)`, because a capture of a session outside any repo is as
  useful as one inside.

- **The session name ends in `[harness-proxy]`**, whether computed or
  supplied through `--name`, so a captured session is recognizable in
  Claude Code's own session list and a capture can be matched to it by
  eye. A caller's `--name` wins over the computed name and is tagged in
  place.

- **The upstream is the `ANTHROPIC_BASE_URL` in force at launch**, or
  `https://api.anthropic.com` without one, so a session that already
  goes through a gateway is captured through that gateway rather than
  around it. The override pointing `claude` at the proxy is a prefix
  assignment on the `claude` command, so it exists in the child's
  environment only and the caller's shell keeps whatever value it had.

- **One trap string, installed once on `EXIT INT TERM`.** A second
  `trap` on any of those signals replaces the first handler rather than
  adding to it, so every teardown step lives in the one string. It
  disarms itself, stops the proxy, and exits with the status in force
  when it fired, so `claude`'s own exit status is the launcher's.

- **Portable to the bash 3.2 macOS ships**: no associative arrays, no
  `${var,,}`, and empty arrays expanded through `${a[@]+"${a[@]}"}`.

## Deliberately out of scope

Each of these is a decision, not an omission to repair:

- **The Claude desktop app.** The launcher wraps the `claude` CLI.
- **TLS interception with a locally trusted CA.** The base URL is
  enough, per the first decision above.
- **The reading verbs.** A diff of two captures and any replay are
  later skills in this bucket; the capture exists so they have
  something to read.
- **Any change to a host `cr()` wrapper.** The launcher stands beside
  one rather than replacing it.

## Tests

Both suites drive the real commands over loopback and reach no real
API.

- `test/ch-proxy-test.py`, run as `/usr/bin/python3
  test/ch-proxy-test.py`, starts `ch-proxy.py` as a subprocess against
  an in-process plain-HTTP upstream and grades both what the client
  received and what landed on disk: the `session.json` fields and the
  first `*session*` header only; bodies matching the wire byte for byte,
  a gzip body staying compressed; credential headers, `Accept-Encoding`
  and base-path joining reaching upstream unchanged; the request files
  for a `POST` and for a `HEAD`; an upstream error status passing
  through and a `502` for an unreachable upstream; a server-sent event
  reaching the client before upstream has finished; two requests in
  flight together, the upstream held on a two-party barrier; directory
  numbering in arrival order; and an unwritable capture directory
  leaving the response unchanged. A case no subprocess argument can
  reach loads the proxy as a module instead.

  The negative control is a copy of the proxy with the response fully
  buffered and the server single-threaded: the streaming and
  concurrency cases fail against it, so a green run measures the proxy
  and not the fixture.

- `test/ch-capture-test.sh`, run as `/bin/bash test/ch-capture-test.sh`,
  drives `ch-capture` against a stub `claude` that records its argv and
  environment. Each case gets its own `XDG_STATE_HOME`, so the capture
  root holds exactly the session directory that case created; the one
  case whose stub sends a request points the upstream at a dead port.
  It checks the computed name and both spellings of `--name`, the
  arguments after `--` reaching `claude` unchanged, the repo-root cwd
  and `(local)` with a date-stamp suffix, the default and inherited
  upstreams, the child's `ANTHROPIC_BASE_URL` pointing at the proxy,
  the session directory stamp and slug, exit-status propagation, and
  the proxy stopped after a normal exit, an error exit, `SIGINT` to the
  process group and `SIGTERM`.

  The negative control is the launcher with its trap removed: every
  proxy-stopped case fails against it.
