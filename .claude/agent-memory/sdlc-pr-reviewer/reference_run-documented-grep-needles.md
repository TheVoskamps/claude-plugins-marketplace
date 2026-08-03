---
name: run-documented-grep-needles
description: When a PR writes a grep-needle recipe into docs (CLAUDE.md sweep sections), run each needle at the tip before trusting it — a multi-token needle can already miss a consumer because the phrase wraps mid-line
metadata:
  type: reference
---

A doc that prescribes grep needles ("grep `X` and `Y`, check every
hit") is making a testable claim: each needle actually hits every site
it exists to find. Run each needle at the branch tip during review —
one grep per needle — before accepting the recipe.

**Why:** on PR #224 round 3, CLAUDE.md's new "Sweep the branch-name
grammar" paragraph told sweepers to grep `` `B` empty ``. At the very
tip that added the advice, `pr-reviewer.md`'s own arm wrapped as
"leaves `B`\n empty." — the needle hit pr-create and pr-link-issue but
missed the third consumer. The same paragraph had even picked
`all-numeric` for being "a short, wrap-proof needle", so the class was
known to the author; the multi-token sibling needle just never got
run. It stayed Low only because the paragraph's other needle (`∩`)
hits pr-reviewer's step 2 three lines above the arm.

**How to apply:** for each documented needle, run it exactly as
written and compare the hit list against the sites the doc claims (or
implies) it covers. A miss on a multi-token needle is usually a line
wrap — confirm with a single-token or wrap-proof respelling
(`convention` vs `` `B` empty ``) and recommend that respelling or a
reflow. Sibling shape: [[reference_sweep-artifacts-hide-in-line-wraps]]
(wraps hide old-side refs from sweeps; here they hide sites from the
documented sweep recipe itself).
