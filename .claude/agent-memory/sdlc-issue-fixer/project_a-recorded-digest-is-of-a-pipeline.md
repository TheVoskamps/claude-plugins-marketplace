---
name: a-recorded-digest-is-of-a-pipeline
description: A hash quoted in a review or PR body is the output of somebody's shell pipeline, not of the abstract value it names — reproduce the pipeline (jq -r adds a trailing newline) before reading a mismatch as "the artifact changed"
metadata:
  type: project
---

When a review finding or PR body pins an invariant with a digest —
"`hooks.json` unchanged (sha256 `266f565e…` on the extracted command
string)" — that digest is of whatever byte stream the author's pipeline
produced, not of the logical value. Reproduce candidate pipelines and
match one before concluding anything from a mismatch.

**Why:** on PR #217 round 4 the recorded digest was
`266f565e55f99db5…`. Hashing the command string as extracted by
`json.load(...)["…"]["command"]` in Python gave
`0bbb4072b512e52a…` — a clean mismatch that reads as "the artifact
moved", which on a rebase round is a stop-everything signal. The real
difference was a single `\n`: the author had run
`jq -r '.hooks.PreToolUse[0].hooks[0].command' | shasum -a 256`, and
`jq -r` terminates its output with a newline. `jq -j` (no newline)
reproduces the Python value exactly, and hashing the whole file gives a
third digest again. All three are "the sha256 of the hook command
string" by an honest description.

**How to apply:** write a throwaway script that prints every plausible
variant (`jq -r`, `jq -j`, whole file) for a ref, and run it against
the *pre-change* ref first. Matching the recorded digest there proves
you have the author's convention; then run the same script against the
post-change ref for the real comparison. Cheaper and stronger anyway:
compare the git **blob hash** of the file across the two refs
(`git ls-tree <ref> -- <path>`), which needs no convention at all — use
the recorded digest only to confirm you and the reviewer are talking
about the same artifact. Related verification lore:
[[git-status-cannot-see-main-staleness]],
[[negative-control-the-approved-snippet]].
