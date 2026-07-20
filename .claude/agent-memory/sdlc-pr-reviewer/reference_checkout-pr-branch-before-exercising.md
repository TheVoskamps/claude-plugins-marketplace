---
name: checkout-pr-branch-before-exercising
description: The review worktree may start on the BASE branch, not the PR branch — checkout the PR branch before any build/test/binary exercise, or every result is base-code noise.
metadata:
  type: reference
---

The fresh review worktree can start checked out on the repo's BASE
branch (e.g. the latest `main` merge commit), NOT the PR branch under
review. If you Read source, `go build`, `go test`, or exercise a
committed binary before `git checkout <pr-branch>`, you are measuring
BASE code and will draw false conclusions.

**Symptom that caught this:** the PR's new Go tests reported
`testing: warning: no tests to run` and a `grep` for the new test
function names in the working tree returned nothing — because the
functions only exist on the PR branch, and the worktree was on base.
The committed binary also "failed" the fix behavior (allowed the very
op the PR claims to now ask) — again because base binaries lack the
fix.

**How to apply:** for any PR that ships code you intend to build/test/
run (Go/permission-gate work especially), FIRST run
`git fetch origin <branch> && git checkout <branch>`, confirm with
`git log --oneline -2` and a positive `grep` that the fix source is
present, THEN exercise. The pr-reviewer agent def treats branch
checkout as "optional (step 4)" — for compiled-artifact PRs it is
effectively mandatory, because the committed binary is itself a review
target and the tests won't even compile against base.

See [[guardrails-binary-verification]] for exercising the rebuilt
binary once you are on the right branch.
