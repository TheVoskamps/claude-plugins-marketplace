# cc-tools

Tools for running Claude Code itself: launch a session named after the
repo it runs in, with that repo's own settings overlay on top of your
global ones; load the global rules a session should be working under;
find out what changed in the harness and in the issues you track; and
curate the memory your agents write so it stays worth reading.

Everything here is *about* the harness rather than about any one
repo's code. That is the line: a skill or a command belongs in this
plugin when what it operates on is your Claude Code configuration, the
launch of a session, the upstream Claude Code project, or the memory
tree agents leave behind.

## Why you would want it

Each of these gets worse the longer you leave it:

- **Every repo launches with the same settings.** A permission rule or
  an auto-mode line that one repo needs has nowhere to go but your
  global `settings.json`, where every other repo gets it too, and a
  repo's own `.claude/settings.json` does not reach `autoMode`. The
  `cr` launcher gives each repo a settings file of its own that is
  layered over the global one at launch.
- **Your global rules are on disk but not in the session.**
  `~/.claude/CLAUDE.md` pulls in files with `@~/` lines that are not
  expanded for a model reading it with a file tool, so "the rules are
  loaded" is an assumption, not a fact. There is a skill that makes it
  a fact.
- **Claude Code moves faster than you can read its changelog.** Most
  of what ships does not touch any subject you are actually following,
  and the bug you filed six months ago may have quietly closed.
- **Agent memory rots.** Agents that declare `memory: project` write
  into `.claude/agent-memory/` as they work, and nothing judges those
  writes. Entries pile up that restate the code, name a design doc as
  the source of truth, or narrate finished work — each one
  misdirecting the next agent that reads the index. An unread memory
  tree is better than a wrong one.

## Before it will work

- **`gh`, authenticated.** The skills that report on upstream Claude
  Code read `anthropics/claude-code` through it, and memory curation
  aimed at a PR resolves that PR's branch through the `github-prs`
  plugin's PR-view verb — which is why `plugin.json` declares a
  `dependencies` edge on `github-prs`. The edge guarantees that verb
  is installed and enabled wherever this plugin runs; it grants no
  access to `github-prs`' files.
- **`jq`**, if you want `cr`. The resolver at `~/.local/bin/cr` reads
  `claude plugin list --json` through it to find where the enabled
  cc-tools is installed; without `jq` it refuses with a message on
  stderr rather than guessing a path.
- **`~/.local/bin` on your `PATH`**, if you want `cr`. The deploy hook
  writes the resolver there and says so when the directory is not on
  `PATH`; it never edits `PATH` for you.
- **No `cr()` function in your shell profile.** In zsh a function
  shadows a command on `PATH`, so a shell that still defines one keeps
  running it until the function is removed from the profile and the
  profile is reloaded; only then does `~/.local/bin/cr` take over.
- **A `~/.claude/CLAUDE.md`**, if you want rule-loading to have
  anything to load.
- **Agents that declare `memory: project`**, if you want anything to
  curate. With nothing captured — no `.claude/agent-memory/` for the
  repo route, an empty inbox for the session route — curation reports
  that there was nothing to grade and stops; that is a valid outcome,
  not a failure.
- **A list of topics you care about.** The two skills that report on
  upstream Claude Code take their topics from that list and infer none
  from anywhere else; both seed it from a starter set on their first
  run, and you edit it from there — by hand, or by accepting what
  `cc-suggest-topics` proposes. What it holds and where it lives are
  `skills/lib/cc-topics-config.md`.

`cc-whats-new` keeps a watermark file beside that list, which it
creates on its first run; its path and shape are
`skills/cc-whats-new/SKILL.md` → "State file". The only other state is
the session inbox described below, which lives under the session
scratchpad rather than in any repo and dies with the session. The one
file the plugin writes outside its own tree is `~/.local/bin/cr`, a
byte-for-byte copy of `hooks/cr-resolver`.

## The entry points

### Launching a session

`cr` starts an interactive Claude Code session from the root of the
repo you are in, named after that repo. Its shape:

```text
cr [--cr-strict] [<name-word>…] [<claude-argument>…]
```

