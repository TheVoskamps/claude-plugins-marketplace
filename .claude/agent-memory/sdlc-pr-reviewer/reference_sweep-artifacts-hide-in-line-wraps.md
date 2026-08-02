---
name: sweep-artifacts-hide-in-line-wraps
description: On a mechanical comment/token-removal sweep, read JOINED comment blocks against the old text — the broken ones are where the removed token was the head of a noun phrase straddling a line wrap, which no line-based grep and no compiler will surface.
metadata:
  type: reference
---

A "remove every `#N` from the comments" style sweep (515 lines / 24
files on PR #208) leaves a residue that `gofmt`, `go vet`, the test
suite and the sweep's own guard regex all pass over: the substitution
was correct *on its line*, but the removed token was the grammatical
head of a phrase that continued onto the next comment line.

**How to find them cheaply.** Diff old vs. new per file and grep the
OLD side for a ref sitting at end-of-line — that is the signature:

```bash
git show origin/main:<file> | grep -nE '//.*#[0-9]+[^ )]*$'
```

Then read each hit's next line in both versions. On PR #208 this
surfaced ~18 candidates across the package, of which three were
genuinely broken and still live after the author's own repair pass:

- `// …the former isGitConfigPath check, which` / `// rule to the whole
  .git/ tree)` — was `isGitConfigPath #125-config` / `rule …`; the new
  parenthetical has no verb.
- `// …bundled-skills tree,` / `// prefix) is neither…` — the `#193)`
  that closed the parenthesis became a duplicated `prefix)`.
- `// …the example command substitution here before it` / `//
  allowlisted it as…` — was `before #132`; "it allowlisted it" now has
  no antecedent.

**Grading.** These are comment-only, so the repo's own severity rule
caps them at **Low** unless the broken comment masks an unmet
acceptance criterion. Report all instances as ONE finding of the class
(with a verbatim quote and the `origin/main` original for each), not
one finding apiece — three Lows read as noise; one class-level Low with
three sites reads as the sweep being finishable.

Related: [[re-review-the-whole-diff-fresh]] — this class is invisible to
a delta-only read for the same reason, and to
[[verify-doc-cross-reference-headings]] for the sibling
"pointer survived the thing it pointed at" class.
