# Verification playbook

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

### Derive the control from the shipped code, and watch awk's `-v`

A control that reproduces pre-fix behavior is worth having only if it
reproduces the pre-fix *code*. Hand-typing the old loop drifts the
moment the real one changes, and then proves nothing. Slice the real
loop out of the shipped or generated script and transform those same
lines back to the old shape — swap the changed line, drop the added
expansions — then assert that the transform landed (the old line
present, the new expansions absent) before reading anything into the
behavioral flip.

When awk does that transform, its `-v` assignment is not a verbatim
channel: it runs escape processing on the value. Measured with
`awk -v v="$x" 'BEGIN { printf "%s", v }' | od -c` on macOS awk
20200816:

| shell-side value | reaches the program as |
| --- | --- |
| `a\tb` | `a`, real TAB, `b` |
| `a\\tb` | `a`, `\`, `t`, `b` |

So re-emitting a line like `while IFS=$'\t' read -r a b c; do` through
`-v` silently plants a real tab between the quotes. Nothing warns, and
the generated control still *behaves* right — bash reads `$'<TAB>'` as
a tab — so only a text assertion catches it. Keep two copies, and say
in a comment which is which:

```bash
FOO="while IFS=\$'\\t' read -r a b c; do"       # for grep/assert
FOO_AWK="while IFS=\$'\\\\t' read -r a b c; do" # for awk -v
```

Assert with the un-doubled copy. In the same family: `\x27` for a
single quote is outside POSIX awk, so pass it in as `-v q="'"` and
concatenate rather than embedding a hex escape in the program.

### Run the doctored cases against the approved snippet as written

When a brief hands you an approved fix to apply, the approval is of an
idea; the bytes are still unverified. Run the failure cases from the
finding that produced it against the snippet exactly as written,
before shipping it — an approved fix can leave a case from its own
finding failing open. Then negate your fix at its call site and
confirm those cases go back to failing.

### A control's liveness anchor can be voided by your own change

A negative control usually proves its own harness is live by pinning
one row that still lands where it always did. Your change can be the
thing that moves exactly that row, and the control then passes
vacuously — it is asserting nothing about a harness that no longer
runs the path it names. Re-point the liveness half at a row the diff
does not touch, and re-read every control whose anchor your diff
names, not only the controls you edited.

### Prefer the fix that spares an expensive verification

When a finding admits several fix shapes and the branch's strongest
evidence came from a run you cannot cheaply repeat — a real image
build, a real boot, a container matrix — prefer the shape that leaves
that already-exercised path byte-identical and confines the change to
the branch that evidence never covered. The alternative is not a
riskier fix so much as a fix that silently expires the PR's best
measurement.

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

## A background child inside `$( )` holds the substitution open

Command substitution reads until its **stdout closes**, not until the
command exits. A backgrounded child inherits that same descriptor and
holds it for its whole lifetime, so `PID="$(start_listener)"` blocks
for as long as the listener lives even though `echo $!` already
wrote the pid. Measured with a `sleep 3` child: inheriting the
substitution's stdout costs 3s, redirecting the child's own stdio
returns immediately.

```bash
start_listener() { real_listener … >/dev/null 2>&1 </dev/null & echo $!; }
```

The faces it shows, of which the silent mismeasurement is the
dangerous one:

- **The hang.** A helper that stands up a real listener (perl
  `IO::Socket::UNIX`/`INET`, `nc`, `socat`) and echoes its pid appears
  to "pass but take ~30s", or times out. Stock macOS has perl with
  real unix and TCP listeners and does *not* have `socat`.
- **The silent mismeasurement.** A timing assertion built this way
  reports the stub's lifetime rather than the code's — a suite meant
  to prove "returns in ~1s" took minutes while the function under test
  was correct. That looks like evidence and is not.

So when a shell test measures elapsed time: redirect every stub
child's stdio, have the harness write its result to a **file** and
`cat` that afterwards rather than echoing into the substituted stdout,
and sanity-check the wall clock — a "1 second" assertion that takes
minutes indicts the harness before the code. In a stub that must stay
signal-responsive, write `sleep N & wait $!` rather than a foreground
`sleep N`, which queues the signal behind itself and makes the stub
look like it ignores signals it does not ignore.

## Comment prose inside an unquoted heredoc is code

`#` is inert inside a heredoc body, and an **unquoted** delimiter
(`<<CONF`, needed whenever the body interpolates a variable) leaves
backticks, `$( )` and `$VAR` live. A markdown-style comment written
for a human reader — ``# falls back to `cp --preserve=…,xattr` `` —
is paired-backtick command substitution: the shell runs the text and
splices its output into the generated file. In
`plugins/claude-vm/payload/provisioners/podman-mkosi.sh` that
corrupted the generated `mkosi.conf` and surfaced as two unrelated
sounding failures (`cp: illegal option --`, `hashed:: command not
found`), neither of which any pure-function test could see. The same
bug was re-committed later, from writing a `Packages=` justification
that naturally wanted to quote a command name.

