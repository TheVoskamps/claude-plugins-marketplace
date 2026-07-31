---
name: guardrails-permgate-docs-locality
description: Where permission-gate classifier behavior is documented, and the two recurring stale-count defects found there (PR #114 sweep)
metadata:
  type: project
---

The `permission-gate` hook's classification behavior (Engine A command
classifier, dangerous git/gh/aws tiers, Engine B containment) lives
almost entirely in its own
`plugins/guardrails/hooks/permission-gate/README.md`. That README is
long, prose-dense, and kept current by the developer/fixer as part of
each classifier PR (e.g. #64, #113 both landed with the README's
relevant paragraph already rewritten before doc-updater ran). No other
markdown in the repo describes gate *behavior* — sibling docs
(`plugins/block-background-agents/README.md`,
`plugins/guardrails/rules/scratch-file-location.md`, top-level
`README.md`) reference the gate only by name/existence, same pattern as
[[project_github-setup-docs-locality]].

The in-code Go doc comments (`rules.go`, `gh_api_gate.go`) are also
kept meticulously current by the developer — dense, accurate,
cross-referenced to issue numbers. By the time doc-updater runs, expect
the substantive doc work to already be done; the value-add pass is
verifying accuracy (read the doc comment against the actual function
body) and a writing-style sweep, not drafting new prose.

**Two "N-before-list" defects found and fixed during the #113 sweep**
(pre-existing, not introduced by #113, but this file was already open
for editing so the sweep rule applied): "Four bypass gates fire BEFORE
per-command logic" immediately before a `(1)(2)(3)(4)` list, and "Two
refinements (#247): (1) ... (2) ..." same pattern. Both fixed by
dropping the leading count word ("Bypass gates fire...", "Refinements
(#247): (1)..."). Distinguish from the *acceptable* "the two
owner-decision deviations" phrase a few paragraphs later in the same
file — that one refers back to a pair of named, already-stated ASK
outcomes as a parenthetical aside, not introducing a fresh adjacent
list, so it stayed.

**How to apply:** on a future guardrails/permission-gate PR, don't
assume the README needs new prose — check first whether the developer
already rewrote the relevant paragraph (grep the PR diff for the
README path). Do re-grep the whole README for `\(1\)|Two |Three |Four `
style count-before-list patterns while the file is open, since this
class of defect keeps surfacing and the sweep-the-class rule applies to
the whole file once you're editing it, not just the touched paragraph.

**Lowercase count defects survive the capital-letter grep:** the
`Two |Three |Four ` grep in "How to apply" only catches
sentence-initial forms; the ones that keep surviving are mid-sentence
and lowercase, shaped like "closed allowlist of **five**
process-environment-derived variables — `$HOME`, `$USER`, …",
"EXACTLY one of **three** command substitutions — `$(git rev-parse
…)`, …", and "for the **three** tools whose remote operations
…(`git`/`gh`)…(`aws`)". Grep case-insensitively
(`grep -inE "\b(two|three|four|five) [a-z-]+"`) and fix each by
dropping the numeral. The case-insensitive grep also surfaces the
recorded exception above — "the two owner-decision deviations" is
deliberate and must stay, so re-read this entry before removing a hit
that refers back to already-stated items instead of introducing a
list.

**Counterexample (#156, PR #159):** the developer landed exhaustive Go
doc comments on `engine_a_bash.go` (resolveVar, isResolvableParamExp,
literalWord, varResolver) but did NOT touch the README, even though
#156 widened literalWord's variable-resolution semantics (adding a
closed $HOME/$USER/$TMPDIR/$PWD/$OLDPWD allowlist) in a way that made
an existing README sentence — "an undefined / environment variable...
stays inexact" — actively false. So the "usually already current"
pattern holds for git/gh/aws classifier tiers but not reliably for
literalWord/resolveVar-level semantics changes; always diff the
README's variable-resolution paragraph against the actual `literalWord`
doc comment when a PR touches that function, don't just grep for
whether the README path appears in the PR diff.

**Same counterexample class again (#132, PR #164):** the developer
added a command-substitution anchor allowlist (`resolveAnchorCmdSubst`,
`anchorCommands` — recognizes exact `$(git rev-parse --show-toplevel)`
/ `$(git rev-parse --git-common-dir)` / `$(pwd)`/`` `pwd` `` as an
assignment RHS) with dense, accurate Go doc comments on every new
function, but again did NOT touch the README. This is a sibling
mechanism to the #156 five-variable allowlist, not a variant of it — the
README needed a new paragraph distinguishing "resolves bare variable
references" (#156) from "resolves specific command-substitution forms"
(#132), inserted right after the #156 paragraph it sits beside. Confirms
the rule from the #156 entry above generalizes: any PR that adds a new
*recognized form* to Engine A's static-resolution machinery (variable
allowlist, anchor allowlist, whatever comes next) needs its own README
paragraph even when the Go comments are already complete — check by
grepping the README's variable/anchor-resolution paragraph for the new
mechanism's name, not just whether the README path is in the PR diff.
