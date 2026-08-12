# Guardrails verification playbook

How to establish a fact about the `guardrails` permission gate: whether
a committed binary carries the source it claims to, and whether a
classifier change does what its PR says it does.

The gate ships policy *inside* committed binaries under
`plugins/guardrails/hooks/bin/<goos>-<goarch>/permission-gate`, so a
stale binary silently ships old behavior even when the Go source is
right. Nothing below is settled by reading the diff; each item is a
command to run.

## Exercise the committed binary

Feed the binary a synthetic `PreToolUse` event on stdin and read the
JSON `permissionDecision` (`deny` / `ask` / `allow` / `defer`):

```bash
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"<repo>","tool_input":{"command":"cat \\"$HOME/.ssh/id_rsa\\""}}' | <bin>
```

Pick commands that map to the PR's acceptance criteria and confirm the
committed binary returns the new verdicts. Only the host-arch binary is
natively runnable; the other arches are built from the same source in
the same commit, so host-arch exercise plus a passing `go test` is
sufficient evidence for them.

The gate active in your own session is the *installed plugin cache's*
binary — main's version, not the branch's. A deny you receive while
working is evidence about main. Probe the branch's binary explicitly
(`<pr-bin> < event.json`) whenever you need the branch's verdict.

### Placing the scratch repo

The gate blocks tool-mediated writes outside the repo root and blocks
`cd <path> && git ...`. Create the scratch git repo under
`<repo-root>/.claude/tmp/<slug>/` and run
`git init -q .claude/tmp/<slug>/<dir>` — a path argument, from the
worktree root. Do not `cd` in one call and `git init -q .` in the next:
cwd does not persist between Bash calls, so the second call
reinitializes the worktree root instead and the scratch dir ends up
with no `.git`, after which every probe reads `defer` — the
no-repo-context residual (#262 moved it off `ask`, so a stale note
expecting `ask` here reads as a probe failure rather than the setup
mistake it is).

Two probe-cwd traps fake a whole result table:

- A cwd that does not **exist** resolves no repo context, so every row
  — including the control — comes back `defer` and the table looks
  uniform and meaningless. That residual is a QUIET one: `defer` is
  also the honest verdict for several rows under test, so the table
  looks plausible where the old `ask` looked odd. Assert the control
  row's expected bucket explicitly rather than eyeballing the column,
  and paste the worktree path, not the primary clone's.
- Count `../` levels against the scratch repo root, not by feel. A
  path that escapes a worktree root can still resolve back inside the
  primary clone. Always run `cat <same-path>` as the paired control:
  the verdict under test must equal `cat`'s, and when both allow, the
  row is contained rather than missed.

### Escape probes must escape the primary clone

With probe cwd inside `.claude/worktrees/<agent>`,
`../sibling-repo/.env` resolves to `.claude/worktrees/sibling-repo/…` —
still inside the primary repository — and the gate allows it. Use
`/etc/passwd` or a path above the primary root, and keep
`cat <escaping-path>` as the control row that must deny.

### Pick the probe form by the track the program takes

The read tracks have different terminals for the same containment
verdict: the read-only-utility track *allows* any operand that is
contained or carved out, while the pager/dumper track (`less`, `more`,
`od`, `xxd`) *defers*. A probe whose track already produces the bucket
you expect proves nothing about the carve-out under review. Read the
program's classifier arm first, then pick a probe whose verdict can
actually change.

Two related facts older notes get backwards: `ls` **is** on the
read-only-utility allow track, so it grades a path rather than
deferring on every one; and a redirect target **is** graded —
destinations land in `sc.redirectTargets` and are decided by
`redirectVetoesAllow`. Neither `ls <path>` nor `cmd > <path>` is a
vacuous probe.

## Prove which source a committed binary came from

### The cheap first move: rebuild and `cmp`

Rebuild with the README's exact invocation and compare bytes:

```bash
GOOS=<goos> GOARCH=<goarch> CGO_ENABLED=0 \
  go -C plugins/guardrails/hooks/permission-gate build -trimpath -o <out> .
cmp <out> plugins/guardrails/hooks/bin/<goos>-<goarch>/permission-gate
```

Byte-identical is conclusive and settles staleness in one command.
**Differing proves nothing** — vcs stamps and build IDs move — so fall
back to the protocol below.

### The decisive protocol when `cmp` differs

Require all of:

