---
name: git-review-pr
description: Review a GitHub pull request for quality, security, and best practices.
---

# Review GitHub Pull Request

This skill is a thin wrapper around the `pr-reviewer` agent
(`agents/pr-reviewer.md`). That agent is the single source of truth
for *what* to review and *how* to report it — its review criteria,
focus areas, serverless checks, severity rubric, verbatim-quote
finding format, file-topology verification rules, and the
single-call review posting. Do not restate or fork that guidance
here; delegate to the agent so the two never drift.

## Process

1. **Resolve the PR number.** `$ARGUMENTS` is the PR number to review.
   If it is empty, ask the user which PR to review before proceeding.

2. **Delegate to the `pr-reviewer` agent.** Spawn it with the Agent
   tool using `subagent_type: pr-reviewer`, passing the PR number in
   the prompt. The agent runs in its own throwaway worktree, reads
   `issue-link-prefix` from the repo's `.claude/rules/repo-config.md`
   (for recognizing `References:` trailers), fetches the diff via
   `/github-prs:pr-diff`, optionally exercises the change, reviews it,
   and **posts the review to the PR as a single call** via
   `/github-prs:pr-review-submit`, carrying both verdict and body,
   exactly as it does in the `/sdlc:orchestrate` pipeline.

   This path passes a bare PR number and no issue set, which is what
   makes it the agent's **standalone** path: with no orchestrator
   brief naming the issues, the agent takes its claim from
   `/github-prs:pr-closing-issues <PR>` and reconciles it against the
   branch itself. Nothing here needs to supply one.

3. **Relay the agent's verdicts and findings** back to the user: the
   overall APPROVED / NEEDS_CHANGES / BLOCKED, plus every per-issue
   verdict it reports (a PR may deliver a batch of several), plus the
   severity counts (Critical, High, Medium, Low).
