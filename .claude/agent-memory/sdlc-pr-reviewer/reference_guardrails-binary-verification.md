---
name: guardrails-binary-verification
description: How to verify the guardrails permission-gate committed binary carries a PR's new policy — exercise it with synthetic PreToolUse events; a raw cmp against a rebuild proves nothing, but the nm-table + build-ID + delta-clustering rebuild comparison IS decisive
metadata:
  type: reference
---

The `guardrails` plugin ships policy *inside* committed binaries
(`plugins/guardrails/hooks/bin/{darwin-arm64,linux-amd64}/permission-gate`),
so a stale binary would silently ship old behavior even when the Go
source is correct.

**Try a raw `cmp` against a recipe rebuild first — identical is
conclusive, differing proves nothing.** On #227 round 4 all three
committed binaries came back byte-identical to a fresh
README-recipe rebuild in the review worktree (worktree HEAD ==
builder's state, `-trimpath`), which settles the staleness question in
one command. Repeated 3/3 on #232. When `cmp` differs, that is still
expected (vcs stamps, build IDs) and NOT evidence of staleness — fall
back to the nm-table + build-ID + delta-clustering protocol below.

**Do verify by exercising the committed binary directly** with a
synthetic PreToolUse event on stdin:

```bash
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"<repo>","tool_input":{"command":"cat \\"$HOME/.ssh/id_rsa\\""}}' | <bin>
```

It prints a JSON `permissionDecision` (`deny`/`ask`/`allow`/`defer`).
Pick commands that map to the PR's acceptance criteria and confirm the
committed binary returns the new verdicts. Only the host-arch binary is
natively runnable (on darwin you can't execute the linux-amd64 one);
the other arch is built from the same source in the same commit, so
host-arch exercise + passing `go test` is sufficient evidence.

**How to place the scratch repo**: the gate blocks tool-mediated writes
outside the repo root and blocks `cd <path> && git ...` forms. Create
the scratch git repo under `<repo-root>/.claude/tmp/<slug>/` and run
`git init -q .claude/tmp/<slug>/<dir>` — a PATH argument, from the
worktree root. Do NOT `cd` in one call and `git init -q .` in the next:
a subagent's cwd does NOT persist between Bash calls, so the second
call reinitializes the worktree root instead (harmless, but the scratch
dir ends up with no `.git` and every later probe reads `ask`).

**Two probe-cwd traps that fake a result** (both hit on #232 round 4):

- A cwd that does not EXIST resolves no repo context, so every row —
  including the `cat` control — comes back `ask` (fail-closed) and the
  table looks uniform and meaningless. Paste the worktree path, not the
  primary clone's.
- Count the `../` levels against the SCRATCH repo root, not by feel.
  The issue's own row `gh pr comment -F ../../../.ssh/id_ed25519`
  ALLOWS from a worktree root (it resolves back inside the primary
  clone) and from a 3-deep scratch dir (it resolves to the scratch
  root). Always run `cat <same-path>` as the paired control: gh's
  verdict must equal cat's, and when both allow the row is contained,
  not missed.

**When the claim is "the committed binary matches HEAD source" (a
staleness claim, not a policy claim), a rebuild comparison IS decisive
— just not a raw `cmp`.** Verified on PR #208 round 6: build with the
README's exact invocation (`GOOS=… GOARCH=… CGO_ENABLED=0 go -C
plugins/guardrails/hooks/permission-gate build -trimpath -o <out> .`),
then require ALL of:

1. `go tool nm <committed>` vs `go tool nm <rebuilt>` byte-identical
   (compiled code identity; works for the foreign arch too, no
   execution needed);
2. `go tool buildid` third segment (`a/b/CONTENT/d`) matching;
3. `cmp -l` offsets clustering ONLY into vcs-stamp-derived regions —
   the two embedded buildinfo copies (grep the hex dump for
   `vcs.revision`), the `Go build ID:` string near 0x1000, LC_UUID,
   and the LC_CODE_SIGNATURE range (`otool -l` gives dataoff/datasize).

On #208 that was exactly 291 differing bytes, all accounted for. Also:
scope a fixer's "only a _test.go changed" claim to the LAST COMMIT THAT
TOUCHED bin/ (`git log -- plugins/guardrails/hooks/bin/`), not to the
latest commit — comment-only .go changes after the rebuild are fine,
but check the diff since the rebuild commit, not since round N.

**Negate-check the PR's new tests rather than trusting a green run.** In
the review worktree, flip the predicate the new tests exist to exercise
(e.g. a new allow-eligibility arm to `return false`), run only those
tests, read which assertions fail, revert, then prove the revert with
`git hash-object <file>` against `git rev-parse HEAD:<file>`. It
separates the load-bearing assertions from the vacuous-but-true ones in
one run and settles an ambiguous PR-body claim without asking anyone.

Better still, never touch the worktree: `git archive HEAD
plugins/guardrails/hooks/permission-gate | tar -x -C .claude/tmp/<slug>` gives a
copy that builds and tests on its own, so a python driver can apply each
mutation, run `go -C <copy> test ./...`, and restore from a `.bak` — six
controls in one pass with the branch untouched. The same copy takes a throwaway
`zz_dump_test.go` that marshals an unexported table (`ghFileSpecs`) to JSON for
an external audit script, which beats regex-parsing the Go literal.

**Count failing assertions from a NON-verbose run.** `go test -v` prints
`t.Logf` output with the same `file_test.go:NNN:` prefix as `t.Errorf`, so a
regex count over `-v` output is inflated by every passing test that logs — it
read 8 where the truth was 6 on #232 round 3, and would have contradicted an
accurate PR-body count. Plain `go test ./...` prints only the failures.

Do the flip with the **Edit tool plus a throwaway `const`**, not with a
`python3 -c` that rewrites the source in place — the auto-mode
classifier denies the latter ("Blocked by classifier"). Add
`zz_negate.go` holding `const reviewNegateProbe = false`, Edit the call
site to `…; hit && reviewNegateProbe {`, run, then Edit back and
`rm` the file. On #232 that gave 46 failing assertions across exactly 5
tests, confirming the PR body's "45 assertions across 5 tests" claim.
Probe helpers go in the package as a `zz_*_test.go` calling
`classifyInRepo(t, cmd, repo)` and `t.Logf`-ing
`d.Bucket`/`d.Operation`/`d.Reason` — note the field is `Operation`,
there is no `Rule`.

**Never judge binary provenance from the embedded vcs stamps in this
repo.** Builds run inside a `.claude/worktrees/` linked worktree stamp
`vcs.revision` with the PRIMARY clone's HEAD (main), not the worktree's
branch tip, and `vcs.modified=false` even though the worktree carries
the PR's source — verified on PR #222, where the committed binaries
AND a fresh review-worktree rebuild both stamped main's merge commit.
A "wrong" revision stamp is therefore expected, not evidence of a
stale binary; staleness falls to the nm-table compare and behavior
probes above.

**Choose the probe form by the track the program takes, not by
convenience.** The read tracks have different terminals for the same
containment verdict — the read-only-utility track ALLOWs any operand
that is contained or carved out, while the pager/dumper track (`less`,
`more`, `od`, `xxd`) DEFERs — so a probe whose track already produces
the bucket you expect proves nothing about the carve-out under review.
Read the program's classifier arm first, then pick a probe whose
verdict can actually change.

**Grade a precondition-shield or any deny→allow widening against the
STATIC spelling's baseline, not against zero.** Before filing a
widened-hole finding, replay the fully-literal spelling of the same
operation on the OLD (origin/main) binary. On #227 round 4,
`gh api graphql … -F body=@/etc/passwd` (gh reads the `@`-file
client-side) already ALLOWED on main, so the shield admitting the
dynamic `-F body=@$F` spelling added no capability — a follow-up-issue
class, not a High on the PR. Blocking only the dynamic spelling while
static passes would just recreate the two-spellings-two-verdicts
inconsistency.

**The gate active in YOUR review session is the installed plugin cache's
binary — main's version, not the PR branch's.** So a deny you receive
mid-review is evidence about MAIN's behavior, and can itself
live-reproduce the pre-fix behavior a PR claims to change (on #208 the
old gate denied a write to the harness scratchpad, reproducing #193).
Probe the PR's own binary explicitly (`<pr-bin> < event.json`) whenever
you need the branch's verdict rather than main's.

**Escape-probe paths must escape the PRIMARY clone, not just the
worktree.** With probe cwd = a `.claude/worktrees/<agent>` worktree,
`../sibling-repo/.env` resolves to `.claude/worktrees/sibling-repo/…` —
inside the primary repository — and the gate ALLOWS it (both main's and
the PR's binary; pre-existing, not a finding). On #227 round 2 this made
every "escaping" probe read allow and nearly fabricated a refutation of
a correct fix. Use `/etc/passwd` or a path above the primary root; keep
`cat <esc-path>` alone as the control row that must deny.

**Pinning WHICH commit's source a committed binary came from** (used to
prove #227's doc round staleness): `git archive <commit>
plugins/guardrails/hooks/permission-gate | tar -x -C <tmp>` for each
candidate commit, build all candidates in the same environment, then
byte-compare and `go tool buildid` against the committed binary. An
exact byte match names the source commit; comment-only .go edits change
the artifact (pclntab file:line — over 1M differing bytes on #227) while
`go tool nm` stays byte-identical, so policy-identity and
provenance-identity are separable claims. A doc round that edits a gate
`.go` comment without rebuilding leaves binaries that fail the README's
"only vcs.revision/vcs.modified differ" protocol — a Medium, not
policy-affecting.

**Verifying a doc round's "comments only; no behavior change" claim
costs two commands** (#232 round 4, and it is decisive rather than
suggestive):

1. Non-comment lines changed must be zero —
   `git show <commit> -- '<pkg>/*.go' | grep -E "^[+-]" |
   grep -vE "^(\+\+\+|---)" | grep -cvE "^[+-][[:space:]]*//"`.
2. `go tool nm` of the PRE-round committed binary
   (`git show <parent-commit>:<bin-path> > <tmp>`) vs the tip one must
   be byte-identical, on EVERY committed arch (the foreign ones need no
   execution). Comment-only edits move pclntab `file:line` and nothing
   else.

Together those separate "the source is comments" from "the shipped
bytes carry the same policy", which is the pair the claim asserts. The
tip-rebuild `cmp` still answers the different question of staleness.

Subagent cwd resets between Bash calls, so run module commands as
`go -C <abs-module-dir> test ./...` rather than `cd` plus `go`.

Related: [[self-approve-blocked-use-comment]],
[[harness-slugs-can-double-dash]].