1. `go tool nm <committed>` versus `go tool nm <rebuilt>`
   byte-identical. This is compiled-code identity and works for a
   foreign arch with no execution.
2. `go tool buildid` third segment (`a/b/CONTENT/d`) matching.
3. `cmp -l` offsets clustering **only** into vcs-stamp-derived
   regions: the two embedded buildinfo copies (grep the hex dump for
   `vcs.revision`), the `Go build ID:` string near `0x1000`, `LC_UUID`,
   and the `LC_CODE_SIGNATURE` range (`otool -l` gives
   `dataoff`/`datasize`).

`go version -m <binary>` prints go version, module, deps, `-trimpath`
and `CGO_ENABLED` for a foreign-arch binary, so use it to confirm every
committed arch was rebuilt consistently when only one can execute.

### Never read provenance off the embedded vcs stamp

A build run inside a `.claude/worktrees/` linked worktree stamps
`vcs.revision` with the **primary clone's** HEAD, and `vcs.modified=false`
even though the worktree carries the branch's source. A "wrong"
revision stamp is expected, not evidence of staleness; staleness falls
to the `nm` compare and the behavior probes.

### Naming the exact source commit

`git archive <commit> plugins/guardrails/hooks/permission-gate | tar -x
-C <tmp>` for each candidate commit, build all candidates in the same
environment, then byte-compare and `go tool buildid` against the
committed binary. An exact match names the commit. Comment-only `.go`
edits change the artifact (pclntab `file:line`) while `go tool nm`
stays identical, so policy identity and provenance identity are
separable claims.

Scope a "only a `_test.go` changed" claim to the **last commit that
touched `bin/`** (`git log -- plugins/guardrails/hooks/bin/`), not to
the latest commit.

## Adjudicate a "comments only, no behavior change" round

Two commands, and they are decisive rather than suggestive:

1. Non-comment lines changed must be zero:

   ```bash
   git show <commit> -- '<pkg>/*.go' | grep -E "^[+-]" \
     | grep -vE "^(\+\+\+|---)" | grep -cvE "^[+-][[:space:]]*//"
   ```

2. `go tool nm` of the **pre-round** committed binary
   (`git show <parent-commit>:<bin-path> > <tmp>`) versus the tip one
   must be byte-identical, on every committed arch.

Together those separate "the source is comments" from "the shipped
bytes carry the same policy". The tip-rebuild `cmp` answers the
different question of staleness, so run it too.

When `nm` differs on exactly one arch, the claim is still decidable.
Diff the two `nm` dumps and require all of: only change hunks, no
added or removed lines; every differing symbol typed `r` (read-only
data), so no text symbol moved; and one constant delta across them.
Those are the pclntab's boundary and lookup symbols, and that shape is
exactly what added comment lines produce. A moved `T` symbol, an
unequal delta, or an added or removed line refutes the claim instead.

A comment-only round that leaves `nm` identical also settles, for free,
that every other mutation or control count the PR body carries is
unchanged from the previous round — assertions cannot move when no
compiled code did.

## Negate-check the PR's own tests

A green run does not tell you which assertions are load-bearing. Flip
the predicate the new tests exist to exercise and read which assertions
fail.

Do it in an extracted copy, never in the worktree:

```bash
git archive HEAD plugins/guardrails/hooks/permission-gate \
  | tar -x -C .claude/tmp/<slug>
```

That copy builds and tests on its own, so a driver can apply each
mutation, run `go -C <copy> test ./...`, and restore from a `.bak` —
several controls in one pass with the branch untouched. The same copy
takes a throwaway `zz_dump_test.go` that marshals an unexported table
to JSON for an external audit script, which beats regex-parsing a Go
literal.

Do the flip with the Edit tool plus a throwaway `const`, not with a
`python3 -c` that rewrites the source in place — the auto-mode
classifier denies the latter. Add `zz_negate.go` holding
`const reviewNegateProbe = false`, edit the call site to
`…; hit && reviewNegateProbe {`, run, then edit back and `rm` the file.

Count failing assertions from a **non-verbose** run. `go test -v`
prints `t.Logf` output with the same `file_test.go:NNN:` prefix as
`t.Errorf`, so a regex count over `-v` output is inflated by every
passing test that logs. Plain `go test ./...` prints only failures.

Probe helpers go in the package as a `zz_*_test.go` calling
`classifyInRepo(t, cmd, repo)` and `t.Logf`-ing `d.Bucket`,
`d.Operation` and `d.Reason` — the field is `Operation`, there is no
`Rule`.