The arguments before the first `-`-prefixed one become the session
name's prefix, joined with spaces — `cr fix the bug` in a clone of
`my-repo` names the session `fix the bug my-repo`; with no name words
the prefix is a `%b%d-%H:%M` date stamp. The first `-`-prefixed
argument and everything after it go to `claude` unchanged. The repo
name is the last path component of the `origin` URL without `.git`, or
`(local)` when there is no `origin`. Outside any repo, `cr` runs
`git init` in the current directory so the session has a repo, and
removes that `.git` again when the session ends, on an interrupt or a
termination included; `--cr-strict` as the first argument refuses
instead, and also refuses a repo with no `origin`. The session gets
`--remote-control`, a debug log under `~/.claude/logs/` named after
the session, and `Grep` and `Glob` allowed without a prompt. When
`GIT_CONFIG_GLOBAL` is unset and `~/.gitconfig-claude` is readable,
`cr` exports it pointing there, so git inside the session reads that
file as its global config. The usage block at the top of `bin/cr` is
the exact contract.

**The per-repo overlay.** When `<repo-root>/.cc-tools/cr-settings.json`
exists, `cr` passes it to `claude --settings`. It is a Claude Code
settings file, with the format and keys of a user `settings.json`,
`permissions` and `autoMode` included; list keys add to the global
lists and scalar keys override them. This is the one route by which a
per-repo setting reaches `autoMode` — a repo's `.claude/settings.json`
does not — and an `autoMode.environment` line passed this way lands in
every model request of the session, subagent requests included. Only
the file at the repo root counts; one in a subdirectory is ignored. A
change to the overlay takes effect at the next `cr`; nothing in a
running session re-reads it. Owner- and org-level layers over the repo
one are issue #596.

**How `cr` reaches the shell.** The launcher lives in the plugin as
`bin/cr`, which puts it on `PATH` inside sessions — but the plugin
cache path changes with every cc-tools version, so nothing in a shell
profile can name it. What the shell runs is a resolver, deployed to
`~/.local/bin/cr`, that carries no launcher logic: it asks
`claude plugin list --json` where the enabled `cc-tools@thevoskamps` is
installed and execs that install's `bin/cr` with its arguments, so a
cc-tools update reaches the very next `cr` with nothing redeployed.
When no enabled cc-tools is installed, or `jq` is missing, or the plugin
list cannot be read, the resolver says which on stderr and exits 1; it
never falls back to plain `claude`, because a session launched without
the overlay would look like one launched with it. The resolver's text
is `hooks/cr-resolver`. It sits under `hooks/` rather than `bin/`
because `bin/` is what sessions get on `PATH`, and the resolver is only
ever run from the shell.

**Keeping the resolver current.** `hooks/hooks.json` registers
`hooks/cr-deploy.sh` on `SessionStart`. While `~/.local/bin/cr` matches
`hooks/cr-resolver` byte for byte, the hook does nothing and prints
nothing. When the target is missing or differs, it creates
`~/.local/bin` if absent, writes an executable copy to a temporary file
beside the target and renames it into place, and reports through a
`systemMessage` that `cr` was updated and the shell should be
restarted, adding that `~/.local/bin` is not on `PATH` when it is not.
A write that fails, and a `HOME` that is unset or empty, each get a
`systemMessage` saying the launcher could not be updated. The hook
exits 0 on every path, so it never blocks a session, and it builds its
JSON by hand so that `jq` is a dependency of `cr` alone. A change to
the resolver's text therefore reaches a machine at its next session
start, and a change to the launcher reaches it at the next `cr`.

### Loading the global rules

`/cc-tools:cc-all` reads `~/.claude/CLAUDE.md` and every file it
includes. Run it at the top of a session where you want the global
principles genuinely in context rather than nominally in effect.

### Finding out what changed

Which you want depends on whether you are asking about the harness or
about your own filed issues:

- `/cc-tools:cc-whats-new` reports what changed in Claude Code since
  the skill last ran, **filtered to the topics you configured**, and
  drops changelog lines none of them names. Takes an optional
  `--since YYYY-MM-DD` to widen the window for one run. A typical run:
  it reads the watermark, diffs the upstream CHANGELOG forward from
  your last version, searches issues on every configured topic, prints
  the report — offering what it found as candidates to track — and
  advances the watermark.
- `/cc-tools:cc-watchlist` reports which of the upstream feature
  requests and bugs your topics list names are still open and which
  have shipped, with the closure date, one group per topic. Pass extra
  issue numbers as arguments to fold them into one run without editing
  the list.

### Widening the topics list

`/cc-tools:cc-suggest-topics` is the one skill that mines the machine
for topics to track. It reads your **global** Claude configuration —
settings, installed plugins and marketplaces, the always-loaded
rules — derives candidate topics from the harness surfaces it finds
there, and shows each one with the file and key it came from, so you
can tell a claim about your own setup from a topic the skill
invented. It appends only what you accept. A candidate that restates
a topic you already track under different wording becomes a proposal
to rename that topic to the broader term instead, carrying its issue
numbers over — and that rename takes its own yes. Decline everything
and no topic changes.

