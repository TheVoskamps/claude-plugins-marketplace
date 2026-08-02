---
name: no-source-lint-meta-tests
description: never add a test that lints the package's own source prose/comments/style, and don't substitute a build tag / go:generate / linter config for one; when such a check is removed, delete the README, comment and PR-body prose that claimed it enforced anything
metadata:
  type: feedback
---

A test suite asserts that code does what it should do. It is not the
place to enforce a documentation or style standard. Never write a test
that parses/greps the package's own source for prose shapes (issue
references in comments, TODO formats, comment wording), and when told
to remove one, do not replace it with a differently shaped check — no
build tag, no `go:generate`, no linter config added to the same PR, no
equivalent test relocated elsewhere. Just remove it.

**Why:** on PR #208 (issue #193) I added `TestNoIssueRefsInComments`,
which walked every `.go` file with `go/parser` and failed the suite on
`#\d+` in any comment. Edwin approved it, then reversed: *"I approved
it in error"*, and had issue #193's sweep section rewritten to state
the rule — documentation standards change independently of behavior, so
a style rule living in `go test` fails the suite over prose, and a
pattern-matching check encodes the narrow syntactic case as the
definition of the class, making the tree look clean when it is not
(exactly what happened: the pattern missed every wrap-split reference).

**The legitimate sibling, so the line is clear:** a check over text the
program *emits* is behavior, not documentation, and stays.
`trackerRefInReason` / `TestRemediationReasonsAreActionable_58` grades
the deny/ask `Reason` strings the permission-gate returns to an agent —
program output, part of the gate's contract. The test I removed graded
comments, which are not behavior. Ask which side of that line a
proposed assertion sits on before writing it.

**How to apply:** when an issue or review finding asks you to enforce a
documentation convention, state the convention in the doc surface and
let review carry it; say so explicitly rather than reaching for a
mechanism. When you remove such a mechanism, sweep every claim it
spawned in the same round — README sections, Go comments, and the PR
body — including its *exemptions* ("labels and test failure messages
are outside the rule") and any "every X is gone" / "fails the build if
reintroduced" completeness claim. Those are false the moment the check
is gone, and a stale claim is worse than none. Keep the convention and
its rationale; drop the enforcement story. Related:
[[pr-body-is-a-swept-surface]], [[audit-a-prose-sweep-by-added-words]].
