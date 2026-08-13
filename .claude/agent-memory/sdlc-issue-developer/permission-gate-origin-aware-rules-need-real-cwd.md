---
name: permission-gate-origin-aware-rules-need-real-cwd
description: permission-gate rules that compare against the session repo's git origin (foreign-target scoping) only fire when the event cwd is a REAL git repo with an origin remote; the /tmp default in classifyCmd fails them open.
metadata:
  type: project
---

Some permission-gate verdicts depend on the session repo's `git origin`
(the #163 foreign-target write scoping: a `gh` write whose `-R`/`--repo`
target differs from origin DEFERS — it ASKed before #262). These call
`runGit(ev.CWD, "remote",
"get-url", "origin")` at classify time.

**Why it matters for tests and probes:** the standard `classifyCmd` test
helper sets `CWD: "/tmp"`, which is not a repo, so `sessionOriginRepo`
returns "" and the scoping **fails OPEN** (the write ALLOWs, rather than
reaching the foreign-target verdict).
To exercise an origin-aware verdict you must build a real temp repo with
an `origin` remote and pass its dir as the event cwd — see
`setupRepoWithOrigin` / `classifyInRepo` in `foreign_target_test.go`.

**How to apply:** when adding or testing any gate rule that reads live
git state (origin, local user.email, rev-parse), give the event a real
repo cwd. `t.TempDir()` + `gitInit` + `git remote add origin …`. The
same pattern already existed for `isAppManagedRepo` (see
`setupRepoWithEmail` in `naked_gh_test.go`). Fail-open-on-git-failure is
deliberate for these refinement rules (a git hiccup must not block normal
use), so a missing-cwd test will silently pass the ALLOW branch and prove
nothing about the escalating branch.

Related: [[permission-gate-self-hosting]] (verify by piping synthetic
PreToolUse event JSON into the rebuilt binary — for origin-aware rules
the JSON's `cwd` must point at a real repo, not `/tmp`).