Subagent cwd resets between Bash calls, so run module commands as
`go -C <abs-module-dir> test ./...` rather than `cd` plus `go`.

## Audit a per-verb flag whitelist

A whitelist-of-flags fail-safe rests on one checkable claim: *this spec
is the verb's complete flag grammar*. Spot-checking three verbs does not
test it, and the table is too big to eyeball. Count the pairs out of
the table itself and diff your pair list against it.

**Get the table by running the package, not by parsing it.**
`git archive HEAD <pkg> | tar -x -C .claude/tmp/<slug>/src`, drop a
throwaway `zz_dump_test.go` into the extracted package that marshals
the live table to JSON (`os.WriteFile(os.Getenv("DUMP_OUT"), …)`), and
run `DUMP_OUT=<path> go -C <extracted-pkg> test -run TestZZDump ./...`.
The dump is the table **after** the constructor runs, so merged
inherited flags and shared vars referenced by name are already
resolved, where a source parse has to reproduce both by hand and
under-reports when it misses one. It is also the only form that can
dump a derived predicate.

Then for each pair run `<tool> <noun> <verb> --help` and diff —
**except the publishing verbs**, which the root `CLAUDE.md` forbids
invoking in any spelling, `--help` included. Take their `FLAGS`,
`USAGE` and `ALIASES` from the command's own registration block
instead:

```bash
gh api "repos/cli/cli/contents/<path>?ref=<tag>" --jq .content | base64 -d
```

That is the parser's own input and beats help on every axis.

### Arity matters more than presence

A bool mismodelled as value-taking consumes the next token, and on a
verb with file positionals that is the one way such a walk can swallow
a path out of containment. Compare each flag set against whether the
help line carries a value-type word.

Expect one false-positive class and know its cause: pflag's
`UnquoteUsage` lifts a **backquoted word out of the usage string** and
renders it where the value type goes, so a bool reads as value-taking.
The tell is the same word appearing un-backquoted in the description;
the proof is the registration block (`grep BoolVar`). Read the source
before filing an arity finding.

A run of help lines parses cleanly with
`^\s{2,}(?:(-[A-Za-z]), )?(--[A-Za-z0-9-]+)(?: (\S+))?\s\s+\S`: the
annotation is one token separated by a single space, and the
description always follows two or more spaces.

### `--help` is not the accepted grammar

gh's help block prints only `--help`, yet pflag answers an unregistered
`h` shorthand with usage plus `ErrHelp` on every verb, so `-h` is
accepted and a table transcribed faithfully from help still misses it.
The mechanism is **pflag, not cobra**: gh's root registers a persistent
`--help` with no shorthand, which `mergePersistentFlags` makes visible
to cobra's `InitDefaultHelpFlag`, so cobra never adds `-h`. Read the
flag library's parser, not just the framework.

The rest of that class is where the teeth are. pflag strips an `=`
immediately after a shorthand (`len(shorthands) > 2 && shorthands[1] ==
'='`), which getopt does not, so `-F=/etc/passwd` opens `/etc/passwd`
while a getopt-shaped extractor reads the value as a relative, in-repo
`=/etc/passwd`. The sibling reading, `-p=f` meaning `--public=false`,
ends the token, so a walk that keeps screening past the `=` reads the
trailing `f` as another flag and swallows the next operand. When a
finding names one unrendered spelling, the parser's whole grammar is
the class.

**Probe the parser through a read-only verb with an invalid value.**
Never run the mutating verb the finding is about. Pick a read verb with
a typed flag and give it garbage: `gh pr list -L=abc` fails inside the
same `parseSingleShortArg` and the error **quotes the value pflag
extracted**, which is the whole answer. On gh 2.97.0 five rows settle
every discrimination at once:

| Spelling | Value pflag extracted |
| --- | --- |
| `-L=abc` | `abc` (the `=` is stripped) |
| `-L =abc` | `=abc` (a separate token is literal) |
| `--limit==abc` | `=abc` (long keeps everything after the first `=`) |
| `-L=` | `=` (under the `len > 2` threshold) |
| `-sL=abc` | `-s` takes `L=abc` |

Zero network, zero mutation. Abbreviations are not a pflag feature
(`--bod x` gives `unknown flag`), and hidden flags are worth one search
for `MarkHidden`.

### `USAGE` and `ALIASES` are claim surfaces too

