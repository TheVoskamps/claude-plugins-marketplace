---
name: baseline-rebuild-before-editing-a-go-comment
description: before touching a guardrails .go comment, rebuild all three arches from the UNMODIFIED source and cmp against the committed binaries — that baseline is what makes the post-edit byte differences attributable to your edit instead of to your toolchain
metadata:
  type: project
---

`plugins/guardrails` ships committed binaries, so any `.go` edit —
comments included — obliges a rebuild of `darwin-arm64`, `linux-amd64`
and `linux-arm64` with the README's recipe, because Go embeds
`file:line` in the pclntab. The trap is that a rebuild also absorbs any
difference between YOUR toolchain and the previous builder's, and you
cannot tell the two apart afterwards.

**Do the baseline first, before the edit:**

1. `go version` and `go version -m <committed-bin>` must agree on the
   Go release (go1.26.5 on PR #232).
2. Rebuild all three arches from the unmodified tip into
   `.claude/tmp/<slug>/base/` and `cmp` against the committed
   binaries. Identical on all three means your environment reproduces
   the builder's exactly.
3. Make the comment edit, rebuild in place, then `go tool nm` the
   baseline copy against the new one. Comment-only edits leave the
   symbol table **byte-identical** — that is a stronger and simpler
   claim than the `r`-symbols-shifted-by-a-constant narrative round 5
   of #232 had to adjudicate, and it costs one `cmp` because the
   baseline is already on disk.
4. Prove the non-comment count is zero as well:
   `git diff -- '<pkg>/*.go' | grep -E "^[+-]" | grep -vE "^(\+\+\+|---)" | grep -cvE "^[+-][[:space:]]*//"`
   (`grep -c` exits 1 on a zero count — that non-zero exit is the pass).

Then replay the behavior rows against the rebuilt binary from a scratch
repo anyway; nm identity is about compiled code, the probe is about the
verdicts. Related: [[real-build-verification-not-unit-tests]],
[[buildvcs-stamp-is-primary-clone-head]].