### Curating agent memory

Which route into the rubric you want depends on whether the memory is
in a repo or in a session.

`/cc-tools:agent-memory-cleanup` is the one you invoke yourself. It
grades every entry in `.claude/agent-memory/`, then **acts** — it
deletes every entry the rubric grades as no longer earning its place,
moves durable lore out into the repo's own documentation, keeps what
has no home in the repo, and repairs the `MEMORY.md` indexes and the
wikilinks between entries. It is not a read-only report handed to
someone else to apply.

The argument picks which tree it curates: with none, the one you are
sitting in; with a PR number, that PR's branch. What each mode does
about confirming and committing — and the caller-side precondition the
PR mode carries, since deletions are confirmed with nobody — is
`skills/agent-memory-cleanup/SKILL.md` → "Invocation". Read it before
you run the PR mode.

The other route is the **session inbox**, for agents that run under
`isolation: worktree`. Their `.claude/agent-memory/` resolves inside a
throwaway worktree and dies with it, so the work has to leave before
cleanup: a capture step copies the entries that outlive the run into a
per-branch inbox under the session scratchpad, and a curation step
grades them and writes the survivors into the repo. Both are
`user-invocable: false` — an orchestration flow drives them at the
right two moments, since only the agent that did the work can say
which of its notes were about the branch and which about the repo.

## What it deliberately does not do

- **`cr` does not validate the overlay.** `.cc-tools/cr-settings.json`
  goes to `claude --settings` as it stands, so a malformed file fails
  the way `claude` fails on any bad settings file, and the keys it may
  hold are Claude Code's to define.
- **The resolver does not run `claude` without cc-tools.** A missing
  or disabled cc-tools is an error, never a plain `claude` launch.
- **The deploy hook does not touch your profile.** It writes
  `~/.local/bin/cr` and nothing else; putting that directory on `PATH`
  and removing an older `cr()` function are yours.
- **It does not decide what your rules should say.** `cc-all` loads
  `~/.claude/CLAUDE.md`; authoring it is yours.
- **The topics list is hand-maintained.** Past the starter set that
  seeds it, nothing reaches it on your behalf: the watchlist discovers
  nothing, and every other write asks first. An issue nobody added is
  an issue neither reporter will mention.
- **The reporting skills do not read your machine.** `cc-watchlist`
  and `cc-whats-new` consult your settings, installed plugins and
  hooks for nothing, so a surface this machine exercises but your
  topics do not name goes unmentioned in their reports. That is the
  trade: the tools report, you curate. `cc-suggest-topics` is the one
  place those surfaces are read, and it only proposes — you run it
  deliberately, and it writes nothing you did not accept.
- **Suggestions come from configuration, not from use.** The candidates
  are derived from what the machine is configured for; no transcript
  history and no usage frequency stands behind them, so a surface you
  set up once and never exercise is proposed exactly like one you hit
  daily.
- **Nothing removes a topic.** Every write that touches an entry
  already in the file takes its own yes and drops nothing; which writer
  touches what is in `skills/lib/cc-topics-config.md` → "Writing it". A
  tracked topic that has stopped mattering stays until you delete it by
  hand — save on the one path that file discloses.
- **The topics list is machine-wide.** It lives under your user config
  directory, and no repo-local layer sits over it, so every repo you
  run these skills in reports on the same topics — including the ones
  that matter in one repo and nowhere else. For the same reason the
  suggester reads only the global rung of your Claude configuration and
  never a repo-local `.claude/settings.json`: a candidate derived from
  one repo's settings would have nowhere repo-local to be written.
  Adding such a layer is issue #375.
- **Curation is destructive and has no undo of its own.** It relies on
  git, or on your review of an uncommitted tree. The inbox is not a
  repository at all: an entry the curator neither transfers nor
  deletes is simply lost at the end of the session.
- **Nothing here migrates prose that is already in place.** Curation
  governs the entries in front of it. Documentation transferred by an
  earlier run stays where that run put it.

## Where the rules actually live

Curation reads a shared rubric,
`skills/lib/agent-memory-grading.md` — what makes an entry durable,
the evidence a delete has to produce, how a transfer is phrased, which
file it lands in, and the standard that file is held to afterwards.
The inbox path and layout live in `skills/lib/agent-memory-inbox.md`.
The topics config — its path, its schema, and what a skill that reads
it does when it is missing or unreadable — lives in
`skills/lib/cc-topics-config.md`, and the starter set that seeds it
lives in the one skill that creates it,
`skills/cc-seed-config/SKILL.md`. No skill restates any of those
contracts, and neither does this README: when you need the exact
behavior, those files are the source.
