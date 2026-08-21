---
name: tune-auto-mode
description: "Run an unbounded critique loop over this machine's Claude Code autoMode rules: capture the `claude auto-mode critique` prompt through a loopback sink, replay it in this session (no 4K-token answer ceiling), and apply accepted edits to a scratch settings.json copy, writing the live file only at the end after a backup and a validation pass."
---

You are running the `/auto-mode-tools:tune-auto-mode` skill. Critique
and improve the `autoMode` block of the user's Claude Code
`settings.json`, one round at a time, with the human accepting or
rejecting every finding.

`claude auto-mode critique` sends its request with `max_tokens` of
4096, so its own answer is truncated for any sizeable block. This skill
captures that request instead of letting it reach the API and answers
it here, in this session, where no such ceiling applies.

**Run this on a high-end model at high effort.** The skill runs in the
main session and inherits the session's model and effort; it neither
spawns an agent nor overrides either. If the session is on a small
model or low effort, say so and let the human decide before starting.

## Paths

State lives under `$XDG_STATE_HOME/auto-mode-tools/`, defaulting to
`~/.local/state/auto-mode-tools/` (macOS sets no `XDG_STATE_HOME`, so
the default is the path in practice). Resolve it once and use it
throughout:

- `<state>/ledger.yml` — the cumulative decision ledger.
- `<state>/last-run/` — the artifacts of the most recent run.

Concurrent invocations of this skill are **not supported** and it does
not guard against them: there is no lock file and no per-session
directory. Two parallel runs share these paths and corrupt each
other's results. If the human asks for a second run while one is in
flight, tell them to run one at a time. Do not add a lock.

## Procedure

### 1. Read the ledger

If `<state>/ledger.yml` exists, read it and check `schema-version`. It
must be `1`. On any other value, **abort**, naming the file and the
version expected:

```text
<state>/ledger.yml has schema-version <found>; this skill reads
schema-version 1. Aborting rather than reading it as if it matched.
```

If the file does not exist, there are no prior decisions and this is a
first run. That is not an error.

### 2. Stand up the scratch config directory

`CLAUDE_CONFIG_DIR` makes `claude` read `settings.json` from a
directory other than `~/.claude`. Create a scratch directory for this
run and copy the live `~/.claude/settings.json` into it as
`settings.json`.

Every capture and every round runs against **that copy**. Accepted
edits are applied to the copy, never to the live file. The live
`~/.claude/settings.json` is the permission configuration this very
session is enforcing; editing it between rounds would have the loop
rewrite its own enforcement while running, and a bad intermediate round
would degrade the session doing the work.

Confirm the scratch directory is the one `claude` reads before going
further:

```bash
CLAUDE_CONFIG_DIR=<scratch> claude auto-mode config
```

### 3. Capture the critique prompt

The capture runs on **every** invocation. Nothing is cached and no
captured prompt is committed into the plugin: the classifier prompt,
the built-in rules and the tool descriptions all change with Claude
Code releases, and a stale captured prompt produces a
plausible-looking critique against an obsolete baseline.

Start the sink, which prints its base URL on stdout and also writes it
to `<run-dir>/sink-url`:

```bash
/usr/bin/python3 "${CLAUDE_PLUGIN_ROOT}/payload/sink.py" \
  --run-dir <state>/last-run
```

Then run the critique against it, with a dummy key so no real
credential is sent to the local socket:

```bash
CLAUDE_CONFIG_DIR=<scratch> \
ANTHROPIC_BASE_URL=<sink-url> \
ANTHROPIC_API_KEY=auto-mode-tools-dummy-key \
  claude auto-mode critique
```

The sink writes the request body to
`<state>/last-run/critique-request.json` and exits. The prompt is the
one user message in that body. If the sink exits non-zero, or the file
is absent, stop and report — do not fall back to writing a critique
prompt of your own.

### 4. Fetch the built-in rules

```bash
CLAUDE_CONFIG_DIR=<scratch> claude auto-mode defaults
```

Save the output to `<state>/last-run/defaults.json`. A finding about a
custom rule is only judgeable against the shipped rules it sits beside.

### 5. Run a round

Feed yourself, in one context:

- the captured critique prompt,
- the built-in rules from step 4,
- the **whole** `settings.json` from the scratch copy —
  `permissions.allow`, `permissions.ask`, `permissions.deny` and the
  `autoMode` block together, because a rule's correctness depends on
  what the permission lists already cover, and
- the ledger's **rejected** findings with the reasons given.

Present the round's findings to the human. For each finding, give:

- the rule it touches, by label,
- the proposed edit, and
- the reasoning.

The human accepts or rejects each one. Apply accepted edits to the
scratch copy. Write **every** decision — accepted and rejected alike —
to the ledger with the reason given. Key each entry on the rule's
**label**, not on a position or an index, so the decision survives
reordering or a later rewrite of the block.

Write the round's transcript and its proposed-edit set into
`<state>/last-run/`.

### 6. Loop or stop

Run another round unless one of these holds:

- the human says stop, or
- the round produced **no accepted findings**.

A round whose findings were all rejected is a round with no accepted
findings, and therefore terminates the loop.

### 7. Write the live file

Show the human the full diff between the live `~/.claude/settings.json`
and the scratch copy, and get an explicit approval. Then, in this
order:

1. Take a **timestamped backup** of the existing
   `~/.claude/settings.json`, and tell the human its path.
2. Verify the candidate passes
   `CLAUDE_CONFIG_DIR=<scratch> claude auto-mode config` without error.
3. Only then write the scratch copy over the live file.

If either the approval or the validation does not come, leave the live
file untouched and say where the scratch copy is.

The tuned `autoMode` block carries only `environment`, `allow`,
`soft_deny` and `hard_deny`. Do not write provenance into
`settings.json` — Claude Code strips `//`-prefixed keys whenever it
rewrites that file itself, so the last revision, the hash of the
captured prompt and when the tuner last ran all live in `<state>/`
beside the ledger.

### 8. Write the PR body

As the last act of the run, write a ready-to-use PR body into
`<state>/last-run/`: the accepted findings with the human's reasons,
and the rejected ones with theirs. Landing the tuned `settings.json`
on a branch of a config repo is then an ordinary `git-tools` plus
`github-prs` operation, and this skill opens no PR itself.

## Retention

`<state>/last-run/` holds the **last run only**, where a run is one
invocation of this skill including every round inside it — not the last
round. Clear it at the start of a run.

The ledger is the exception: it is **cumulative**, accumulating across
every run and never truncated. Feeding prior rejections into a later
round is the whole point of keeping it.

## Independence

This skill does not depend on `/auto-mode-tools:personalize-auto-mode`
and never reads the facts file. It must work when no facts file
exists, because it is usable by anyone who received a tuned
`settings.json` and never wrote facts of their own. There is no
ordering contract between the two skills.
