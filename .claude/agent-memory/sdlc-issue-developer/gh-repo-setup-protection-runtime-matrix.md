---
name: gh-repo-setup-protection-runtime-matrix
description: The protect skill moved from install-time-narrowed static matrices to runtime detect→matrix→aggregator workflows; aggregator empty-matrix-success is the key gotcha
metadata:
  type: project
---

`/gh-repo-setup-protection`'s CodeQL + dependency-gate workflows use a
**runtime dynamic-matrix** design (issue #145), not install-time
narrowing.

**Why:** Freezing the armed set at install time meant protection was
absent exactly when a new language/ecosystem first landed (barn-door),
and armed-but-empty legs failed closed (phantom-check hang, issues
#91/#230).

**How to apply:**
- Each of codeql.yml / dependency-install-gate.yml /
  dependency-pinned-gate.yml has three jobs: a single `detect`
  (ubuntu) emitting a JSON array to a job output; a matrix job over
  `fromJSON(needs.detect.outputs.<set>)`; and a `*-required`
  aggregator that `needs:` the matrix job, runs with `if: always()`,
  and concludes **success when the matrix was empty or every leg
  passed**. The aggregator's stable name (`codeql-required`,
  `install-gate-required`, `pinned-gate-required`) is the ruleset's
  required status check — NEVER the per-leg names.
- The single biggest regression risk: a naive aggregator without
  `if: always()` is **skipped** on an empty matrix, and a required
  check treats "skipped" as not-passed → PR hangs forever. Always
  `if: always()` + inspect `needs.<matrix>.result` for
  `failure`/`cancelled`.
- Detection is defined **once per surface**: the detect job calls the
  same gate script (`dependency-install-gate.sh --present` /
  `dependency-pinned-gate.sh --present` / `codeql-language-present.sh`)
  that also gates at runtime, so "what detect thinks is present" and
  "what the script discovers" cannot drift.
- Swift needs a macOS runner; detect adds a `swift` matrix entry
  carrying `runner: macos-latest` only when `*.swift` is present, so a
  Swift-less repo never provisions macOS.
- Dependabot gets NO detect/matrix/aggregator — it just renders the
  full supported `updates:` set; it no-ops on absent manifests. The
  one trap is class-varying placeholders (no `versioning-strategy` on
  docker/github-actions; github-actions uses singular `directory: "/"`
  + weekly).
