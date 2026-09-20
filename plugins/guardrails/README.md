# guardrails

A compiled `PreToolUse` hook that inspects every tool call Claude Code
is about to make and, where it can settle the question from the call
alone, allows it, denies it with a redirect, or holds it for a human
click — before any prompt, allow-list or model judge sees it.

## Why

Claude Code's own permission handling is a static allow-list plus, in
auto mode, an LLM judge reading the call in context. That stack is good
at judgment and poor at two other things: refusing a known-bad call
with an explanation the model can act on, and reserving a fixed set of
actions for a human click that no allow-list entry and no judge is
meant to waive. This plugin supplies both, and it takes the calls it
can prove harmless off the judge's plate entirely, so the ordinary hot
path of a session costs no prompt and no evaluator round-trip. Which
actions fall where, and why, is in
[`plugins/guardrails/hooks/permission-gate/README.md`](hooks/permission-gate/README.md).

## What changes in a session

Every `Bash`, `Read`, `Write`, `Edit`, `MultiEdit` and `NotebookEdit`
call, and every `mcp__*` tool call, passes through the gate before
Claude Code's normal permission handling. What the gate does with a
given call — what it allows, denies, holds for you, or passes through
with no opinion — is not restated here: run a session with the plugin
installed to see it, or read the permission-gate README and the gate's
source under `hooks/permission-gate/`.

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

One optional file exists, `~/.config/guardrails/config.yml`, which
nothing installs and you write yourself. What it is for, its format,
and what it can and cannot relax are in the permission-gate README,
which is the component document for the gate itself: the verdict
model, what each verdict guarantees, and how to build, test and rebuild
the binaries.

## Limits

**The plugin only works on a platform with a committed binary, and it
fails closed everywhere else.** Binaries are committed under
`hooks/bin/` for `darwin-arm64`, `linux-amd64` and `linux-arm64`. On
any other platform, `hooks/hooks.json` finds no executable gate for the
running `uname` and denies every matched tool call — every `Bash`,
`Read`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit` and `mcp__*` call.
A session on such a platform cannot do anything until a binary for it
is built and committed per the permission-gate README, which also
lists the other conditions under which `hooks/hooks.json` denies rather
than runs the gate. This is deliberate — a gate that cannot run must
block rather than step aside — but it means installing this plugin on
an unsupported platform stops the session rather than degrading it.

**It is not the whole permission stack.** The gate decides only what
it can settle better than a model can, and deliberately passes the
judgment middle to the downstream auto mode evaluator with no opinion,
rather than spending a human prompt on it. That posture assumes a tuned
auto mode configuration is there to catch what it passes through;
without one, those calls fall to whatever your allow-list and prompt
settings do with them. The
[`auto-mode-tools`](../auto-mode-tools/README.md) plugin is the other
half: it tunes and personalizes that configuration.
