---
name: git-review-pr
description: Review a GitHub pull request for quality, security, and best practices.
---

# Review GitHub Pull Request

This skill is a thin wrapper around the `sdlc:pr-review-pipeline`
skill (`skills/pr-review-pipeline/SKILL.md`), which is the single
source of truth for *what* a review checks and *how* it is reported:
its inputs, issue-set resolution, generator spawn, disprover fan-out,
severity rubric, verbatim-quote finding format, file-topology
verification rule, verdict derivation, and the single-call review
posting. Do not restate or fork that guidance here.

You run the pipeline **in this session**, not inside a subagent. The
pipeline spawns a `theorem-generator` and then one `theorem-disprover`
per theorem in parallel, and a subagent cannot spawn subagents — so a
delegated pipeline would collapse to a single reader, which is the
shape this replaced.

This path always spawns the base `theorem-generator` (medium effort).
The higher tiers — `theorem-generator-high` and
`theorem-generator-xhigh` — are picked by `/sdlc:orchestrate` from
signals it has and this skill does not (see that skill → "Picking a
generator tier"). A user who wants a higher tier for a one-off review
passes `--generator theorem-generator-high` (or `-xhigh`) to the
pipeline themselves.

## Process

1. **Resolve the PR number.** `$ARGUMENTS` is the PR number to review.
   If it is empty, ask the user which PR to review before proceeding.

2. **Run the pipeline** with the PR number as its own `--pr`
   parameter:

   ```text
   /sdlc:pr-review-pipeline --pr <PR_N>
   ```

   This path passes `--pr` alone — no `--issues`, no `--branch`, and
   no `--generator` — which is what makes it the pipeline's
   **standalone** path: with no orchestrator brief naming the issues,
   the pipeline takes its claim from `/github-prs:pr-closing-issues
   <PR>` and reconciles it against the branch itself, and the
   generator tier falls back to the default. Nothing here needs to
   supply any of them.

   The pipeline reads `issue-link-prefix` from the repo's
   `.claude/rules/repo-config.md` (for recognizing `References:`
   trailers), resolves the issue set, spawns the generator and the
   disprovers in their own throwaway worktrees, derives the verdicts,
   and **posts the review to the PR as a single call** via
   `/github-prs:pr-review-submit`, carrying both verdict and body,
   exactly as it does in the `/sdlc:orchestrate` pipeline. It commits
   nothing and pushes nothing.

3. **Relay the pipeline's verdicts and findings** back to the user:
   the overall APPROVED / NEEDS_CHANGES / BLOCKED, plus every
   per-issue verdict (a PR may deliver a batch of several), plus the
   severity counts (Critical, High, Medium, Low) and the theorem tally
   — generated, disproved, survived, unsettled.
