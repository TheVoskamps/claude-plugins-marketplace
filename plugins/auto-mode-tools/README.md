# auto-mode-tools

Tools for working on the `autoMode` block of a Claude Code
`settings.json` — the rules the auto mode classifier evaluates every
tool call against.

The plugin exists because `claude auto-mode critique` sends its
critique request with `max_tokens` of 4096, read off the body the sink
below captured. A large `autoMode` block can therefore never receive a
complete critique from that command: the answer is truncated at the
ceiling. `/tune-auto-mode` captures the critique request instead of
letting it reach the API, and replays it through the current Claude
Code session, which has no such ceiling.

## Skills

- **`tune-auto-mode`** — the critique loop: capture the critique
  prompt, run rounds against a scratch config copy, and write the live
  `settings.json` only at the end, after the human approves.
- **`personalize-auto-mode`** — rewrite an existing `autoMode` block
  against this machine's facts: names, organizations, SSO profiles,
  repositories and paths.

Neither skill depends on the other. `/tune-auto-mode` works when no
facts file exists, because it is usable by anyone who received a tuned
`settings.json` and never wrote facts of their own.
`/personalize-auto-mode` works on an `autoMode` block that has never
been tuned. There is no ordering contract between them and neither
reads the other's state; in particular `/personalize-auto-mode` does
not read the ledger.

## The sink

`payload/sink.py` is a loopback-only HTTP sink bound to an ephemeral
port. It never makes an upstream call and never forwards anything: it
writes the received request body to the run directory, returns a
minimal well-formed response so the invoking CLI exits cleanly, and
terminates.

`/tune-auto-mode` starts it **in the background**, then runs `claude
auto-mode critique` in the same shell with `ANTHROPIC_BASE_URL` pointed
at it and `ANTHROPIC_API_KEY` set to a dummy value, so no real
credential is sent to the local socket. The backgrounding is not
optional: the sink serves until it captures a body or its timeout
expires, so a foreground launch never reaches the critique command and
the capture cannot happen at all.

```bash
/usr/bin/python3 "${CLAUDE_PLUGIN_ROOT}/payload/sink.py" --run-dir <dir> &
```

It prints the base URL on stdout and also writes it to `<dir>/sink-url`,
then serves until it captures a body into `<dir>/critique-request.json`
— `--body-file` renames that file, and the test reads the same default
off the module's `DEFAULT_BODY_FILE`. If no request reaches it for
`--timeout` seconds (default 180) it gives up, reports that on stderr
and exits non-zero, so a critique that never started cannot leave the
caller waiting on a sink that never returns.

Standard library only, and no syntax newer than Python 3.9, so a stock
macOS `/usr/bin/python3` runs it with nothing installed. That matches
the constraint the repo's existing **host-side** Python already works
under: the inline `python3 -c` scripts in
`plugins/claude-vm/payload/lib/credential.sh`, and in its test under
`plugins/claude-vm/payload/test/`, run on the macOS host and target
that same stock interpreter — each calls bare `python3` and each says
in its own header that it requires no more than the one macOS ships.
The `python3 -c` blocks in
`plugins/claude-vm/payload/provisioners/podman-mkosi.sh` are not that
precedent: they run inside the Debian build container, on the
interpreter that image installs, so they say nothing about what macOS
ships.

What is new here is the first `.py` *file*, not the first Python. It
adds no lint configuration, the repo declaring none for Python, but it
does change what CI runs: `.github/scripts/codeql-language-present.sh`
arms the `python` analysis leg whenever a tracked, non-vendored `*.py`
file is present, so `codeql.yml` analyzes Python on every PR from here
on.

### Why the sink is not a one-request server

The obvious design — answer exactly one request and exit — does not
work, and the failure is silent-looking rather than loud: the CLI opens
with a bodyless `HEAD /api/hello` reachability preflight, and a sink
that spends its single request on that preflight leaves the CLI
reporting `Failed to analyze rules: Connection error.` with nothing
captured. So the sink answers every **bodyless** request with `200 {}`
and keeps serving; only a request that carries a body is the capture,
and the sink stops after it.

### Why the sink answers two response shapes

The critique request measured today carries no `stream` key, so the
answer it wants is an ordinary JSON `message`. The sink reads the
captured body and answers a streaming request with a complete
Server-Sent Events stream (`message_start` through `message_stop`) and
a non-streaming one with the JSON message. Which shape the CLI asks for
is not a contract this plugin controls — it changes with Claude Code
releases — so the sink covers both rather than pinning the current one.