A `FLAGS` sweep never reaches them. Each spec's positional index is
justified **by** the `USAGE` quote, so dropping an optional bracket is
exactly the fact a reader checks. Dump it per pair with
`gh <noun> <verb> --help | grep -A3 '^USAGE'` and compare byte for
byte.

`ALIASES` is the one with teeth. A table keyed on the canonical verb
misses every alias, so an aliased spelling lands on the
unrecognized-verb residual (*defer* since #262) instead of the
containment *deny*. Resolve the alias to its canonical spelling before
any tier runs.

Enumerating aliases: the block is rendered per command, so the complete
set needs a walk of the whole tree — and the section headings are not
only `AVAILABLE COMMANDS` (`GENERAL COMMANDS` and `TARGETED COMMANDS`
appear too), so match `/ COMMANDS$/` or you silently skip nouns.
Reconcile against `grep -rn "Aliases:" --include "*.go" | grep -v
_test.go` in a source tarball at the tag; that grep is the authority,
since a command under `HELP TOPICS` is never reached by a help walk.

A `<pattern>` operand needs no special handling and is not a hole: the
gate reads the pre-expansion command string, so quoted and unquoted
spellings arrive as the same literal token, and both `filepath.Glob`
and the shell keep the pattern's literal non-meta prefix as a prefix of
every match — grading the prefix bounds the expansion without resolving
it. Probe both directions plus the unquoted twins, and pick the
contained probe on a verb whose own tier still allows.

## Grade a GraphQL allowlist entry against the schema, not the verb name

`ghGraphQLMutationAllowlist` keys on the top-level mutation **field
name** and never on the arguments — `allGraphQLMutationFieldsAllowed`
is handed a list of names — so an entry admits every arm of that
field's input type. A justification of the form "this verb only sets
recoverable issue metadata" is therefore a claim about GitHub's
schema, and it is settled by a read-only introspection query rather
than by the verb's name or by gh's docs:

```bash
gh api graphql -f query='query { __type(name: "UpdateIssueInput") { inputFields { name } } }'
```

That is what kept the generic `updateIssue` off the list in #256: its
input carries an `agentAssignment` arm (`targetRepositoryId`,
`baseRef`, `customInstructions`, `customAgent`), which dispatches a
third-party coding agent at an arbitrary repository — a surface the
gate cannot distinguish from a title edit, since it never inspects
arguments, so no argument inspection would make the verb allowable and
it is refused whichever arm the document sets, aliased or not. #262
moved that refusal from `ask` to `deny`, on the second half of the same
grading: the introspection settles whether a verb can ever be ALLOWED,
and a separate question — is there a TOTAL set of allowed spellings
covering every legitimate use? — settles whether refusing it is a
teaching deny or a dead end. For `updateIssue` there is one
(`updateIssueFieldValue`/`setIssueFieldValue`/`deleteIssueFieldValue`,
`updateIssueIssueType`, `closeIssue`/`reopenIssue`, `gh issue edit`),
so it denies; a verb with no such enumeration defers instead. Grade
**every** arm the input declares, and follow a composite arm into its
own input type.

Two traps in running the query itself:

- **`__Type.inputFields` may be used at most twice per document.** A
  third alias fails the whole query with
  `INTROSPECTION_LIMIT_EXCEEDED`: "Introspection fields may only be
  used 2 times, but some fields were used more than that:
  `__Type.inputFields` (3)". Split the query rather than adding a
  third alias.
- **An input field's name is not the concept.** `UpdateIssueInput`
  spells one concept two ways in several places (`state`/`stateInput`,
  `issueTypeId`/`issueType`, `assignees`/`assigneeIds`,
  `labels`/`labelIds`), so prose enumerating what a verb sets reads as
  a field list unless it says it is a list of concepts.

Whether a spelling exists as a mutation at all is the sibling query —
`__type(name: "Mutation") { fields { name } }` — and it settles a
"this verb is absent for a different reason" claim: GitHub has
`updateIssueFieldValue` and `updateIssueIssueType` but no
`updateIssueIssueFieldValue`.

Neither query mutates anything, and neither substitutes for a verdict
probe: replay the document through the built binary (see *Exercise the
committed binary*) to confirm where the verb actually lands.

## Audit a widening: the regression hides in flag values

When a PR adds a program to the read-only allow table or gives one an
operand grammar, the leak is usually through a **flag value**, not
through an operand. Operand rows have tests; flag-value rows do not.

- **A new operand grammar that consumes a flag's value.** `-e`'s value
  is a pattern and is correctly consumed; `-f`'s is a file the program
  genuinely reads, so consuming it moves an escaping path from deny to
  allow. Prove the read with a two-file sandbox.
- **A new table entry with no grammar** falls back to `pathOperands`,
  which skips every leading-dash token, so the **glued** spellings of
  its file-valued flags (`-X/etc/passwd`, `--exclude-from=`) skip
  containment while the separate-token spelling still denies. Same
  command, two verdicts by spelling.

Probe both spellings of every value flag, always, and say which are the
PR's regression and which are pre-existing holes the fix should sweep
anyway.

**A verb-level allow arm must inspect flags.** A `case "status":` that
returns allow for a whole subcommand also allows the flag that dumps
the live credential. Check `<tool> <verb> --help` for a flag that
changes *what is printed* before accepting any new verb allow — read
the help text and probe the gate binary synthetically; never run the
command against the real credential.

### The counterfactual swallow story

In the read-only-utility track, a utility with **no** operand grammar
takes its containment operands from `pathOperands`, which is
flag-model-unaware: it skips only leading-dash tokens and keeps every
non-dash token, a value flag's value included. So "modelling `-X` as a
value flag would swallow the path operand and skip containment" is
counterfactual for such a program. Flag-model changes can only move a
form between defer and allow-with-full-containment; they can never
remove a token from the containment walk.

The story *can* be true for a program that has its own grammar, since
those extractors are value-flag-aware. But the extractor is
`utilitySpec.operands`, which is `pathOperands` or the program's
grammar **plus** the values of the program's declared `pathValueFlags`,
appended. So the swallow story is false even for a program with a
grammar when the flag is a declared path flag. Read the table entry,
not just the function: only a flag absent from `pathValueFlags` can
still hide a path.

## Re-derive a "N rows move" figure

Never adopt the figure and never hand-list the row set: derive it from
the compiled maps.

**Dump the cross from the package itself.** `git archive HEAD` the
package into `.claude/tmp/`, drop in a `zz_dump_test.go` that unions
the nouns and verbs out of every table the classifier dispatches on,
and write `<tool> <noun> <verb>` lines to `$CROSS_OUT`. Two things make
it honest: function-local literals have to be restated, so assert every
restated member back through the real predicate in the same test, plus
a non-member, or you are grading your own transcription; and report the
cross as `<nouns> x <verbs>` with the union that produced each side, so
a reader can re-run it.

**Replay with a thread pool, not a loop.** A `ThreadPoolExecutor(8)`
over `subprocess.run([binary], input=json.dumps(event))` does an
order-1,000-row cross times two binaries in a couple of minutes; the
gate forks `git rev-parse` per row, so serial is painful. Extract the
old binary by redirecting `git show origin/main:<bin-path>` to a file
and `chmod +x` it. Report the composition as a counter of
`"<old> -> <new>"`.

The moving **set** is invariant to the cross's width; the count is not.
So grade the derivation, not the total: a PR that states a width and
its composition is reproducible, and one that states a bare count is
not.

Three more replays are cheap once the rig exists:

- **Last-reviewed tip to current tip**, bounding what the rounds since
  the last review changed. Anything moving beyond the directed change
  and its aliases is the finding.
- **The same cross with operand suffixes** — escaping positional, each
  path flag escaping, `--`, `-` with a redirect, bare redirect,
  contained counterparts, an unmodelled flag, `-h`. **Zero**
  `deny -> ask`, `deny -> defer` or `deny -> allow` is a much stronger
  statement that containment still outranks the new arm than a
  hand-picked probe list. Count `defer` as a weakening target since
  #262: it is now the residual bucket, so a lost deny lands there as
  readily as in `allow`, and a cross that only watches `allow` misses
  it.
- **Alias parity**: for every row whose noun or verb is an alias,
  assert `tip(alias) == tip(canonical)`. Zero violations settles that
  the resolution grants exactly the canonical verdict and nothing
  wider.

## Redirects have three attach points

`mvdan.cc/sh` parks redirects on the enclosing `*syntax.Stmt`, not on
the `CallExpr`. So `cmd < f` and `{ cmd; } < f` reach the walker by
different routes: the first through the `CallExpr` arm, the second only
if every compound arm (`Block`, `Subshell`, `IfClause`, `ForClause`,
`WhileClause`, `CaseClause`) forwards the enclosing statement's
redirects down. A statement with redirects and **no command at all**
(`> f`, `[[ -f x ]] > f`, a bare assignment) is a third route, reached
by neither, and needs a redirect-only fallback to be graded at all.

Tests and an author's own matrix cover the simple form. Run the claimed
matrix three times — as written, with every command wrapped in
`{ …; }`, and with the command removed so only the redirect remains —
on both the input and output axis. Assert the operand control alongside
it, which proves the *construct* is walked and isolates a lost redirect
from an unwalked node. An escaped write redirect earns `allow`, which
outranks `settings.json` and so beats the user's own deny list.

## Enumerate what a residual bucket was catching before you move it

Changing the bucket a *residual* arm returns — the unrecognized-verb
floor, the no-repo-context arm, the unknown-flag screen — moves every
call that was reaching it only by falling through, and those calls are
invisible in the diff. #262 moved the unrecognized-`gh` floor from
`ask` to `defer` and would have dropped `gh auth token` (which prints
the live OAuth token) out of the credential tier, purely because
nothing else classified it.

The enumeration is a replay, not a reading. Cross the tip binary
against the merge-base binary over the whole probe corpus and list
every row whose bucket moved; then grade each mover on its own terms
rather than as a consequence of the intended change. A row that was
only ever escalating by accident shows up here as a bucket change with
no corresponding arm in the diff.

The synthetic replay also reads the evolution log, which is the second
half of the evidence since #262: `PERMISSION_GATE_LOG=<path>` puts the
record where the probe can read it, and `ask`, `deny` and `defer` each
append one. That is how a probe distinguishes *which* arm produced a
`defer` — two arms returning the same bucket are indistinguishable on
stdout, because `emitDecision` blanks a defer's reason. Assert the
`operation` label, not just the bucket, whenever more than one arm can
produce the verdict under test.

`operation` and `analysis` are populated only where the arm had an
account to give: a `deferJudgment` site fills both, while a bare
`deferToPipeline` — a contained pager read, say — logs a record with
both fields empty. An empty `operation` is therefore a positive result
(the line reached no analysed arm), not a probe that failed to capture
one, and an ALLOW appends nothing at all.

## When an ask becomes an allow, re-audit the helpers

A PR that turns a blanket ask into a conditional allow silently
promotes whatever helper computes the condition from *cosmetic* to
*load-bearing*. Any shape that helper mis-reads was harmless while
everything asked and becomes a bypass the moment one branch allows.

List every field of the result struct the new condition reads, find the
function that populates each, and read that function's own doc comment
for its **original** purpose. Then enumerate the input shapes it drops
or mislabels — indirection such as fragment spreads, includes, aliases
and variables, and anything skipped by depth or paren counting — and
probe each against the committed binary, comparing with the
`origin/main` binary to separate regression from pre-existing.

The author's own new guard is the tell: a PR that adds one narrow
anti-indirection check has usually stopped at one level of indirection.

## Baseline a widening against the static spelling, not against zero

Before filing a widened-hole finding, replay the fully-literal spelling
of the same operation on the **old** binary. When the static spelling
already allowed on main, a shield that admits the dynamic spelling adds
no capability — a follow-up-issue class, not a High. Blocking only the
dynamic spelling while the static one passes just recreates the
two-spellings-two-verdicts inconsistency.

Baseline against main to tell *residual* from *regression*, never to
decide whether to file at all: pre-existing on main, plus the same
defect class, plus a verb the table already models, means fix it here.

## Probe every equivalent spelling of a guarded path

A guard that compares **normalized** path strings is only as strong as
its normalizer and as the set of inputs feeding it. Run each of these
through the real function:

- `//a//b` (repeated separators)
- `/a/b/` (trailing separator)
- `/./a/b` and `/a/./b` (a `.` segment before *and* after the
  protected component; they behave differently, because the protected
  component is matched as a prefix)
- `/a/../b` (a `..` segment)
- `/a/bfoo` versus `/a/b` — a prefix-but-not-component match, as the
  must-still-pass control

Then ask what the **runtime** does with the un-normalized string: a
host-side guard compares strings, and the kernel on the other side
*resolves* them. Grade the finding on the leg with no backstop.

The guarded string usually has more than one input. Grep for every
construction of a guarded path (`"$X/$y"`, defaults, fallbacks) and ask
which value lands in each slot — a value validated only as a
**charset** is not validated as a path component, and a default built
from a different field never reaches the check that sits inside the
`if` for the explicit one.
