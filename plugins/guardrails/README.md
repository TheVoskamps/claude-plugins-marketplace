# guardrails

A compiled `PreToolUse` hook that inspects every gated tool call Claude
Code is about to make and, where it can settle the question from the call
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
path of a session costs no prompt and no evaluator round-trip.

## What changes in a session

Every `Bash`, `Read`, `Write`, `Edit`, `MultiEdit` and `NotebookEdit`
call, and every `mcp__*` tool call, passes through the gate before
Claude Code's normal permission handling. The gate sorts each call by
what it can settle better than a model reading the call in context, not
by how confident it is, and gives one of these outcomes:

- **Deny, with a redirect.** A known-bad call that has a sanctioned
  alternative, such as a read that resolves into another repository.
  The reason names what to do instead and is fed back to
  the model, which corrects itself on its next call.
- **Allow.** A call the gate can prove harmless: a read-only operation,
  or a write confined to the current worktree or the session
  scratchpad. It runs with no prompt and no evaluator round-trip.
- **Hold for your click.** A short, fixed set of actions that policy
  reserves for a human: publishing (`gh release create`, a gist, a
  repository visibility change), a history-destroying `git push`, and
  reading or minting a credential with `gh` or `aws`.
- **No opinion.** Everything else, including whatever the gate cannot
  classify from the call alone. The call goes on to your allow-list and
  the auto mode evaluator exactly as it would without the plugin.

Every deny, hold and no-opinion outcome is appended, with the gate's
reason, to `~/.claude/logs/permission-gate.jsonl`, or to the file
`PERMISSION_GATE_LOG` names. An allow is not recorded; a warning about
the config file is, whatever the outcome of the call it rode on.

## Using it

Install it like any plugin from this marketplace. There is no skill
and no command. The hook registers itself from `hooks/hooks.json` and
runs on every matched call; there is nothing to configure for it to
work. The policy is compiled into the binary, so there is no rule file
to edit.

## Configuration

One optional file exists, `~/.config/guardrails/config.yml`, which
nothing installs and you write yourself. It is read at that path
wherever `$XDG_CONFIG_HOME` points.

It exists for paths outside the repository that a session legitimately
needs. Plugins in this marketplace keep per-user config under
`~/.config/<plugin>/` and per-user state under
`~/.local/state/<plugin>/`, and the gate denies a read that resolves
outside the current repository. On a machine whose `~/.config` is a
symlink into a dotfiles repository, every such file resolves into
another repository, and a plugin can no longer reach its own config.
Listing a path in the config makes the gate allow it instead.

```yaml
schema-version: 2
resolve-xdg-environment-variables: yes
config-home-default: ~/.config
state-home-default: ~/.local/state
redirect-bash-file-work: worktree
config-home:
  read:
    - gh/config.yml
  write:
    - issues/**
state-home:
  write:
    - sdlc/**
home:
  read:
    - .ssh/config
```

- `config-home`, `state-home` and `home` each relax containment for the
  paths listed under them, relative to that root: `read` for reads,
  `write` for writes and reads alike. A listed path is matched as
  written, so it is allowed wherever a symlink takes it.
- `config-home-default` and `state-home-default` say where the first two
  roots are.
- `resolve-xdg-environment-variables: yes` makes those two roots follow
  `$XDG_CONFIG_HOME` and `$XDG_STATE_HOME` when they are set. Whatever
  sets those variables then decides where the roots are.
- `redirect-bash-file-work` relaxes no deny. It sets where the
  Bash-to-file-tool redirect under "Limits" applies.
- `schema-version` stamps the file with the format it is written in and
  relaxes nothing.

No entry relaxes these: nothing under a `.git/` directory is allowed by
a listing, and no call may write the config file itself.

**A broken file denies every call.** A config that exists but cannot be
read or parsed makes the gate deny every gated tool call, a write to
the file included, and the deny names the file and the error. Repair or
remove the file by hand, outside the session.

**List directories, not `**`.** Name the directory each plugin needs. A
bare `**` under `home` opens every file in your home directory,
credential files included, for reading.

## Limits

