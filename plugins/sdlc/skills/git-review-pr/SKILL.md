---
name: git-review-pr
description: Review a GitHub pull request for quality, security, and best practices.
---

# Review GitHub Pull Request

This skill is a thin wrapper around the `pr-reviewer` agent
(`agents/pr-reviewer.md`), which is a skeleton over the
`sdlc:pr-review-protocol` skill (`skills/pr-review-protocol/SKILL.md`).
That protocol is the single source of truth for *what* to review and
*how* to report it — its inputs, review criteria, focus areas,
serverless checks, severity rubric, verbatim-quote finding format,
file-topology verification rules, and the single-call review posting.
Do not restate or fork that guidance here; delegate to the agent, which
gets the protocol preloaded, so the two never drift.

This path always spawns the base `pr-reviewer` (medium effort). The
higher tiers — `pr-reviewer-high` and `pr-reviewer-xhigh` — are picked
by `/sdlc:orchestrate` from signals it has and this skill does not (see
that skill → "Picking a reviewer tier"). A user who wants a higher tier
for a one-off review spawns the variant directly.

## Process

1. **Resolve the PR number.** `$ARGUMENTS` is the PR number to review.
   If it is empty, ask the user which PR to review before proceeding.

2. **Delegate to the `pr-reviewer` agent.** Spawn it with the Agent
   tool using `subagent_type: pr-reviewer`, passing the PR number in
   the prompt as the protocol's own `--pr` parameter:

   ```text
   --pr <PR_N>

   Review per the preloaded PR review protocol and post a single
   review with a verdict per issue plus an overall verdict. Report
   back every verdict line you posted and the overall APPROVED,
   NEEDS_CHANGES, or BLOCKED with severity counts.
   ```

   The agent runs in its own throwaway worktree, reads
   `issue-link-prefix` from the repo's `.claude/rules/repo-config.md`
   (for recognizing `References:` trailers), fetches the diff via
   `/github-prs:pr-diff`, optionally exercises the change, reviews it,
   and **posts the review to the PR as a single call** via
   `/github-prs:pr-review-submit`, carrying both verdict and body,
   exactly as it does in the `/sdlc:orchestrate` pipeline.

   This path passes `--pr` alone — no `--issues` and no `--branch` —
   which is what makes it the protocol's **standalone** path: with no
   orchestrator brief naming the issues, the agent takes its claim
   from `/github-prs:pr-closing-issues <PR>` and reconciles it against
   the branch itself. Nothing here needs to supply one.

3. **Relay the agent's verdicts and findings** back to the user: the
   overall APPROVED / NEEDS_CHANGES / BLOCKED, plus every per-issue
   verdict it reports (a PR may deliver a batch of several), plus the
   severity counts (Critical, High, Medium, Low).
