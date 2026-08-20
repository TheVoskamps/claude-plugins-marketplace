# Scratch / Temporary File Location

Agent scratch, temporary, and throwaway files go under
**`<repo-root>/.claude/tmp/`** — never a loose `/tmp/` path and never
`.git/` (git internal state). The one sanctioned out-of-repo
destination is the **harness scratchpad**, `/tmp/claude-<uid>/`, and
only for a handoff whose reader the writer's own `.claude/tmp/` cannot
serve — one in another repo, another session, or another subagent's
worktree.

## The rule

When an agent needs somewhere to put a file that is not part of the
deliverable — a sandbox, a test fixture, an intermediate artifact, a
scratch buffer — it writes under `<repo-root>/.claude/tmp/`. In a
linked worktree that root is `$(git rev-parse --show-toplevel)`, so the
destination is `$(git rev-parse --show-toplevel)/.claude/tmp/`. Spell it
however reads best — the gate resolves that substitution wherever it
sits in a word (bare, as `"$(…)"`, inline as `"$(…)/.claude/tmp/x"`, or
as a `cd` target), not only as a bare assignment RHS (#225).

- ✅ `<repo-root>/.claude/tmp/issue-30-scratch/foo.json`
- ✅ `/tmp/claude-<uid>/<project-slug>/<session-id>/scratchpad/…` — the
  harness scratchpad, but only for a handoff file whose reader sits
  outside the writer's containment boundary (see below).
- ❌ `/tmp/foo.json` — out of repo; boundaries can't be enforced and
  the artifact escapes inspection.
- ❌ `.git/foo.json` (or anywhere under `.git/`) — git internal state.
  The permission-gate denies it outright (issue #125, broadened in #35).

The destination matters even for a scratch file the agent never reads
back itself. Since #229 a file `gh` PUBLISHES is graded by the same
read containment. What that grades, per verb, is exactly:

- `-F`/`--body-file` on `gh pr create`, `pr comment`, `pr edit`,
  `pr merge`, `pr review`, `gh issue create`, `issue comment` and
  `issue edit`.
- `-F`/`--notes-file` on `gh release create` and `release edit`.
- `-T`/`--template` on `gh pr create` — and only there, because
  `gh issue create`'s `-T` names a server-side template rather than a
  local file.
- `--recover` on `gh pr create` and `issue create`.
- `-a`/`--add` on `gh gist edit`.
- File operands: every operand of `gh gist create`, and every operand
  after the gist id or tag of `gh gist edit`, `gh release create`,
  `gh release upload` and `gh release edit` — the last of which takes
  no file operand at all in gh's own grammar, so a stray one is
  graded rather than ignored.
- Whatever stands in for one of those paths: a `-` — in a file
  operand or as the value of any flag above — is gh's read-from-stdin
  marker and is graded as the command's input redirect source
  (`gh pr comment 227 -F - < /tmp/body.md` is the
  same publish as naming the path), and `gh gist create` reads stdin
  with no marker at all when given no operand
  (`gh gist create < /tmp/body.md`).
- Whichever spelling names the verb. gh's own command aliases resolve to
  the canonical one before the grading runs, so `gh gist new`,
  `gh pr new`, `gh issue new` and `gh release new` grade exactly what
  `create` grades — respelling the verb is not a way around the
  destination rule. The message names the canonical verb too:
  `gh gist new /tmp/body.md` is refused as `'gh gist create'`, so read
  the verdict against the rule rather than against the words you typed.

Both sanctioned destinations survive that
grading — a PR-body file under `<repo-root>/.claude/tmp/` is
contained, and one in a harness session directory is allowed outright
— while a loose `/tmp/body.md` that used to be published without
comment is now denied as a cross-repo read escape.

Surviving containment is not the whole verdict, though. Containment
forwards an escape and discards its own ALLOW, so the verb's own tier
still decides. Both gist verbs ask on the publish tier however
well-placed the file is:

- every `gh gist create`, with `--public` and without it. A gist
  created without the flag is *unlisted*, not private — GitHub's docs
  say anyone who discovers the URL can read it, whether or not you sent
  it to them — so publishing a scratch file as a "secret" gist is not a
  way to move it off the machine quietly.
- every `gh gist edit`, whatever the destination gist's visibility. The
  gist already exists, so its URL may already be circulating and may
  already have readers: pushing a scratch file into one exposes it the
  moment it lands, which can be *worse* than minting a fresh gist
  rather than safer. The escalation is on the whole verb, so
  `-a`/`--add`, the positional file and the bare editor invocation all
  ask alike.

A sanctioned destination buys the file past containment, not past the
human.

## Cross-repo, cross-session, and cross-worktree handoff

Repo-scoped scratch is the common case, and `.claude/tmp/` serves it.
But a file whose whole purpose is to reach a reader the writer's own
`.claude/tmp/` cannot serve goes to the scratchpad instead. These
shapes qualify:

- **A file that outlives one repo or one session** — a handoff another
  session picks up, possibly from a sibling repo. It cannot live in
  either repo's `.claude/tmp/`: the reader is outside the writer's
  containment boundary, so the read is a cross-repo escape.
- **A file handed from one subagent's worktree to another's**, within
  a single session. An `isolation: worktree` agent's `.claude/tmp/` is
  removed with its worktree, so a later agent never gets to read it —
  the scratchpad is the only destination both agents can name. The
  `cc-tools` agent-memory inbox is the worked instance.

Either goes in the **harness scratchpad**, which Claude Code
provisions per session at:

```text
<system-tmp>/claude-<uid>/<project-slug>/<session-id>/scratchpad
<system-tmp>/claude-<uid>/<project-slug>/<session-id>/tasks
```

`<uid>` is the current process's user id, so the tree is per-user
(on macOS `/tmp` is a symlink to `/private/tmp`, and both spellings
name the same location). The permission-gate carves out the whole
**per-uid** prefix — `/tmp/claude-<uid>/`, not just the current
session's own subdirectory — precisely so a second session can read
back what the first one wrote under a different
`<project-slug>/<session-id>` subpath (issue #193).

The verdict inside that prefix is graded on where the path lands:

- A path in a **session directory** — `<project-slug>/<session-id>/`
  followed by `scratchpad/` or `tasks/`, with `<session-id>` a uuid —
  is **allowed outright**, for reads and writes alike and by every
  spelling of each: the `Write`/`Edit` tools and the `Read` tool,
  `cat` of a file there and `ls` of the directory, `cp`/`mv`/`tee`,
  and a shell redirect
  (`echo x > <scratchpad>/f`), including a credentialed tool's redirect
  (`gh pr diff 224 > <scratchpad>/f`, #225 — it is graded as a write
  destination like any other, not vetoed for being `gh`). This is the
  destination to use.
- A path under `bundled-skills/` — harness-installed skill content
  living beside the session directories, not a scratch destination —
  is **allowed to read** and **defers** for a write.
- A path elsewhere under the prefix **defers** to the normal
  permission pipeline: `settings.json` allow/ask/deny still governs,
  but containment no longer hard-denies.
- If the `claude-<uid>` root itself is not a plain directory owned by
  this user — a symlink, a non-directory, another user's — every path
  under it **defers**, with an analysis naming the defect. That is a
  broken `/tmp`, not the carve-out failing; the carve-out simply cannot
  prove where a path under a defective root lands, so it withholds the
  allow rather than escalating.
- Outside the prefix, every other `/tmp` path — including another
  user's `/tmp/claude-<other-uid>/` — is still denied as a cross-repo
  escape.

Do not hand-build a path that only approximates the shape. The right
scratchpad path is the one the harness told this session about; write
under its `scratchpad/` (or `tasks/`) directory rather than inventing
a sibling.

Prefer `.claude/tmp/` whenever the file is repo-scoped. The scratchpad
is for handoff, not a way around containment: it is outside the repo,
so a failed run leaves nothing for the human to inspect alongside the
work.

## Why this location

`/**/tmp/` is **already gitignored repo-wide** (see the repo's
`.gitignore`), so `<repo-root>/.claude/tmp/` is an untracked, in-repo
location:

- **In-repo** → the permission-gate's containment check treats it as
  `contained`, so the write is allowed (it defers to the normal
  pipeline) rather than blocked as a cross-repo (#148) or
  worktree-escape (#127) escape. That holds for a credentialed tool's
  redirect too — `gh pr diff 224 > .claude/tmp/x.md` is graded on its
  destination like `tee .claude/tmp/x.md` and allows (#225), where it
  used to ask purely for being a `gh`/`git`/`aws` redirect. The other
  side of that grading is now a deny: a credentialed redirect whose
  destination the gate proves ESCAPES the worktree
  (`git show HEAD:f > /tmp/x.md`) is denied with the same prescription
  this document records, exactly as `Write` to that path is (#262). It
  asked until then, which is why an agent could click through a
  destination the `Write` spelling of the same write would have
  redirected it away from.
- **Gitignored** → scratch artifacts never get committed and never
  pollute a diff.
- **Inspectable on failure** → because it lives under the repo, a
  failed run leaves its sandbox where it can be examined, rather than
  in a system temp dir outside the boundary.

No new `.gitignore` line is required; the `/**/tmp/` rule already
covers `.claude/tmp/` at any depth. Verify with:

```sh
git check-ignore -v .claude/tmp/x
```

## Why the permission-gate deny messages point here

A guardrail that only forbids invites a workaround; a guardrail that
prescribes prevents one. The permission-gate's containment denies
(#127, #148) used to tell the agent only what it may *not* do. Faced
with an open-ended denial of a scratch write, the model improvises its
own landing spot — and a plausible-but-wrong improvisation is to write
under `.git/` purely because that directory is gitignored and in-repo,
so it slips past containment. The deny induced the bad write.

As of issue #30, the write/edit containment-escape denies name this
canonical destination and explicitly warn against `.git/`, so the
feedback prescribes the correct alternative instead of leaving it to
the model's discretion. Issue #193 completes the prescription: naming
only the in-repo destination left a genuine cross-repo handoff file
with no legal landing spot at all, which is the same open-ended denial
in a different disguise, so the denies now name **both** destinations
and the read-side denies name the handoff location too. Both hints
state the criterion this rule states — a reader the writer's own
`.claude/tmp/` cannot serve — and enumerate the same three shapes that
qualify, so a hint never tells an agent that a sanctioned handoff has
nowhere to go. They also name
the **resolved** repository root — the absolute path the gate already
holds — rather than a `<repo-root>` placeholder the model has to
resolve for itself (and can resolve to the primary clone instead of
its own worktree) or a `$(git rev-parse --show-toplevel)` incantation
it is told to run for a value the gate is already holding. The same
prescriptive remediation is emitted by the in-repo-write classifier
(issue #32) when a file-mutating shell
command (`cp`, `mv`, `mkdir`, `touch`, `sed -i`, `tee FILE`) targets a
path that escapes the worktree (#127) or the repo (#148): the bash
deny steers scratch writes here too. The policy itself is compiled
into the permission-gate binary (see
`hooks/permission-gate/classify_files.go` for the write/edit denies and
`hooks/permission-gate/classify_inrepo_write.go` for the bash
in-repo-write denies); this document records the convention the deny
messages prescribe.

Issue #262 extended the same reasoning to the credentialed-redirect
track. `git show HEAD:f > /tmp/x.md` and a redirect into `.git/` used
to ask where the `Write` tool denied the identical destination, so the
one spelling that most needed the prescription — the one an agent
reaches for when capturing command output — got a prompt instead of
it. Both now deny and carry the prescription. The induced-bad-write
argument above is why: a click-through leaves the agent to improvise a
landing spot just as an open-ended denial does, and the prescription is
what stops the improvisation.
