# Verification playbook

**Who reads this and when:** any agent about to claim a change was
verified, in any domain. Read it before running the measurement, since
its subject is what makes a measurement mean anything.

Cross-domain techniques for settling a claim about a change: how to
build a harness that isolates the thing under test, how to baseline so
a measurement means something, and how to prove a rebase or a lint
sweep did what it says.

The domain-specific companions are
[`guardrails-verification-playbook.md`](./guardrails-verification-playbook.md)
and
[`claude-vm-verification-playbook.md`](./claude-vm-verification-playbook.md).

## Baseline a suite total before believing a delta

A branch total alone cannot verify a "+N assertions" claim — you need
the base revision's total, and switching the worktree back mid-review
is churn. Extract the base payload and run it in place:

```bash
mkdir -p .claude/tmp/main-payload
git archive origin/main <payload-path> | tar -x -C .claude/tmp/main-payload
bash .claude/tmp/main-payload/<payload-path>/test/<suite>.sh | tail -2
```

A self-contained suite resolves its own `lib/` relative to its
location, so the extract is fully runnable with no checkout.

**A wrong baseline is not always a stale-fork-point story.** Check the
other plausible metric before narrating a cause: run
`git merge-base origin/main HEAD` *and* the alternative count (e.g.
`grep -c 'assert_eq ' <suite>`). When neither metric yields the claimed
number, the tree is fine and the PR body is simply wrong.

## Negative-control new assertions with a hybrid tree

A fixer's "N of the new assertions fail against the previous code"
claim is what makes those assertions worth having, and the branch suite
passing proves nothing about it. Build the branch's payload with
exactly one file reverted to the pre-fix blob:

```bash
H=.claude/tmp/hybrid; rm -rf "$H"; mkdir -p "$H"
git archive HEAD <payload-path> | tar -x -C "$H"
git show <pre-fix-commit>:<payload-path>/<changed-file> \
  > "$H/<payload-path>/<changed-file>"
bash "$H/<payload-path>/test/<suite>.sh" 2>&1 \
  | grep -E '^FAIL|passed, .* failed'
```

The pre-fix commit is the previous round's head, read off the PR's
commit list (`gh pr view --json commits`). The FAIL list should be
exactly the assertions the claim names — confirmed in one run, with no
worktree churn.

Pair it with a real-shell micro-check of the underlying mechanism when
the defect is a parsing fact, rather than asserting the mechanism from
the suite's verdict alone.

## Bound a cleanup escalation by stubbing `kill`

Reviewing a "bounded" reap or cleanup escalation (grace, then SIGTERM,
then SIGKILL, then give up), the load-bearing question is whether the
**give-up path** really skips the blocking `wait`. A normal test child
cannot get you there: `trap "" TERM` only survives to the SIGKILL rung,
and nothing in userspace survives SIGKILL.

Extract the real function bodies verbatim
(`sed -n '<start>,<end>p' src.sh > reap.inc`), source them in a
harness, shorten the tick constants, and stub `kill` as a shell
function so the process appears immortal:

```bash
kill() { case "$1" in -0) return 0 ;; *) return 0 ;; esac; }
```

Every rung then expires, and you observe directly whether the function
returns — and with what status — or blocks in `wait`. Use
`builtin kill` to clean up the real child afterward. Run both harnesses
(a real SIGTERM-ignoring child, and the stubbed-kill give-up) under the
oldest bash that can reach the code as well as a modern one.

Worth checking in the same pass: that the synthetic give-up status is
nonzero, so it routes to the conservative retain branch; that its only
consumer is a `= "0"` test rather than an exact-value match; that a
test asserting the value **derives** it from source rather than
hardcoding it; and that any terminal restore is ordered before the reap
and re-asserted after.

## Test an interactive-shell handoff under a real pty

A claim that "on failure we `exec` a login shell and the operator lands
in a working interactive shell" is testable on the host even when the
real target is a guest you cannot boot. Wrap the handoff in a stub and
run it under `script -q /dev/null`, which supplies a real pty; pipe
probe commands in with a leading `sleep` so the login shell is up
first:

```bash
{ sleep 1
  printf 'case $- in *i*) echo PROBE_INTERACTIVE=yes;; *) echo PROBE_INTERACTIVE=no;; esac\n'
  printf 'echo PROBE_TTY=$(tty)\n'
  sleep 1; printf 'exit 0\n'; sleep 1
} | script -q /dev/null ./inner.sh 2>&1 | tr -d '\r' | grep -a "PROBE_\|launcher"
```

