---
name: git-review-pr
description: Review a GitHub pull request for quality, security, and best practices.
---

# Review GitHub Pull Request

This skill is a thin wrapper around the `sdlc:pr-review-pipeline`
skill (`skills/pr-review-pipeline/SKILL.md`), which is the single
source of truth for *what* a review checks and *how* it is reported:
its inputs, issue-set resolution, generator spawn, disprover fan-out,
counterexample-verifier fan-out, consequence-class-to-severity
transcription, verbatim-quote finding format, file-topology
verification rule, verdict derivation, argued body structure, and the
single-call review posting. Do not restate or fork that guidance here.

You do **not** run the pipeline in this session. You spawn the
`sdlc:theorem-based-pr-reviewer` agent, which has the pipeline skill
preloaded and runs it. That agent spawns a `theorem-generator`, then
one `theorem-disprover` per live theorem in parallel, then one
`counterexample-verifier` per disproved theorem in parallel — nested
spawning the harness supports, so the fan-outs happen inside the
agent.

This path passes **no** `--generator`. The pipeline's own tier rubric
picks between `theorem-generator` (low) and `theorem-generator-medium`
(medium) from the round's delta, and it never routes to
`theorem-generator-high` or `theorem-generator-xhigh`. A user who
wants a specific tier for a one-off review passes
`--generator <name>` to this skill and it goes through unchanged; a
user who wants every recorded theorem re-checked passes `--full` the
same way. Both are human overrides, and neither is something this
skill computes.

## Process

1. **Resolve the PR number.** `$ARGUMENTS` is the PR number to review.
   If it is empty, ask the user which PR to review before proceeding.

2. **Spawn the reviewer agent** with the `Agent` tool, using the
   `subagent_type` `sdlc:theorem-based-pr-reviewer`, and give it the
   PR number as the pipeline's own `--pr` parameter:

   ```text
   --pr <PR_N>

   Review this PR per your agent definition and the review pipeline
   skill preloaded into you. Report back its verdicts, findings,
   severity counts, and theorem tally.
   ```

   This path passes `--pr` alone — no `--issues`, no `--branch`, no
   `--generator`, and no `--full` — which is what makes it the
   pipeline's **standalone** path: with no orchestrator brief naming
   the issues, the pipeline takes its claim from
   `/github-prs:pr-closing-issues <PR>` and reconciles it against the
   branch itself. Add `--generator <name>` or `--full` to the brief
   only when the user asked for one.

   The pipeline reads `issue-link-prefix` from the repo's
   `.claude/rules/repo-config.md` (for recognizing `References:`
   trailers), resolves the issue set, carries the previous round's
   theorem records forward off the PR, computes the round's delta,
   picks a generator tier, spawns the generator, the disprovers, and
   then the verifiers in their own throwaway worktrees, derives the
   verdicts, and **posts the review to the PR as a single call** via
   `/github-prs:pr-review-submit`, carrying both verdict and body,
   exactly as it does in the `/sdlc:orchestrate` flow. It commits
   nothing and pushes nothing.

   Remove the reviewer agent's worktree when it returns.

3. **Relay the pipeline's verdicts and findings** back to the user:
   the overall APPROVED / NEEDS_CHANGES / BLOCKED, plus every
   per-issue verdict (a PR may deliver a batch of several), plus the
   severity counts (Critical, High, Medium, Low) and the theorem
   tally. What that tally enumerates, and which of its counts never
   reach severity, is the pipeline skill's own "Report back" section;
   relay it as the pipeline returned it rather than restating the
   enumeration here. Relay the tier that ran and the kind of round it
   was as well — a user reading "no findings" off an empty-delta round
   is reading a carried-forward verdict, not a fresh check.