**The plugin only works on a platform with a committed binary, and it
fails closed everywhere else.** Binaries are committed under
`hooks/bin/` for `darwin-arm64`, `linux-amd64` and `linux-arm64`. On
any other platform, `hooks/hooks.json` finds no executable gate for the
running `uname` and denies every matched tool call. This is
deliberate — a gate that cannot run must block rather than step
aside — but it means installing this plugin on an unsupported platform
stops the session rather than degrading it.

**A gate binary that produces no decision also denies every call.**
`hooks/hooks.json` denies the call, naming the binary's path on stderr,
when the binary:

- is missing, lacks its executable bit, or sits on a `noexec` mount;
- cannot be executed, as one built for another architecture or a
  corrupt file cannot;
- exits successfully without printing a decision, as an empty file
  does;
- exits abnormally, as a crashed, killed or truncated binary does.

A binary committed without its executable bit therefore reads as a
total lockout on that platform rather than as a mode problem.

**It is not the whole permission stack.** The gate decides only what
it can settle better than a model can, and deliberately passes the
judgment middle to the downstream auto mode evaluator with no opinion,
rather than spending a human prompt on it. That posture assumes a tuned
auto mode configuration is there to catch what it passes through;
without one, those calls fall to whatever your allow-list and prompt
settings do with them. The
[`auto-mode-tools`](../auto-mode-tools/README.md) plugin is the other
half: it tunes and personalizes that configuration.

**A held call's precedence is design intent, not a measurement.** The
hold tier exists so that no `settings.json` allow entry and no auto mode
judgment can waive a publish, a history-destroying push or a credential
read. Nothing in this plugin runs a real session with a competing allow
to observe which wins, so treat that guarantee as intended rather than
proven.

**The Bash-to-file-tool redirect is graded on the command's shape, not
on what the file holds or what the pipe does.** In a linked worktree, a
Bash command that reads, edits in place or writes a file the way the
Read, Edit or Write tool does is denied and sent to that tool, which
loads the path's `CLAUDE.md` and `paths:` rules where Bash does not.
`redirect-bash-file-work` in `~/.config/guardrails/config.yml` moves
that boundary. The grading accepts these consequences rather than
carving exceptions for them:

- `sed -i` on a file that is not valid UTF-8 is denied and sent to Edit,
  although Edit refuses such a file.
- An `awk` whose program only selects lines is denied and sent to Read,
  while one that prints a field or sets a separator is not, although
  both read the file: Read can reproduce the first's output and not the
  second's.
- A covered read is denied only when its output is not consumed by a
  command outside the reader set, so piping it into a filter that
  changes nothing (`cat f | tr a a`) passes.
- A reader is covered only when it names at least one file operand, and
  the operands are read by each program's own option grammar: `-` names
  stdin, an option's value (`head -n 5`, `nl -ba`, sed's script,
  `less +G`) is not a file, and a reader that names no file reads stdin
  and is never denied. So `make 2>&1 | tail -20`, `cmd | head` and
  `cat <<EOF | x` pass, while `cat f`, `cat a; cat b` and `cat f | head`
  are denied.

**Some paths are graded nowhere, each left that way deliberately.**

- `Grep` and `Glob` raise no hook event, so a path handed to either is
  never graded, a `~`-spelled one and one in another repository
  included. Gating them would put a gate process in front of every
  search in every session.
- An input redirect on `git`, `gh`, `aws` or `acli` is not held to
  containment: `git status < /etc/passwd` is allowed, where
  `cat < /etc/passwd` is denied.
- A process substitution inside an unquoted parameter expansion's
  default, `${Q:-<(cmd)}`, is invisible to the shell parser the gate
  uses, so `for f in ${Q:-<(cat ../other-repo/.env)}; do …; done` is
  allowed although bash runs the `cat`. The `$(cmd)` spelling of the
  same shape is graded.

**A `--separate-git-dir` clone whose git directory is itself named
`.git` is unsupported.** The gate finds a linked worktree's primary
clone through the git directory the worktrees share, and git records no
work tree for a clone made that way, so the gate takes the directory
above the `.git` for the clone. A read from such a worktree that
resolves into the primary clone is still denied, but the deny's label
and the path it suggests instead are wrong.