### Tests

`payload/test/sink-test.py` is stdlib-only and directly executable. It
drives the real sink over loopback: starts it, POSTs a body, and
asserts that the body landed in the run directory verbatim and that the
answer it got back is a well-formed Messages-API response of the shape
the request asked for. It covers the preflight, the streaming shape
(graded event by event, `message_start` first and `message_stop` last)
and the non-streaming shape.

```bash
/usr/bin/python3 plugins/auto-mode-tools/payload/test/sink-test.py
```

The test does not run `claude auto-mode critique`. What it pins is the
sink's own contract; that the real CLI drives it end to end was
established by running the real command against the real sink.

## Isolation: every round runs in a scratch config dir

`CLAUDE_CONFIG_DIR` makes `claude` read `settings.json` from a
directory other than `~/.claude`. This is verified: with a
`settings.json` in `$D` carrying a sentinel `autoMode.environment`
entry, `CLAUDE_CONFIG_DIR=$D claude auto-mode config` prints the
sentinel and exits 0.

`/tune-auto-mode` therefore copies `~/.claude/settings.json` into a
scratch config directory and runs every capture and every round against
that copy. Accepted edits are applied to the copy, not to the live
file. The live `~/.claude/settings.json` is the permission
configuration the running session is enforcing; editing it between
rounds would have the loop rewrite its own enforcement while running,
and a bad intermediate round would degrade the very session doing the
work.

The live file is written only at the end, after the human approves, and
only after a timestamped backup of the existing
`~/.claude/settings.json` is taken and the candidate file passes
`claude auto-mode config` against the scratch directory without error.

`/personalize-auto-mode` writes the same file, so it carries the same
protections in the same order.

## Machine-local state

Everything the tuner keeps between runs lives under
`$XDG_STATE_HOME/auto-mode-tools/`, defaulting to
`~/.local/state/auto-mode-tools/` — macOS sets no `XDG_STATE_HOME`, so
the default is the path this will use in practice.

Concurrent `/tune-auto-mode` invocations are not supported, and the
skill does **not** guard against them: there is no lock file and no
per-session directory. Two parallel runs share the paths below and will
corrupt each other's results, and the answer is to run one at a time.
This is written down so the shared fixed paths are read as a decision
rather than as an oversight to fix.

### The ledger

`~/.local/state/auto-mode-tools/ledger.yml` carries a `schema-version`
key that starts at `1` and that the reader gates on: on any other
value the skill aborts, naming the file and the version it expected,
rather than reading the file as if it matched.

The ledger is **cumulative** — it accumulates across every run and is
never truncated, which is the whole point of feeding prior rejections
into a later round. The last-run-only retention below applies to the
run artifacts and not to it.

It is machine-local and does not travel with `settings.json`: a
recipient of a tuned config who dislikes what they got re-runs the
tuner rather than inheriting someone else's decisions.

It cannot live inside `settings.json`, because Claude Code strips
`//`-prefixed keys whenever it rewrites that file itself. The same
constraint applies to all of the tuner's provenance, so that lives
beside the ledger too — in `provenance.yml`, below — and the `autoMode`
block ends up carrying only `environment`, `allow`, `soft_deny` and
`hard_deny`.

Each ledger entry keys on the rule's label rather than on a position or
an index, so a decision survives reordering or a later rewrite of the
block.

### Provenance

`~/.local/state/auto-mode-tools/provenance.yml` holds the provenance
`settings.json` cannot carry: `revision`, the revision number of the
tuned block; `prompt-sha256`, the SHA-256 of the captured critique
prompt that produced it; and `last-run`, the UTC timestamp of the run
that wrote it. It carries a `schema-version` key gated exactly as the
ledger's is.

`/tune-auto-mode` writes it as the last step of writing the live file,
reading the previous `revision` back to increment it. A run that leaves
`~/.claude/settings.json` untouched writes no provenance, because a
revision that names no write names a block nobody has.

A record therefore names the block **this tuner last wrote**, not
whatever `settings.json` holds now. `/personalize-auto-mode` writes the
same file and writes nothing to the state directory, so once it has
run, `revision` and `prompt-sha256` describe a block that has since
been rewritten. That is a decision rather than an oversight: having the
personalizer bump the revision would claim a critique round it never
ran, and having it read the state directory would end the independence
the two skills are built on. Read the record as the tuner's own
history, and re-run the tuner if you want provenance for what is in the
live file today.

