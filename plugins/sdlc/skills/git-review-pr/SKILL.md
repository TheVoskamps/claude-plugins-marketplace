---
name: git-review-pr
description: Review a GitHub pull request for quality, security, and best practices.
---

# Review GitHub Pull Request

This skill is a thin wrapper around the
`sdlc:theorem-based-pr-reviewer` agent
(`agents/theorem-based-pr-reviewer.md`), which is the single
source of truth for *what* a review checks and *how* it is reported —
every section of it, deliberately not enumerated here. A list of the
review's parts written at this distance goes stale as the review
gains a stage, and reads as its complete set while it does. Do not
restate or fork that guidance here.

You do **not** run the review in this session. You spawn the
`sdlc:theorem-based-pr-reviewer` agent, which carries the whole
procedure. That agent spawns a `theorem-generator`, then
one `theorem-disprover` per live theorem in parallel, then one
`counterexample-verifier` per disproved theorem in parallel — nested
spawning the harness supports, so the fan-outs happen inside the
agent.

This path **computes** no `--generator`. The reviewer's own tier
rubric picks between `theorem-generator` (low) and
`theorem-generator-medium` (medium) from the round's delta, and it
never routes to
`theorem-generator-high` or `theorem-generator-xhigh`. A user who
wants a specific tier for a one-off review passes
`--generator <name>` to this skill and it goes through unchanged; a
user who wants the retired theorems re-checked passes `--full` the
same way. Both are human overrides, and neither is something this
skill computes.

## Process

1. **Resolve the PR number.** The first positional token in
   `$ARGUMENTS` is the PR number to review, with or without a leading
   `#`. Any `--generator <name>` and `--full` tokens alongside it are
   the human overrides above; they are not part of the PR number and
   pass through to the reviewer spawn in step 2 unchanged. If
   `$ARGUMENTS` carries no positional token, ask the user which PR to
   review before proceeding.

2. **Spawn the reviewer agent** with the `Agent` tool, using the
   `subagent_type` `sdlc:theorem-based-pr-reviewer`, and give it the
   PR number as the reviewer's own `--pr` parameter:

   ```text
   --pr <PR_N>

   Review this PR per your agent definition. Report back its
   verdicts, findings, severity counts, and theorem tally.
   ```

   Unless the user asked for an override, this path passes `--pr`
   alone — no `--issues`, no `--branch`, no `--generator`, and no
   `--full` — which is what makes it the
   reviewer's **standalone** path: with no orchestrator brief naming
   the issues, the reviewer takes its claim from
   `/github-prs:pr-closing-issues <PR>` and reconciles it against the
   branch itself. Add `--generator <name>` or `--full` to the brief
   only when the user asked for one.

   The reviewer reads `issue-link-prefix` from the repo's
   `.issues/repo-config.md` (for recognizing `References:`
   trailers), resolves the issue set, carries the previous round's
   theorem records forward out of the PR's XDG state directory,
   computes the round's delta, picks a generator tier, spawns the
   generator, the disprovers, and then the verifiers in their own
   throwaway worktrees, derives the verdicts, stores the round's
   records and its argued review under that same state directory, and
   **posts a summary of them to the PR as a single call** via
   `/github-prs:pr-review-submit`, carrying both verdict and body,
   exactly as it does in the `/sdlc:orchestrate` flow. The body
   travels as a file — the reviewer stages it under
   `.claude/tmp/<task-slug>/` and passes `--body-file`, because it
   carries a backticked state-relative path on every theorem and
   finding line, under the `${…}` state root it names once, which the
   inline form would hand to the shell. It commits nothing and pushes
   nothing.

   Remove the reviewer agent's worktree when it returns.

   **This path leaves the round's detail on disk and nothing else.** In
   the `/sdlc:orchestrate` flow, `pr-finalizer` posts the assembled
   argued reviews and theorem records to the PR once the fix loop
   concludes; a review run from here concludes no loop, so nothing posts
   them. The records, the argued review and every child's report stay under
   `${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/<owner>/<repo>/pr<PR_N>/`,
   where `sdlc-agent-result-persist --mode print-review` and
   `--mode print` reach them, and the PR carries the summary alone. That
   is accepted rather than a gap to close here: the detail is on disk in
   full for anyone who wants it, and a standalone review has no loop
   whose end would be the honest moment to post it.

3. **Read the report's closing `Return:` line before relaying
   anything.** The harness surfaces every return as `status: completed`
   with the closing message as the result, so a round that did not
   finish reads like a finished review unless you look; the line is
   what tells them apart, and on any kind but a posted review, do not
   present the partial text as a review outcome.

   - `Return: in progress: … — re-spawn to resume`: tell the user the
     round did not finish, say no review was posted, and offer to
     re-spawn the reviewer on the same PR — that re-spawn resumes the
     stalled round from its round log rather than starting it over, so
     the theorems already settled stay settled.
   - `Return: in progress: … — raise it`: tell the user the same, and
     relay the reviewer's line verbatim with no offer, since this exit
     means the reviewer judged that another pass would settle nothing
     new.
   - `Return: broken call: … — raise it`: quote the script's message
     verbatim to the user with no offer, for a different reason: no
     fan-out ran, and a re-spawn composes the same call again.

4. **Relay the reviewer's verdicts and findings** back to the user, and
   say where the round's detail is — the state path above — since the
   posted review carries the summary alone: the overall
   APPROVED / NEEDS_CHANGES / BLOCKED, plus every per-issue verdict
   (a PR may deliver a batch of several), plus the severity
   counts (Critical, High, Medium, Low) and the theorem
   tally. What that tally enumerates, and which of its counts never
   reach severity, is the reviewer agent's own "Report back" section;
   relay it as the reviewer returned it rather than restating the
   enumeration here. Relay the tier that ran and the kind of round it
   was as well — a user reading "no findings" off an empty-delta round
   is reading a carried-forward verdict, not a fresh check.
