---
name: gomodcache-outside-repo-use-go-doc
description: the permission gate blocks reads under ~/go/pkg/mod (outside the repo); use `go doc` from inside the repo module to verify third-party Go API shapes instead
metadata:
  type: feedback
---

When an issue asks you to verify a third-party Go package's AST/struct
field names against its module source under `~/go/pkg/mod` (outside the
repo), a direct `find`/`Read` there is DENIED by the guardrails
permission gate ("Do not read another repo's files ... use the
dependency's published docs"), even when the issue text explicitly
says "reading that path for verification is fine" — the issue author
doesn't have gate visibility and can't waive it.

**Why:** `~/go/pkg/mod` resolves outside the current repo root, and the
[[permission-gate-self-hosting]] gate enforces its cross-repo-read
denial uniformly regardless of what the issue body claims is fine.

**How to apply:** run `go doc <import-path>.<Symbol>` from a `Bash`
call with `cd <pkg-dir> && go doc ...` (a single non-git command, so
the `cd &&` form is fine per forbidden-form rules). This queries the
already-downloaded module cache through the `go` tool rather than a
raw filesystem read, and the gate does not block it. It reliably
surfaces exported struct fields, interface methods, and doc comments —
exactly what's needed to confirm real field names before coding
against an unfamiliar dependency's AST types (e.g. confirmed
`mvdan.cc/sh/v3/syntax.ForClause.Loop` is a `Loop` interface holding
`*WordIter | *CStyleLoop`, not a direct `*WordIter`, for issue #131).