So: when debugging a real build failure whose error text names a
command the script does not run, grep the enclosing heredoc body for
backtick pairs, `$( )` and unintended `$VAR` before believing any
story about the diff — check `git diff origin/main..HEAD` on the file
too, since the defect is often older than the branch under review.
And when editing prose *inside* such a heredoc, decide up front to
quote command names with `'single'` or `"double"` quotes; escaping the
backticks works but is one more thing to miscount.

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

## A process substitution's child outlives the shell that spawned it

A claim about *what bash itself runs* — does `: ${Q:-<(cmd)}` execute
`cmd`, does `'$(cmd)'`, does an unquoted here-document body expand — is
settled by running the shape in real bash with a marker side effect
(`touch M` inside a scratch directory), never by reasoning from the
parser.

The trap is the **check**, not the probe. A process substitution's
command runs in an asynchronous child, so the marker is routinely not
there yet when `bash -c` exits, and a check made immediately afterwards
reports the opposite of the truth — which is how an accurate README
sentence gets "corrected" into a false one. Measured on `/bin/bash`
3.2.57, one row per shape, checking with no delay and then again after
`sleep 0.5`:

```text
: <(touch M)          nap=0    did-not-run     nap=0.5  RAN
: ${Q:-<(touch M)}    nap=0    did-not-run     nap=0.5  RAN
: ${Q:-$(touch M)}    nap=0    RAN             nap=0.5  RAN
: '$(touch M)'                                 nap=0.5  did-not-run
```

Command substitutions are synchronous, so they never show the race: a
probe that exercises only those looks sound while every
process-substitution row it also carries is wrong.

So: put a `sleep` between every run and its marker check, and carry both
controls in the same run — a known-RAN one (`: <(touch M)`) and a
known-did-not-run one (`: '$(touch M)'`) — so a probe that measures
nothing announces itself. Run the whole battery once per interpreter the
claim covers, since such a claim usually asserts identical behavior on
each.

Drive it from a script file under `.claude/tmp/<slug>/` invoked as
`bash <script>`; the equivalent inline one-liner is refused, per
[`agent-environment-notes.md`](./agent-environment-notes.md) →
"Paths".

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

**Config discovery is per-directory, closest wins.** This repo commits
a single config, at the root, so a mirror tree needs only that one. Any
subtree that later carries its own config makes the mirror harder than
it looks: reproducing only the root config lints the subtree under the
wrong rules, and copying the nested config in verbatim does not fix it
either — a relative `"extends"` is resolved against the config's own
directory, so from a deeper mirror it lands on a nonexistent path and
markdownlint-cli2 dies with `ENOENT` rather than falling back. Write an
equivalent config by hand with the depth corrected, plus the same
carve-outs.

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

### Grading a lint *fix* needs its controls

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

These probes settle a nested-config question conclusively, and none of
them needs the happy path:

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
