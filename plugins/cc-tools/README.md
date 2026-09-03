# cc-tools

Meta-skills for running Claude Code itself: load the global rules a
session should be working under, find out what changed in the harness
and in the issues you track, and curate the memory your agents write
so it stays worth reading.

Everything here is *about* the harness rather than about any one
repo's code. That is the line: a skill belongs in this plugin when
what it operates on is your Claude Code configuration, the upstream
Claude Code project, or the memory tree agents leave behind.

## Why you would want it

Each of these gets worse the longer you leave it:

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
  aimed at a PR resolves that PR's branch through it.
- **A `~/.claude/CLAUDE.md`**, if you want rule-loading to have
  anything to load.
- **Agents that declare `memory: project`**, if you want anything to
  curate. With nothing captured — no `.claude/agent-memory/` for the
  repo route, an empty inbox for the session route — curation reports
  that there was nothing to grade and stops; that is a valid outcome,
  not a failure.

- **A list of topics you care about.** The two skills that report on
  upstream Claude Code act on that list and on nothing else; both seed
  it from a starter set on their first run, and you edit it from
  there. What it holds and where it lives are
  `skills/lib/cc-topics-config.md`.

`cc-whats-new` keeps a watermark file beside that list, which it
creates on its first run; its path and shape are
`skills/cc-whats-new/SKILL.md` → "State file". The only other state is
the session inbox described below, which lives under the session
scratchpad rather than in any repo and dies with the session.

## The entry points

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
  requests and bugs your topics list are still open and which have
  shipped, with the closure date, one group per topic. Pass extra
  issue numbers as arguments to fold them into one run without editing
  the list.

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

- **It does not decide what your rules should say.** `cc-all` loads
  `~/.claude/CLAUDE.md`; authoring it is yours.
- **The topics list is hand-maintained.** Nothing adds to it on your
  behalf: the watchlist discovers nothing, and `cc-whats-new` asks
  before it appends anything it found. An issue nobody added is an
  issue neither will mention.
- **Nothing here reads your machine to decide what matters.** Your
  settings, installed plugins and hooks are not consulted, so a
  surface this machine exercises but your topics do not name goes
  unmentioned. That is the trade: the tools report, you curate. Widen
  the window with `--since` and read the upstream CHANGELOG yourself
  when that matters.
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
The topics config — its path, its schema, and what a reader does when
it is missing or unreadable — lives in
`skills/lib/cc-topics-config.md`, and the starter set that seeds it
lives in the one skill that writes it,
`skills/cc-seed-config/SKILL.md`. No skill restates any of those
contracts, and neither does this README: when you need the exact
behavior, those files are the source.