### Run artifacts

`~/.local/state/auto-mode-tools/last-run/` retains the last run only,
where a run is one `/tune-auto-mode` invocation including every round
inside it — not the last round. It holds the captured critique prompt
(`critique-request.json`), the URL the sink bound (`sink-url`), the
built-in rules as fetched (`defaults.json`), the per-round transcripts,
and the proposed-edit sets.

As its last act, `/tune-auto-mode` writes a ready-to-use PR body into
that directory: the accepted findings with the human's reasons and the
rejected ones with theirs. This makes landing the tuned
`settings.json` on a branch of a config repo an ordinary `git-tools`
plus `github-prs` operation needing no skill of its own.

## The facts file

`$XDG_CONFIG_HOME/auto-mode-tools/facts.yml`, defaulting to
`~/.config/auto-mode-tools/facts.yml`. It carries a `schema-version`
key that starts at `1` and that the reader gates on with the same abort
as the ledger: on any other value, abort naming the file and the
expected version. It is the input to `/personalize-auto-mode` and is
machine- and user-specific.

The shape is a hybrid, and the split is deliberate:

- **Structured keys for anything enumerable.** These appear verbatim
  inside the environment paragraphs and must be reproduced exactly;
  free prose invites a model to drop a list member or paraphrase a
  profile name, with nothing to catch it.
- **One free-prose `notes:` field** for what is not enumerable — "I no
  longer work on that project", "this laptop is one-employer-only",
  "everything under `~/scratch` is disposable".

The full schema, with placeholder values — no machine's real facts
ship in the plugin, so this documentation uses placeholders throughout:

```yaml
schema-version: 1

identity:
  display-name: "Ada Lovelace"
  github-login: alovelace
  email: ada@example.org

bots:
  - display-name: "Claude for Ada"
    github-login: claude-for-alovelace
    email: ada+claude@example.org

organizations: [ExampleOrg, OtherOrg]

sso-profiles: [example-dev, example-prod]

public-repositories:
  - ExampleOrg/public-thing

scratch-globs: ["~/scratch/**"]
worktree-globs: ["**/.claude/worktrees/**"]

notes: |
  Free prose for what the keys above cannot enumerate.
```

`skills/personalize-auto-mode/SKILL.md` inlines that same block
verbatim — it is what the skill shows the human when no facts file
exists — so a schema change edits both copies.

These properties of that schema are load-bearing:

- **`bots` is a list of records, not three parallel lists.** A rule
  matching a bot generally needs its login and its email to agree, and
  parallel lists let those drift out of alignment with nothing to
  detect it.
- **`identity` and each `bots` entry carry the same three key names**,
  so the personalizer reads one shape twice rather than two shapes.

`organizations` and `sso-profiles` are deliberately flat lists of bare
names. An SSO profile may map to several accounts or to a shared role,
so attaching an account or a role to it would record something that is
not a function of the profile. `public-repositories` holds
`owner/repo` strings, self-scoping and independent of the
`organizations` list. `scratch-globs` and `worktree-globs` are separate
keys because the tuned rules treat disposable scratch space and
worktrees differently.

The environment entries are dense paragraphs, not templates, so
personalizing one is a rewrite rather than a token substitution. The
structured keys give the rewrite exact lists to place; the prose gives
it the rest to reason from.

## Genericity

The facts the plugin tunes against never ship inside it.
Organizations, hosts, SSO profiles, repository lists and paths come
from the facts file or from the `autoMode` block being tuned; the
plugin supplies only the harness.

The `author` block in `.claude-plugin/plugin.json` is outside that
claim and stays. It names the plugin's maintainer, as every plugin in
this marketplace does, and no skill reads it — it is not a fact any
rule is tuned against.

## Deliberately out of scope

Each of these is a decision, not an omission to repair:

- **A skill that opens the config-repo PR.** The PR body artifact above
  makes the manual path a one-liner; revisit only if that turns out to
  be frequent.
- **An `update-auto-mode` skill** reconciling a block against a changed
  shipped baseline.
- **Comparing critique quality across models and effort levels.** That
  needs a way to measure a tuned config — a corpus of tool calls with
  expected verdicts, replayed after each edit — which does not exist
  yet, and without it the comparison has nothing to compare on.
- **Any guard against concurrent `/tune-auto-mode` runs**, per
  *Machine-local state* above.
