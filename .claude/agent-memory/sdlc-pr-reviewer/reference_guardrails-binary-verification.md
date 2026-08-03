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

**Do NOT verify by rebuilding and `cmp`-ing against the committed
binary.** Go embeds build paths / build IDs, so a fresh
`GOOS=... GOARCH=... go build` almost never reproduces byte-identically
without a reproducible-build harness. A `differ` result is expected and
proves nothing.

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
the scratch git repo under `<repo-root>/.claude/tmp/<slug>/`, `cd` into
it in one Bash call, then run `git init -q .` as a separate bare call.

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

**The gate active in YOUR review session is the installed plugin cache's
binary — main's version, not the PR branch's.** So a deny you receive
mid-review is evidence about MAIN's behavior, and can itself
live-reproduce the pre-fix behavior a PR claims to change (on #208 the
old gate denied a write to the harness scratchpad, reproducing #193).
Probe the PR's own binary explicitly (`<pr-bin> < event.json`) whenever
you need the branch's verdict rather than main's.

Subagent cwd resets between Bash calls, so run module commands as
`go -C <abs-module-dir> test ./...` rather than `cd` plus `go`.

Related: [[self-approve-blocked-use-comment]],
[[harness-slugs-can-double-dash]].
