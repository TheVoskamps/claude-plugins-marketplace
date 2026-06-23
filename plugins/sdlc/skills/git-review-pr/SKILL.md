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
   the prompt. The agent runs in its own throwaway worktree, reads the
   repo's `.claude/rules/repo-config.md` for source-control / issue /
   branch conventions, fetches the diff, optionally exercises the
   change, reviews it, and **posts the review to the PR as a single
   call** carrying both verdict and body, exactly as it does in the
   `/issue-address` pipeline.

3. **Relay the agent's verdict and findings** back to the user:
   APPROVED / NEEDS_CHANGES / BLOCKED, plus the severity counts
   (Critical, High, Medium, Low).
