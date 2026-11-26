# auto-mode-tools

Tunes and personalizes the `autoMode` block of your Claude Code
`settings.json`: the rules the auto mode classifier judges every tool
call against.

## Why you would want it

Claude Code can critique your auto mode rules itself, with
`claude auto-mode critique`, but that command caps its answer at 4096
tokens. A large `autoMode` block therefore never gets a complete
critique: the answer stops at the ceiling, part-way through.

`/tune-auto-mode` captures the request that command sends, before it
reaches the API, and answers it in your current Claude Code session,
which has no such ceiling. You get the whole critique, one round at a
time, and decide on every finding yourself.

`/personalize-auto-mode` covers the other common need. A tuned block
names people, organizations, repositories and paths, so one written on
another machine, or handed to you by someone else, describes a setup
that is not yours. The skill rewrites the block against your own facts.

The two skills are independent. Either works without the other ever
having run, in either order.

## What you need first

- A Claude Code that has the `claude auto-mode` command.
- A `settings.json` in your Claude Code config directory. For
  `/personalize-auto-mode` it must already hold an `autoMode` block: the
  skill rewrites one and does not author one.
- For `/tune-auto-mode`, `/usr/bin/python3`. The one macOS ships is
  enough, with nothing installed on top.
- For `/tune-auto-mode`, a session on a high-end model at high effort.
  The critique is only as good as the session that answers it.
- For `/personalize-auto-mode`, a facts file describing your machine.
  "Getting started" below says how to write one.

## Getting started

### Which file the skills change

Both skills read and write `settings.json` in
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}`: the directory `CLAUDE_CONFIG_DIR`
names, or `~/.claude` when that variable is unset or empty. That is the
file your session is enforcing, so it is the one worth changing.

Both treat that file with the same care:

- Work happens on a scratch copy. The live file is the permission
  configuration your running session enforces, so it stays untouched
  until the end.
- You see the full diff, and nothing is written without your approval.
- Before the live write, the skill takes a timestamped backup, tells
  you its path, and runs a validation pass over the candidate. If the
  candidate fails, the live file stays as it was and you are told where
  the scratch copy is.
- When `settings.json` is a symlink, into a dotfiles repository for
  example, the backup and the write go through to the link's target and
  the link stays a link.

### Tuning the rules

```text
/tune-auto-mode
```

A typical run:

1. It copies your live `settings.json` into a scratch config directory.
   Every round runs against that copy.
2. It starts a small local server and points
   `claude auto-mode critique` at it. The server records the critique
   request and never forwards it, and the command runs with a dummy API
   key, so your real credential is never sent to it.
3. It answers the captured request in your session and presents the
   findings: the rule each one touches, the proposed edit and the
   reasoning.
4. You accept or reject each finding. Accepted edits go into the
   scratch copy.
5. It runs another round, until you say stop or a round ends with
   nothing accepted.
6. It shows the diff against your live file and, with your approval,
   backs up, validates and writes.

Run one `/tune-auto-mode` at a time. Runs must not overlap: they share
the files below, nothing locks them, and two at once corrupt each
other's results.

The tuner keeps its state under `$XDG_STATE_HOME/auto-mode-tools/`,
which is `~/.local/state/auto-mode-tools/` unless you set that
variable:

- `ledger.yml` is the record of every finding you accepted or rejected,
  with your reason. It accumulates across runs, and a later round reads
  your earlier rejections so the same proposal does not keep coming
  back. It stays on your machine and does not travel with
  `settings.json`, so someone you hand a tuned config to makes their
  own decisions.
- `provenance.yml` identifies the block the tuner last wrote to your
  live file. `/personalize-auto-mode` does not update it, so after a
  personalization it describes a block that has since been rewritten.
  Tune again when you want it to match the live file.
- `last-run/` holds the artifacts of the most recent run, replaced on
  the next one: the captured critique request, the built-in rules the
  findings were judged against, each round's transcript and proposed
  edits, and a ready-to-use pull request body listing what you accepted
  and rejected and why.

### Personalizing the rules

```text
/personalize-auto-mode
```

The skill reads your facts from
`$XDG_CONFIG_HOME/auto-mode-tools/facts.yml`, which is
`~/.config/auto-mode-tools/facts.yml` unless you set that variable.
The facts file is where you state what is specific to you and your
machine, partly as exact lists and partly as free prose.

No facts file ships in the plugin, so the first run finds none. In that
case `/personalize-auto-mode` prints the facts schema, with placeholder
values, and tells you where to save the file. Fill it in and run the
skill again.

With a facts file in place, the skill rewrites the block's descriptions
of your environment against it, shows you the diff and, with your
approval, backs up, validates and writes. This is a rewrite and not a
find-and-replace: a paragraph that mentions something your facts do not
list is reasoned about again.

Afterwards `settings.json` is the thing you maintain, and the facts
file is expected to go stale. Running the skill again starts over from
the block as it then stands.

## What it deliberately does not do

- **It does not open a pull request.** The tuner writes a pull request
  body into `last-run/`; landing the tuned `settings.json` in a config
  repository is left to you.
- **It does not reconcile your block against a changed set of built-in
  rules.** A Claude Code release that changes the shipped rules does
  not update your block; tune again to have it judged against them.
- **It does not compare critique quality across models or effort
  levels.** Nothing measures a tuned configuration yet, so there is
  nothing to compare on.
- **It does not guard against overlapping `/tune-auto-mode` runs.**
  There is no lock; running one at a time is up to you.
- **It does not ship anyone's facts.** Every name, organization,
  repository and path comes from your facts file or from the block
  being worked on.