A real interactive shell shows `PROBE_INTERACTIVE=yes`, the **same**
tty as the launcher, and emits bracketed-paste (`[?2004h`) around its
prompt — that escape sequence is itself a reliable tell, since only
interactive bash emits it.

Check two things from the code before trusting such a handoff: where
the launcher redirects fds 0, 1 and 2 (a diagnostics redirect to a
*different* console is fine; a redirect of the shell's own fds is not),
and whether the shell binary is actually installed — grep the image's
package list rather than trusting the comment that says it is.

## bash 3.2 ends a `$( )` at a `case` pattern's `)`

Stock macOS `/bin/bash` is 3.2.57, and it terminates a `$( … )` at the
closing paren of a **case pattern**, so an assertion written as
`"$(case "$x" in "$p"/*) echo inside ;; *) echo outside ;; esac)"`
evaluates to the literal tail of its own source:

```text
expected: [outside]
actual:   [ echo inside ;; *) echo outside ;; esac)]
```

bash 5 parses it fine, and the identical classification written
*outside* a substitution — a function, or `[ "${x#$p/}" != "$x" ]` —
returns the right answer on both. So the failure indicts the harness,
never the code under test. But the FAIL *label* is the test's own
sentence, which can read exactly as if the change under review were
broken.

Telling them apart:

1. **Baseline the suite at the base revision** and run it there under
   *both* interpreters. That separates pre-existing failures from the
   branch's own — and separating them is where the work starts, not
   where it ends. "Identical to main's" licenses an investigation, not
   a carried number: read what each surviving FAIL label *names*. A
   label naming a whole shipped function, red on the interpreter the
   product actually runs on, is a blocker wearing a baseline's clothes.
   That is exactly what "568 passed / 15 failed, all pre-existing"
   turned out to be on PR #273 — the `render:` and `enabled-validate:`
   rows were `claude_vm_render_guest_settings` aborting, on bash 3.2,
   every launch whose config carried a `claude.plugins.enabled`
   override, carried for several review rounds because the count
   matched main's.
2. **Run the shipped code, not the assertion.** Slice the real loop out
   by line range and run the slice under `/bin/bash` and `bash`
   explicitly — a suite's own `bash "$SLICE"` resolves through PATH, so
   a suite running under 3.2 still runs its slices under 5.
3. **Grade it cheaply.** Nothing shipped differs; the harm is the false
   FAIL text, so the remedy is to move the classification out of the
   substitution. Say which side of the line the failure sits on: a
   3.2-only construct in an assertion costs a reader's trust, where the
   same construct in a guard ships a hole.

The mechanism is narrower than "counting parens". Measured on 3.2.57
against 5.3.15, a `)` inside a quoted string and a nested `( … )`
subshell both parse correctly; only an **unbalanced** `)`, which in
practice means a case pattern's, ends the substitution early.

To sweep the class, do not grep — the two ends sit on different lines.
A quote-aware paren walker over every tracked shell file that flags a
`$( )` body containing `case` runs in seconds; negative-control it
against the pre-fix commit's own file, which must report the known
instances.

## Running a claude-vm suite under bash 5 needs a borrowed yq

The bash ≥ 4 half of a two-interpreter run has no local shell on a
stock macOS box — `/bin/bash` is the only one, and `command -v bash`
resolves to it. The container is the only route, and the obstacle is
not bash but yq: `plugins/claude-vm/payload` needs **mikefarah** yq v4
(`yq eval`), while Debian's `yq` package is the unrelated Python
wrapper (3.4.3), which makes every yq-touching assertion fail for a
reason that has nothing to do with the change.

Borrow the binary from its own published image rather than downloading
one — same platform as the test container, and no host install:

```bash
podman run --rm -v "$PWD/.claude/tmp/<slug>:/out" \
  --entrypoint sh docker.io/mikefarah/yq:4 -c 'cp /usr/bin/yq /out/yq-linux'
podman run --rm --platform linux/arm64 -v "$PWD:/w:ro" \
  -w /w/plugins/claude-vm/payload docker.io/library/debian:trixie bash -c \
  'install -m755 /w/.claude/tmp/<slug>/yq-linux /usr/local/bin/yq
   export TMPDIR=/tmp; bash test/config-test.sh | tail -2'
```

Expect a **lower** total than the 3.2 run, not a matching one: the
old-bash batteries resolve no pre-4 shell in the container and skip
themselves, which is the whole difference. Baseline the pre-fix tree
there too (copy the payload to a writable path inside the container and
swap the one file) — a bash-4-only defect shows as *no* delta on that
side, which is itself the measurement.

One host-side trap has nothing to do with bash: a scratch `TMPDIR` deep
under `.claude/tmp/` can exceed the 104-byte `sun_path` limit, and
`endpoint-test.sh` then fails three live-listener rows. Re-run it with
the default `TMPDIR` before blaming a change for those.

## Verify a rebase with a local patch-id walk

To verify that a rebased and force-pushed branch lost nothing, compare
the two commit *series* locally. The GitHub compare API is not
available for this — a three-dot compare URL contains `..` and the
permission gate refuses it by shape. The local route needs no fetch:

1. **Anchor the pre-rebase tip.** `gh pr view <N> --json reviews` gives
   each review's `commit.oid`, so a round's approval commit is a known
   pre-rebase SHA. The timeline
   (`gh api repos/<o>/<r>/issues/<N>/timeline`, event
   `head_ref_force_pushed`) gives the post-force-push head.
2. **Old objects are usually already local.** A worktree shares the
   primary clone's object store, and earlier rounds fetched the
   pre-rebase branch; `git cat-file -t <old-sha>` confirms it.
3. **Compare series, not trees, and prefer a pairwise patch-id walk
   over `range-diff`'s verdicts.** `git rev-list --reverse` both
   ranges, then per position `git show <sha> | git patch-id --stable`
   and compare in lockstep. That answers exactly "did any commit's
   *diff* change?". `range-diff` is noisier in two ways: its `!` also
   fires on message-only edits, and its similarity matcher can
   cross-pair two near-identical commits and fake a reorder. Keep
   `range-diff` for *reading* the interdiffs of the commits the
   patch-id walk flagged — a correct conflict resolution appears as
   context-line changes only, with every payload line common to both
   patches, and new work shows as unpaired commits. A tree-level
   `git diff <oldtip> HEAD` mixes the base's advance into the picture
   and cannot distinguish loss from base movement.
4. **Union-check the end state.** For a conflict-resolved index file,
   `comm -23` the entry sets of `git show origin/main:<idx>` against
   the worktree copy to prove no base-side entry was dropped, and
   cross-check files against the index to prove no branch-side entry
   was.

Bonus tell: replayed conflict commits can carry literal `# Conflicts:`
blocks in their final messages, because `git commit --no-edit` uses
cleanup=whitespace and keeps `#` lines. That is both commit-message
noise and a free map of exactly which commits needed resolution.

## Grade a between-rounds delta formula in a throwaway rebase lab

A mechanism that asks "what changed on this PR since I last looked"
has to survive a rebase, and no amount of reading settles which
formula does. Build a four-commit lab instead — it takes one Bash call
and gives you both rebase shapes plus the negative controls.

Stand up a base branch, a PR branch with two commits, then advance the
base and rebase. Vary one thing to get the second shape: have the PR's
first commit edit the same line the base's new commit does, and
resolve the conflict. Record the pre-rebase PR head before you rebase —
that is the `<prev-head>` a later round would diff against.

Then run the candidate formula and each control over the same pair.
Measured on git 2.55.0:

| Formula | Clean rebase | Conflict-resolving rebase |
| --- | --- | --- |
| `rev-list --right-only --cherry-pick <prev>...<head> ^<base>` | empty | the one PR commit whose patch changed |
| same, without `^<base>` | every commit the base gained | that PR commit **and** the base's new commit |
| `git diff <prev>..<head>` | the base's new files, none of them the PR's | the base's added line, with the PR commit's own added line demoted to context |

The controls are the point. A rebase makes everything the base
gained reachable from the head and unreachable from `<prev-head>`, so
an unbounded commit walk reports upstream work as though this PR had
written it, and a two-dot tree diff — a comparison of two *trees*, not
two commit series — does worse: it shows the upstream line as the
change while demoting the PR commit's own added line to unmarked
context, so the line is still in the patch with nothing marking it as
this round's work. Both
failures are silent and both produce plausible output, which is why a
formula that looks obviously right still has to be run.

Mechanics the lab needs. Set author and committer through the
`GIT_AUTHOR_*` / `GIT_COMMITTER_*` environment rather than writing
`git config user.*`. And spell each range endpoint as a literal SHA in
the command you run — print the two SHAs in the setup call and paste
them into the measurement call, rather than interpolating variables
into the `...` range.

Patch equivalence here is `--cherry-pick`'s patch-id comparison, which
reads context lines as part of the patch. A commit re-applied over
changed context is therefore *not* equivalent to its old self and
stays in the delta even though the change it makes is unchanged. That
is a known over-report, not a bug to design around — the alternative
is a mechanism deciding two different patches mean the same thing.

## Skip the fetch when `origin/<branch>` already matches

`git fetch origin` can stall on SSH (`connect to host github.com port
22: Operation timed out`) — often a biometric-gated key waiting on a
tap, not a network fault, and not something to work around by touching
remotes or auth.

The work frequently does not need the fetch at all: a worktree shares
the primary clone's object store and remote-tracking refs. Before
reaching for `git fetch`, compare:

```bash
git rev-parse origin/<branch>
gh pr view <N> --json headRefOid --jq .headRefOid
```

`gh` goes over HTTPS, so it answers even when SSH is stalled. When the
two match, the objects are local and complete — check out immediately.
Only when they differ do you need the fetch, and then the stall is
worth surfacing rather than retrying in a loop.

The same comparison is what lets a parallel fan-out fetch once in the
spawning session and have every spawned agent skip its own fetch: k
worktrees of one repo share one ref store, so k concurrent fetches
contend for the same `.git` and the loser of the lock race fails rather
than waiting.

## Baseline a lint run before filing anything

Run the linter on the **same file set** at the base revision and at the
branch tip, then compare the two summaries. Only a *delta* is a
finding. A line-length hit is the seductive case on a re-wrapping PR:
the reflowed lines are adjacent to a pre-existing long line, so the
causal story is convincing and wrong.

Extract the base versions with `git show origin/main:<path>` into a
mirror tree under `.claude/tmp/`, copy the repo's lint config in, then
lint both trees and diff the summaries. A missing config silently
changes which rules fire.

**Config discovery is per-directory, closest wins**, so when a tree
nests a second config below the root one, a mirror tree that
reproduces only the root config lints under the wrong rules. Copying
the nested config in verbatim does not fix it either: a relative
`"extends"` such as `"../../.markdownlint.jsonc"` resolves against the
config's own directory, so from a mirror at a different depth it points
at a nonexistent path and markdownlint-cli2 dies with `ENOENT` rather
than falling back. Write an equivalent config by hand with the depth
corrected, plus the same carve-outs.

When the mirror's config lineage is in doubt, skip the mirror and prove
**line provenance** instead: `wc -l` the base blob and check whether
the offending line exists there at all. A hit on a line the diff adds
is introduced by the change under the *in-place* lint, which is the
only run that used the right configs.

**The lint config itself can differ between a branch's fork point and
the base.** A carve-out added to the base after the branch forked makes
the branch raise a pile of hits that all dissolve on rebase. Since
config is discovered upward from each file's directory, linting the
primary clone's copy of the same file is a quick base-config baseline.
Only errors that survive under the base's config are findings.

This is the one place a primary-clone path is the right target, and it
survives the read deny only because the linter is a program the
permission gate has no read table for, so its operands are never graded
for containment. Do not `cat` or `Read` the base config itself to
inspect it: that read denies from a linked worktree, and its
remediation prescribes this worktree's copy — the branch's config,
which is the one the baseline exists to get away from. Extract it with
`git show origin/<base>:<path>` instead. See
[`agent-tooling-notes.md`](./agent-tooling-notes.md) → "Read the
worktree, never the primary clone's path".

### Grading a lint *fix* needs two controls

A clean sweep proves nothing until the same command has been shown to
fail on the pre-fix bytes, and a clean sweep under a broken `extends`
is vacuous.

1. **Negative control.** Write `git show <pre-fix-commit>:<path>` back
   into **the same directory** — a copy under `.claude/tmp/` resolves a
   different config and can silently pass. The exact error line must
   reappear. Delete the copy immediately.
2. **Inheritance control.** Drop a throwaway probe *into* the tree
   carrying both a construct only the parent config pins and a
   construct the local config carves out. The parent-pinned rule firing
   proves the parent merged; the carved-out rules staying silent proves
   the local carve-outs applied. That is non-mutating, unlike flipping
   a value in the parent config.

Check the reported file count against `find <tree> -name '*.md' | wc -l`
— equality rules out a silently-skipped glob — and run
`git status --porcelain` afterward to prove both probes are gone.

## A configured lint rule can be inert

A probe that fires in **neither** scope indicts the rule or its option
value, not the config chain. Never read that silence as evidence about
inheritance.

The worked instance: a root config pinned
`"MD060": { "style": "leading_and_trailing" }` as a propagation tracer,
and a table violating that style raised nothing in either scope. The
cause was not version skew — MD060 is `table-column-style`, whose
`style` accepts only `aligned` / `any` / `compact` / `tight`, while
`leading_and_trailing` belongs to MD055 `table-pipe-style`. The
out-of-vocabulary value silently disabled the rule outright rather than
falling back to its default.

A key that *looks* pinned can be inert because the resolved version
does not implement the rule, because the rule ID is wrong, or because
the option value is out of vocabulary — and none of them warn. Check
the rule's own `doc/mdNNN.md` at the resolved version's tag for its
real name and option vocabulary before trusting it as a tracer. A
silent tracer must be swapped, not interpreted.

Two probes settle a nested-config question conclusively, and neither
needs the happy path:

1. **Chain live:** flip a distinctive setting in the **parent** (e.g.
   `"MD040": false` at root) and watch the child-scope probe's hit
   disappear. An implicit `default: true` would otherwise fire it, so
   only inheritance explains the silence.
2. **`extends` load-bearing versus decorative:** remove the `extends`
   line while the parent carries a distinctive disable; if the
   child-scope probe now fires that rule, the closest config wins
   outright and `extends` is what carries the parent in. Restore and
   watch it go silent again.

Revert every flip and confirm `git status --porcelain` is empty, plus
`git hash-object <file>` equal to `git rev-parse HEAD:<path>`, before
writing anything up.

## `set -e` does not abort a non-final failure in an AND-OR list

`set -e` exempts a failing command that is part of an AND-OR list other
than the last one, so `[ -f missing ] && . missing` continues silently
mid-script. Rewriting that as an `if` is a legibility choice, not a
`set -e` fix, and a comment claiming otherwise is wrong.

The general obligation is what matters beyond the one fact: whenever a
comment explains *why* a spelling is unsafe, mutate the code into the
unsafe spelling and confirm the test goes red. If it stays green,
either the assertion is vacuous or the explanation is false — and the
sentence ships next to correct code, which is what makes it durable.

## A lifetime claim is structural, and no test fails on a wrong one

"Cleaned up on exit", "removed by the trap", "shredded", "discarded",
"temporary" — each is an assertion about what some `cleanup()` actually
does, settled by one grep, and each is easy to write on autopilot when
adding a new per-run artifact. In `claude-vm` the plausible default is
backwards: `cleanup()` removes the credential directory and decides the
image clone's fate, but deliberately retains the run directory so the
diff and apply verbs can read it afterward.

The trap is that these sentences sit beside code that was genuinely
verified, so the tested behavior lends the untested claim unearned
credibility. Treat a lifetime claim like "the only caller" or
"funnelled through a single helper": a structural assertion that needs
its own check.

## A process substitution's child runs asynchronously

Settling what bash itself runs for a given shape means running it with
a marker side effect — `touch M` inside a `mktemp -d` — not reasoning
from the parser. The trap is that a **process** substitution's command
runs in an async child, so checking the marker immediately after the
shell exits reports "did not run" for a shape bash genuinely does run.
Acting on that reading inverts the conclusion and turns an accurate
sentence into a false one.

Put a `sleep` between the run and the check; it flips every
process-substitution row. Command substitutions are synchronous and
never show the race, which is what makes the asymmetry surprising.

Include a known-ran control so a probe that measures nothing announces
itself, and run the probe from a script file rather than as an inline
pipeline with redirects, which the worktree-isolation check refuses.
When a claim asserts identical behavior across bash versions, run it
under each one rather than under whichever is on PATH.

## `awk -v` applies escape processing to its assignment

POSIX awk processes escape sequences in a `-v` assignment, so the two
characters `\` and `t` arrive inside the program as a single real tab.
Nothing warns.

This bites when awk reconstructs a literal line of shell source for a
negative control. The generated control may still *behave* correctly —
a literal tab inside `$'…'` is a tab — so a behavioral assertion passes
while the control no longer matches the code it claims to reproduce.
Keep two copies, one for the assertion and a doubled one for awk, with
a comment saying why they differ.

## `git status` cannot see staleness against the default branch

`git status` reporting "up to date with `origin/<branch>`" says nothing
about the default branch: it compares against the branch's own remote
ref, and a plain fetch does not surface the gap either. Only
`git merge-base --is-ancestor origin/<default> HEAD` answers whether the
branch is behind, and `git diff --name-only <merge-base>..origin/<default>`
names which of the files you care about moved.

Being behind is not by itself something to act on — a rebase answers an
actual conflict, not a precondition for editing a file. But a PR whose
mergeable state is conflicted never self-heals if the repo's rebase
automation acts only on behind-or-blocked states, so do not end a run
assuming a sweep will pick it up.

## A background child inside `$( )` holds the substitution open

Command substitution reads until the subshell's stdout closes, and a
backgrounded child inherits that same descriptor and holds it for its
whole lifetime. So capturing a helper that backgrounds a long-lived
process and echoes its pid blocks for the child's full duration instead
of returning immediately. Redirect the background process's own stdio
inside the helper, so only the `echo` writes to the captured stdout.

The same mechanism ruins timing assertions: a harness captured with
`$( )` measures the stub's pipe rather than the code under test, and
the result either times out or passes for the wrong reason. Have the
harness write its result to a file and read that afterwards. A
foreground `sleep` in a stub also queues a signal behind itself, so the
stub appears to ignore signals it does not actually ignore.

## Negative-control the approved design, not just your own

An approved design in a brief is a *direction*, not a verified
artifact. Run every doctored failure case the finding names against the
snippet exactly as written, and only then against your integrated
version — printing the raw exit status per case, not pass/fail. A
wrapper mapping specific failure statuses to a fail-closed verdict can
sail past the very case it was written for, because the real failure
arrives with a status nobody enumerated.

Three cheap negations, in rising cost:

- **A nil argument at the one call site.** When the fix is "consult a
  new table" or "pass a new argument", pass an empty value instead of
  deleting code, run the new tests, and read the failures. It restores
  with one edit, and the failure list doubles as the pre-fix verdict
  table for the report.
- **Flip the named construct and re-measure.** A justification of the
  shape "keyed on X, not Y, because Y would double-count" is a claim
  about code that does not exist — make it exist for one run, measure,
  restore from a backup copy.
- **A whole-file baseline.** Extract the package at the base revision,
  copy your new test in, and run it there. That separates the rows that
  were already graded from the ones your change flips, which no
  reasoning about the diff can do.

## A negate-check names a set, so run the whole package

"Removing arm A makes test T fail" asserts both that T is in the FAIL
list and that the tests you did not name are not. Both halves are
settled by one command — apply the mutation, run the **entire**
package, read the FAIL list — and a `-run` filter cannot see the second
failure.

A fault-injection test is the shape most likely to go vacuous under
exactly its own control mutation: if the mutation stops the fault from
being injected at all, its subtest passes green while the regression is
really caught elsewhere. Never write the negate-check sentence from the
test you were editing; let the FAIL list name what it names. When a
fault-injection subtest is absent from that list, say in its own
comment what its control actually covers.

## Delete the named mechanism to grade the reason

A sentence of the form "X happens **because** the code treats this as
Y" is two claims, and running the example confirms only the first. To
grade the second, delete Y from the example and re-run: if the verdict
survives, Y was never load-bearing. Keep a positive control alongside,
so the surviving row is not read as "the mechanism is unmodelled".

## A control needs a liveness anchor your change cannot void

A negative control has two halves: the claim, and an anchor row that
still rides the mechanism being swapped, proving the swap does
something. When a later round moves the anchor row too, the control
still compiles, still passes, and separates nothing. Re-anchor on a row
outside the diff's reach whenever a round changes a verdict the control
depends on.

## Pin a spec's empirical premise with a live look

An authoritative Design section can carry a factual premise — "the
observed layout across many projects" — that is simply wrong, and
implementing it faithfully still ships the defect. Fixtures can never
catch it: a fixture restates the author's belief about the layout,
which is the thing that was wrong, and a richer fixture set restates it
again.

Whenever a change encodes a pattern for paths some *other* system
creates — harness scratch directories, cache trees, tool-managed
directories — list the live surface before writing the pattern, and
treat the issue's empirical claim as unverified until you have.

## A bounded poll followed by an unconditional wait is unbounded

A tick-budgeted loop followed by an unconditional blocking call only
decides *when* you start blocking forever. The give-up branch must
return before any blocking call, and that is a structural property
worth asserting structurally — comparing the source positions of the
give-up and the wait — rather than behaviourally.

Escalate through finite rungs, each with its own budget, and treat
"survived every rung" as a real outcome with its own status rather than
falling through. Order teardown so user-visible state is restored
before the reap, since a hang after a partial teardown leaves the
operator's terminal wrong for the whole hang.

## Audit a mechanical prose sweep by its added words

A mechanical sweep over prose produces two kinds of hunk, and only one
can be wrong. Pure deletions are safe by construction and reading them
is waste. **Substitutions** — where the removed token was load-bearing
and the sweeper had to put something in its place — are where every
artifact lives.

Two cheap passes, both scriptable: pair each run of removed lines with
the added lines that replaced it, keep the pairs where the added side
contains a word absent from the removed side, and read those; then
independently re-extract every comment block in the current tree,
join it with the wraps closed up, and grep the joined text for
dangling-phrase shapes. Both must come back clean, and each finds
artifacts the other misses.

A second artifact lives in the same hunks: **wrap raggedness**, where
the sweeper re-wrapped only the lines it touched. A blanket short-line
scan is nearly all false positives, because code lines are short by
nature. The reliable test is whether the first word of the next line
would have fitted on this one at the file's own width — applied only
inside the sweep's own substitution hunks, since a whole-file re-wrap
is churn that buries the real change.

## Derive a stale-identifier list mechanically

When a finding hands you identifiers with the word "candidates", treat
the list as evidence that a class exists, not as the class. Derive the
real set from the two things that disagree — for a rename round, split
each test file on its function boundaries, take the name, and report
any test whose name claims something its body never asserts.

Expect the derived run to surface both members the finding missed and
pure false positives — a test that names a thing deliberately *because*
it asserts its absence, or names the helper it calls rather than a
verdict. The script picks the candidates; you grade each hit by reading
it.

## Derive an enumeration from the structure, never transcribe it

An enumeration that silently drops members is the defect, so closing
the one omission a finding names is not the fix — it ships the sibling
defects and buys another round.

Dump the real structure with a throwaway in-package test, grade every
surface against that dump with a script rather than by eye, and run the
checker **before** editing: it must fail on exactly the dropped
members, and that failure is what makes its later pass mean anything.
Cut each prose bullet at its first dash so a deliberate *negative*
clause does not read as a claimed member. Restructure rather than
truncate — if the complete set no longer reads as a parenthetical, make
it a list. Not every hedged list is in the class: a scoped "some of
these needed X, see Y for the rest" is scoped, not truncated, but say
so rather than leaving the reader to notice.

## When enumeration stalls, make the reach structural

When a round hands you "you closed one more instance of the same
class", and the round before it said the same thing, the enumeration
itself is the defect. Stop adding call site N+1 and rewrite the
mechanism so its reach is a property of the traversal rather than of a
list a human keeps complete. Done once, that closes positions no round
had thought to list.

## Union-resolving a conflict silently reverts in-place edits

A conflict hunk is a *region*, not a change set. When both sides append
to the same tail and also revise existing lines, one region mixes lines
only one side added, lines only the other added, and lines both sides
rewrote from the same ancestor. Pasting both sides keeps the additions
but re-installs your side's stale copy of every line the other revised
— a silent revert with no marker and no diff line to notice missing.

Read what the incoming commit actually changed with
`git show <sha> -- <file>` first, take the incoming side only for the
lines it touched, and take the other side's text for the rest.

## MD060 scores each table separately

With the default `any` style, MD060 does not pick one style per
document: it scores **each table** against the alternatives and reports
violations for whichever would produce the fewest. A table whose cells
happen to be narrow can come out closest to one style while
structurally identical tables in the same file come out closest to
another.

`--fix` repairs the per-pipe styles but never the aligned one, because
fixing a single aligned violation can require rewriting the whole
table. So a `--fix` pass over a batch of MD060 hits predictably leaves
a residue that looks like a different, harder problem and is usually
the same trivial one.
