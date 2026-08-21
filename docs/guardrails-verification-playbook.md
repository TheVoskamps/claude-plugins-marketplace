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
JSON `permissionDecision` (`deny` / `ask` / `allow`):

```bash
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"<repo>","tool_input":{"command":"cat \\"$HOME/.ssh/id_rsa\\""}}' | <bin>
```

**A defer has no `permissionDecision` at all.** Since #271 the gate
spells its abstention as the envelope with the field omitted —

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse"}}
```

— because the literal `"defer"` makes Claude Code pause the tool call
for later resumption, which never resolves inside a subagent. So a
probe reads a defer as *the field's absence*, and any jq expression
that pulls `.hookSpecificOutput.permissionDecision` yields `null` for
a deferred row rather than the string `defer`. A probe table that
buckets rows by that string therefore shows `null`, not a failure;
what WOULD be a failure is a row emitting the literal.

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
  primary clone — which is a deny of its own (`read:worktree-escape` /
  `bash-read:worktree-escape`), not the cross-repo deny the probe was
  aiming at. Always run `cat <same-path>` as the paired control: the
  verdict under test must equal `cat`'s, and the reason string must name
  the rule the row is probing.

### Escape probes must escape the primary clone

With probe cwd inside `.claude/worktrees/<agent>`,
`../sibling-repo/.env` resolves to `.claude/worktrees/sibling-repo/…` —
still inside the primary repository — so the gate denies it as a
worktree escape rather than as the cross-repo escape the row claims to
probe. Read the reason string, not just the bucket: both are denies. Use
`/etc/passwd` or a path above the primary root, and keep
`cat <escaping-path>` as the control row that must deny cross-repo.

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

The teaching question is asked of the DOCUMENT, not only of the verb,
and a probe that sends the verb alone cannot see the difference. A
document bundling a redirectable verb with one the gate can only
refuse defers, because the deny would teach about one field and leave
the other with nowhere to go. So a redirect-deny probe needs both
controls: the verb alone (and bundled with allow-listed companions)
must deny, and the verb bundled with an unredirectable mutation —
`mutation { updateIssue(…) deleteIssue(…) }` — must defer. Run the
bundled row in both field orders. The check walks the document's
fields, so a probe that always puts the redirectable verb first cannot
tell a whole-document rule from a first-match one.

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

Write that file under `<repo-root>/.claude/tmp/<slug>/`, and spell the
extraction as one bare `git show … > <file>` — never
`cd <dir> && git show … > <file>`. A `cd <path> && git …` prefix is
denied by the forbidden-form guard (CVE-2025-59536) before the redirect
is graded at all, so that spelling is not a probe of the redirect arms
and cannot serve as a negative control for them: the
redirect-unresolvable **defer** holds for `git`, `gh` and `aws` in the
`;`-joined and prefix-free spellings, and the `&&`-joined `git` one
denies for an unrelated reason.

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
`defer` — every defer is byte-identical on stdout, because
`emitDecision` omits both the decision and the reason for one. Assert
the `operation` label, not just the bucket, whenever more than one arm
can produce the verdict under test.

`operation` and `analysis` are populated only where the arm had an
account to give: a `deferJudgment` site fills both, while a bare
`deferToPipeline` — a contained pager read, say — logs a record with
both fields empty. An empty `operation` is therefore a positive result
(the line reached no analysed arm), not a probe that failed to capture
one, and an ALLOW appends nothing at all.

An unrecognized *program* is not one of those empty rows: it reaches
the `bash:no-specific-rule` residual, which is a `deferJudgment`. So
`npm test` yields a populated record, and a probe that expected an
empty `operation` from "the gate has no rule for this" is measuring the
wrong thing. That label also loses to any other defer analysis on the
same line, so a probe asserting it must not put a git/gh/aws arm in the
same command.

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

## The `/tmp` cwd degrades two rules in opposite directions

`classifyCmd` sets `CWD: "/tmp"`, which is not a git repository. Two
different classes of rule read live git state, and the missing
repository breaks them the opposite ways round — so "the `/tmp` cwd"
is not a fact you can reason about in general. Check which way the rule
under test degrades.

**Origin-aware rules fail OPEN.** Foreign-target scoping compares a
`gh` write's `-R`/`--repo` target against the session repo's origin, by
calling `git remote get-url origin` at classify time. Under `/tmp` the
lookup fails, the scoping is skipped, and the command *allows* rather
than reaching the escalating verdict. Fail-open on a git failure is
deliberate for these refinement rules — a git hiccup must not block
normal use — so a test with no real cwd silently proves nothing about
the branch it was written for. Give the event a real repository with an
origin remote.

**Containment fails CLOSED.** Path operands go through
`resolveRepoContext`, which errors without a repository, so the call
lands on the no-repo-context residual before any path is graded. The
damage here is asymmetric and only half of it is loud: a row asserting
ALLOW fails visibly, while a row asserting the residual's own bucket
keeps passing — for the wrong arm — so the assertion survives while the
coverage evaporates.

That second half got worse when the residual moved to `defer`, because
`defer` is also the honest verdict for the whole judgment middle, so a
row landing there now looks plausible where the old bucket looked odd.

So on any change that puts new operands through containment, sweep the
existing tests for rows of that program carrying a path-shaped operand.
Move them to a helper that initialises a real repository, or pin the
reason rather than the bucket, so a bucket-only pass cannot hide the
swap. This is the sibling of negate-checking: that establishes a *new*
test reaches the new code, this one establishes an *old* test still
reaches the code it was written for after the code moved beneath it.

## The gate adjudicates the commands you edit it with

The compiled gate is a live `PreToolUse` hook while you work on it, so
it rules on your own tool calls in real time. The forms it refuses are
not obstacles to route around — each has a plain spelling that works:

- A `git` invocation carrying a command substitution or heredoc is
  denied as non-static argv. Write a multi-line commit message to a
  file under the worktree's own `.claude/tmp/<slug>/` and use
  `git commit -F <file>`; the same applies to PR bodies via
  `--body-file`. A file a publish verb sends to GitHub is itself
  subject to read containment, so anchoring scratch inside the worktree
  satisfies both rules at once. The anchor allowlist —
  `$(git rev-parse --show-toplevel)`, `--git-common-dir`, `$(pwd)` —
  is the one substitution that resolves, in every word position.
- `git -C <absolute-path> <subcommand>` is a forbidden form even in a
  subagent. Run bare `git <subcommand>`; the cwd is already the
  worktree root on every call.
- A read or a write anchored at the *primary clone's* path is denied
  from inside a worktree, because it resolves outside the agent's own
  tree. The read deny is what stops evidence being gathered from the
  wrong tree: the primary clone's working files can differ, so the read
  would return plausible content with no error.
- BSD `sed -i ''` is denied: the mandatory empty suffix reads as a
  write target that resolves outside the repository, so no in-repo
  spelling gets through. Use the Edit tool, or copy the file and edit
  the copy — `cp` itself is fine.
- Setting `HOME=` inline is refused, since a redirected HOME changes
  where git reads configuration and therefore where git might write.
  This does not make a HOME-redirected experiment impossible: move it
  into a container, where the redirection is the container's business
  and no host git configuration is in play.
- A multi-construct one-liner — a `for` loop, an `&&` chain, anything
  carrying a redirect — is refused as too complex to verify it stays
  inside the worktree. Write the script to a file and run
  `bash <script>`, or issue one plain command per call. This bites
  exactly when probing a rebuilt binary against several synthetic
  events: run one invocation per call.
- Reads outside the repository are refused for `cat`, `grep` and
  `find`, so a dependency's source under a module cache is unreadable.
  Query it through its own tooling instead — `go doc <import-path>.<Symbol>`
  answers exported field and method shapes without a filesystem read.

Forms that look like they should be refused and are not, so no
workaround is warranted: a leading `GOOS=`/`GOARCH=`/`CGO_ENABLED=`
assignment on a `go build`, `podman run` including a host bind-mount,
`mkdir -p` and `>` redirects relative to the worktree cwd, and an
environment prefix on a program the git/gh/aws classifiers never see.

The Edit tool enforces the worktree boundary independently of the gate.
Anchor every path to the worktree root, reads included: a primary-clone
read is denied too, so an unanchored path fails on the Read rather than
surviving to fail on the Edit.

## Settle a reach claim by running the classifier, not by reading it

A claim about the gate's *reach* — "the walk descends into every
process substitution", "every operand funnels through this choke
point", "all three tracks" — is settled with a throwaway
`zz_docprobe_test.go` in the package that logs the classifier's
verdict for each shape, run and then deleted before staging.

Reading the helper bottom-up confirms such a claim; only running it
refutes one. The helper usually does exactly what its doc comment
says, and the falsehood is in its *call sites*: a descent helper that
genuinely descends into every substitution of the word it is handed
still misses the shapes its single caller never passes it. So grep the
helper's callers first — one call site is the tell that a "for every
X" claim is scoped — and then probe.

To say whether a verdict you measured is a widening or was already
there, probe the merge base the same way: extract that revision of the
package with `git archive` into a scratch directory, copy the probe
file in, and run it there. Guessing turns a pre-existing allow into a
reported regression.

Never prescribe a gate-permitted spelling you have not run. And note
that the verdict you measure is the branch's source, while the gate
adjudicating your own tool calls is the installed plugin cache's
binary.

## The package restates one containment rule at each call site

After a change to containment or classification, the diff's own doc
comments are not the sweep. This package duplicates each containment
rule as a paraphrase at every call site that depends on it, across
several files, so a behavior change leaves the other paraphrases
describing the old verdict.

Grep the whole package directory for the old behavior's vocabulary —
the verb-and-outcome pair being changed — rather than trusting the
author's call-site edit as evidence the sweep is complete.

A rebucketing round has a second wave: renaming the tests leaves their
*doc comments* still describing the old verb, so the comment sweep
needs a pass after the rename, not before it.

## Editing a comment here invalidates the committed binaries

The binaries under `hooks/bin/<goos>-<goarch>/` are build artifacts of
the sources beside them, and Go embeds file:line, so adding or
removing even a comment line shifts them. A doc pass that fixes a
stale Go doc comment — squarely in scope — otherwise leaves the
shipped binaries built from a source tree that no longer exists, and
the next reviewer's rebuild-and-compare shows a delta to adjudicate.

So after editing any `.go` file under `hooks/permission-gate/`, run
`gofmt -l .`, rebuild every committed arch with the README's exact
commands, and stage the binaries in the same commit. They
cross-compile from macOS with no extra setup. Run `gofmt -l .` even
when you touched no Go file: an unformatted map alignment left by an
earlier round is cheapest to catch here.

## An unrunnable-binary case needs a wrong GOOS, not a wrong GOARCH

Planting a wrong-architecture ELF to test a "present, exec bit set, but
not runnable" path does **not** produce an exec failure on this host:
the podman machine has qemu `binfmt_misc` handlers registered, so the
foreign binary runs under emulation and returns a correct decision with
exit 0. The case looks like it passed while testing nothing, and the
emulation is invisible unless the probe prints the raw exit status per
case.

The reliably-unrunnable case is a wrong **GOOS** — a Mach-O binary at a
`linux-*` path, or the reverse — which has no handler and gives an exec
format error. Cross-check both directions.

## `cat` already allows, so probe a read carve-out with something else

The gate has two bash read tracks with different terminals for the same
containment verdict: the curated read-only utilities (`cat`, `head`,
`grep`) terminate in **allow** for any operand that is contained or
lands in any carve-out, while the path-reader track (`less`, `more`,
`od`) terminates in **defer**.

So an assertion that `cat <new-carve-out-path>` allows passes
identically before and after the carve-out exists. Probe a new read
carve-out with a path-reader utility or the file-read tool, or the
negate-check leaves every `cat` assertion green while proving nothing.

## Measure which AST node a construct hangs off

The gate walks a shell AST, and when a fix depends on *which node* a
construct attaches to, a throwaway in-package probe that parses a list
of command strings and logs the node type plus redirect count costs a
minute. Assumptions that read as obvious are wrong often enough to
matter: a bare truncate idiom parses to a statement with a nil command
and one redirect, so an early nil-command return silently drops it; a
redirect on a binary command parks on the *inner* statement, leaving
the outer one with none; a redirect on a function definition parks on
the body's statement.

## The worktree git gate counts git-prefixed basenames

In a worktree-isolated agent, a git command is refused as "names git
more than once" when an argument's **final path component** begins with
`git` followed by a word — a directory like `git-tools`, or a file
whose basename starts that way. The count of literal `git` tokens in
the command is not what decides it.

The workarounds are mechanical: name a deeper component, the parent
directory, or a specific file inside the offending directory. The same
command with a broader path argument runs fine.

## A parity fix moves verdicts in every direction

A finding names the direction that alarmed the reporter. Making a
respelling inherit the canonical verdict also moves every other row of
the same class, including rows that become *more* permissive — and
those are the ones a reviewer will find if you do not. Say the
permissive ones first.

**A count is a property of the row set, not of the fix.** Rounds that
each hand-build their own row list, each measure honestly, and each
report a different number are quantifying over different sets. A bare
"N rows moved" is unfalsifiable: nobody can reproduce it, and the next
reviewer's own number reads as a defect. State the row set in the same
sentence as the number, build that set by crossing the code's own
tables rather than listing rows you thought of, publish the derivation,
and re-measure at a deliberately wider cross — the moving set is
invariant to the width, so two measurements beat one number.

Prefer stating a permissive set in closed form over enumerating it. A
screen that scans tokens for a flag name, blind to position, over-asks
exactly where the real parser does not read that token as a flag —
after a separated value, and after the end-of-options marker. That
description is checkable against the verb's own flag map; a hand-listed
enumeration is not, and drops a member.

Build one row list covering the fix, its mirror and unrelated controls,
and replay it through both the base and rebuilt binaries in one table.
Keep a known-contained read in it: if the probe's working directory
loses repository context every row reads the residual bucket and the
table is meaningless. Two traps produce exactly that — a working
directory that does not exist, and relative levels counted by feel that
resolve back inside the primary clone (a worktree-escape deny, not the
cross-repo one).

## A teaching verdict is graded per document, not per element

When a tier's membership rule is "this verdict is legitimate only
because its message tells the caller what to do instead", the rule is a
property of the whole input. A check that fires on the first matching
element returns a message enumerating that element's alternatives while
saying nothing about an uncovered sibling — a dead end, which is what
the tier forbids.

The tell is a codebase that already spells all-elements-must-pass for
one set and not the other; mirror it. Probe per shape, not per verb:
the element alone, with a covered companion, with an uncovered
companion, and with the uncovered companion **first**, since a
first-match loop is order-sensitive and a same-order probe hides it.

A map whose value is a single string forces the rationale into the
caller's message, which then gets written for the founding member;
splitting the value keeps a second member from inheriting the first's
justification verbatim.

## Rank a thin residual, do not just fill it

When a high-frequency site logs an empty record, the obvious fix is to
give it an account — but read the aggregator that picks which record
the whole call emits first. If it is first-wins over "has an account",
filling the blank makes the residual *win* lines it previously lost,
because the residual usually fires on the first part of a command, and
the specific account a tuner actually needs gets dropped.

The repair is a rank, not a discard: hold the residual aside and use it
only when no other account was seen. Assert the ranking in **both**
orderings — the informative-part-first row passes with or without the
fix, so only the residual-first row proves anything. Say which is the
control in the test's own comment, or the next reader deletes the wrong
subtest.

## A tier premise is often a vendor fact

A tier that carves one form out as safe rests on a claim about a
third-party product, which no amount of reading this repo settles.
Check it at the vendor's documentation and quote them in the message,
so the next reader can re-grade the premise without re-deriving it. A
default that is *unlisted* rather than private is the classic case: the
carve-out publishes a readable copy of a contained file to a durable
URL, and containment can never catch that, because containment bounds
which file, and a contained file is exactly where "the bytes stay on
the machine" fails.

Two follow-ons. A screen that decided a branch you are making
unconditional is **dead, not repurposable** — a walk that reported a
flag being *named* cannot describe the value it carried, so reusing it
to sharpen the message produces a false sentence. And negative-control
a structural escalation as a **pair**: removing the arm must fail
loudly, and restoring the old table entry must fail *nothing*, which is
what proves the escalation comes from the arm rather than the table.

## State the harm, not the gate's blind spot

An escalation message states the harm, never the gate's ignorance. "The
gate cannot tell what this publishes to" invites the reader to treat
the unknown as probably-fine and click through; naming what actually
happens puts the decision in front of them. Before citing an unknown,
ask which value of it is the bad one — if the answer is "either, and
one is worse than the case already escalated", the unknown was never
the argument.

Scope such an escalation to the whole verb, not to the flag spellings
that carry the payload; scoping by flag is the sensitivity that
produces holes. And assert the framing in a test that both requires the
harm words and forbids the blind-spot vocabulary, so a later reword
cannot quietly reintroduce it.

Ask rather than deny where a human has legitimate reasons to proceed:
this gate governs interactive human sessions as well as agent ones, and
one click preserves those where a deny does not.

## An upstream guard decides which rows can reach yours

When a finding says to narrow a guard, every row written for the new
behavior must first survive whatever runs *before* it. Pick the row by
reading the upstream guard's own table, not by choosing a token that
reads plausibly — rows pairing a static path with a dynamic value
routinely die on a non-static-argv precondition, which is a different
guard with a different table, and never reach the code under test.

## A recorded digest is of a pipeline, not of a value

A digest quoted in a finding or a PR body is of whatever byte stream
the author's pipeline produced. A tool that terminates its output with
a newline, one that does not, and hashing the whole file all give
different answers, and every one is "the digest of that value" by an
honest description — so a mismatch reads as "the artifact moved" when
nothing did.

Reproduce the candidate pipelines against the *pre-change* revision
first and match one, which proves you have the author's convention.
Cheaper and stronger: compare the git blob hash across the two
revisions, which needs no convention at all, and use the recorded
digest only to confirm you and the reviewer mean the same artifact.

## Baseline the rebuild before editing, and grade it by content

Because a rebuild absorbs any difference between your toolchain and the
previous builder's, do the baseline **first**: confirm the Go release
matches what the committed binary was built with, then rebuild every
arch from the unmodified tip and compare against the committed
binaries.

That comparison is opportunistic and expires. The embedded revision
stamp comes from the primary clone's HEAD, so a byte comparison matches
only while the default branch has not moved since the binaries were
built. When it has, all arches differ inside the build-information
region with nothing wrong — do not report that as a provenance failure,
and never write "a rebuild is byte-identical to the committed binary"
into a PR body, since it is false for every later reader.
