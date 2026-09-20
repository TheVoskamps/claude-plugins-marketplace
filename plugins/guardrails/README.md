# guardrails

A compiled `PreToolUse` hook that inspects every tool call Claude Code
is about to make and, where it can settle the question from the call
alone, allows it, denies it with a redirect, or holds it for a human
click — before any prompt, allow-list or model judge sees it.

## Why

Claude Code's own permission handling is a static allow-list plus, in
auto mode, an LLM judge reading the call in context. That stack is good
at judgment and poor at two other things: refusing a known-bad call
with an explanation the model can act on, and reserving some actions
— publishing, a history-destroying push, reading or minting a
credential — for a human click that no allow-list entry and no judge
is meant to waive. This plugin supplies both, and it takes the proven
read-only and repo-contained calls off the judge's plate entirely, so
the ordinary hot path of a session costs no prompt and no evaluator
round-trip.

It is also the containment layer the OS sandbox cannot provide: a
write that escapes the worktree, or a read or write into another
repository, is blocked with a message naming where the file belongs
instead.

## What changes in a session

Every `Bash`, `Read`, `Write`, `Edit`, `MultiEdit` and `NotebookEdit`
call, and every `mcp__*` tool call, passes through the gate first.
Four things can happen to it:

- **Allowed outright**, with no prompt. Read-only commands, and writes
  that stay inside the current repo or worktree, mostly land here.
- **Denied with a redirect.** The reason is fed back to the model,
  which names the sanctioned way to do what it was trying to do, so
  the model corrects itself on its next call.
- **Held for you.** A short, fixed set of actions prompts rather than
  being judged, and is meant to prompt whatever your allow-list or
  auto mode configuration would have decided.
- **Passed through with no opinion.** Everything the gate cannot
  settle statically goes to Claude Code's normal permission handling
  exactly as if the plugin were not installed.

Every deny, hold and pass-through is appended to
`~/.claude/logs/permission-gate.jsonl` (`PERMISSION_GATE_LOG`
overrides the path) with the gate's account of what it could and could
not establish; allows are not logged. The pass-through rows are the
useful half: they show what your auto mode rules are being asked to
judge.

## Using it

Install it like any plugin from this marketplace:

```text
/plugin install guardrails@thevoskamps
```

There is no skill and no command. The hook registers itself from
`hooks/hooks.json` and runs on every matched call; there is nothing to
configure for it to work. The policy is compiled into the binary, so
there is no rule file to edit — a change of policy is a source change
and a rebuild, not a setting.

One optional file exists: `~/.config/guardrails/config.yml` lists
paths under your config home, state home or home directory that the
gate allows access to. It is absent by default and ships no entries;
it is for the case where containment otherwise blocks a plugin's own
per-user config, which happens when `~/.config` is a symlink into a
dotfiles repository. Its format, and what it can and cannot relax, are
in
[`plugins/guardrails/hooks/permission-gate/README.md`](hooks/permission-gate/README.md),
which is the component document for the gate itself: the verdict
model, what each verdict guarantees, the one guarantee it states as
design intent rather than as a measured property, and how to build,
test and rebuild the binaries.

## Limits

**The plugin only works on a platform with a committed binary, and it
fails closed everywhere else.** Binaries are committed under
`hooks/bin/` for `darwin-arm64`, `linux-amd64` and `linux-arm64`. On
any other platform, `hooks/hooks.json` finds no executable gate for the
running `uname` and denies every matched tool call — every `Bash`,
`Read`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit` and `mcp__*` call
— each with a message on stderr naming the path it looked for. A
session on such a platform cannot do anything until a binary for it is
built and committed per the permission-gate README. The same denial
applies when a binary is present but cannot run: wrong architecture,
a corrupt or truncated file, a missing executable bit, a `noexec`
mount. This is deliberate — a gate that cannot run must block rather
than step aside — but it means installing this plugin on an
unsupported platform stops the session rather than degrading it.

**It is not the whole permission stack.** The gate decides only what
it can settle better than a model can, and deliberately passes the
judgment middle — an unrecognized program, a remote mutation, a
context-dependent operation — to the downstream auto mode evaluator
with no opinion, rather than spending a human prompt on it. That
posture assumes a tuned auto mode configuration is there to catch what
it passes through; without one, those calls fall to whatever your
allow-list and prompt settings do with them. The
[`auto-mode-tools`](../auto-mode-tools/README.md) plugin is the other
half: it tunes and personalizes that configuration.

**A broad static allow rule in `settings.json` gets there first.** A
`Bash(<prog>:*)`-shaped allow matches a passed-through call before auto
mode sees it, so the gate's pass-through is only as safe as your
allow-list is narrow.
