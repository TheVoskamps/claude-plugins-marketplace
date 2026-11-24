# sdlc owners

Paths are relative to `plugins/sdlc/`. Where another file disagrees with
the owner, the owner wins and the other file is the one to fix. A fact
no row names is owned by the file its name points at.

## Orchestration

| Fact | Owner |
| --- | --- |
| How the flow is sequenced, what is branched on at each return, and the briefs spawned during the code loop | `skills/orchestrate/SKILL.md` |
| A linear procedure run at one moment of a run, and the briefs spawned at that moment | the file for that moment under `skills/orchestrate/lib/`, which the skill body names exactly once, where it applies |
| A loop over a gate, its remedies and its bounds | the loop's agent under `agents/` |
| The spawn-prompt and report-consumption principles | `skills/orchestrate/SKILL.md` |
| Which batches need a resolving install, and the plan decision item for one | `skills/orchestrate/lib/plan.md` |
| Running an approved resolving install, and what sends one to the human | `skills/orchestrate/SKILL.md` |
| What a held branch reports, and what `reclaim` refuses and releases | the `git-tools` plugin's `git-branch-sync` skill |
| The response to a held branch, and when `--holder-ended` is passed | `skills/orchestrate/SKILL.md`, and `agents/pr-merge-readiness.md` for a spawn of its own |
| How long an in-progress reviewer hand-back is waited on, and when the reviewer is re-spawned | `skills/orchestrate/SKILL.md`, and `skills/git-review-pr/SKILL.md` for a standalone review |
| The gate that reads the developer's `Scope:` block, the ruling on a finding line, and which findings reach the human | `skills/orchestrate/SKILL.md` |
| What makes two findings one class | `skills/orchestrate/SKILL.md` |
| What an agent does with a finding a ruling settled | `agents/issue-fixer.md`, and `agents/docs-writer.md` in the documentation loop |
| What a merge-readiness brief asks of the fixer | `agents/issue-fixer.md` |
| Who may reopen the review loop after a close-out | `skills/orchestrate/lib/pr-lifecycle.md` |
| Collecting deferred documentation edits and stale PR-body claims | `skills/orchestrate/lib/pr-lifecycle.md` |
| How a follow-up issue's fields are filed | `skills/orchestrate/lib/issue-lifecycle.md` |
| The re-check before a batch's In Progress flips | `skills/orchestrate/lib/issue-lifecycle.md` |
| The Left Draft table | `skills/orchestrate/lib/wrap-up.md` |

## Readiness and grooming

| Fact | Owner |
| --- | --- |
| The readiness bar, the issue-body grammar, the check keys and what a mechanical gap is | `skills/orchestrate-readiness/SKILL.md` |
| The files-affected list as a floor | `skills/orchestrate-readiness/SKILL.md` |
| The terms for a contradicted repo statement, and the search for one | `skills/orchestrate-readiness/SKILL.md` |
| What an implementing agent does with a contradicted repo statement | `agents/issue-developer.md` and `agents/issue-fixer.md` |
| How a body is split into sections and bullets, each gap line, each refusal, and the exit statuses | `bin/sdlc-readiness-check` |
| Which gaps grooming repairs with no question, and the closing approval | `skills/orchestrate-ready/SKILL.md` |

## Decisions and config

| Fact | Owner |
| --- | --- |
| The decision record's format, its refusals, the class list, the printed question, and when a problem or a design gap is pending | `bin/sdlc-decision` |
| How a skill puts a decision through a record, and the search that fills the existing-pattern slot | `skills/lib/decision-record.md` |
| Which prompts stay outside the record, and what a record is keyed on | the asking skill's `SKILL.md` |
| Every config key, its values and default, the tiers, a read's aborts, the writer procedure, and what a standing ruling does | `skills/lib/sdlc-config.md` |
| When a standing ruling is passed to a record | `skills/orchestrate/SKILL.md` |
| What the time report's Decisions table counts | `bin/sdlc-orchestrate-analysis` |

## Review rounds

| Fact | Owner |
| --- | --- |
| What a review checks, the generator tier rubric, each child's brief, which rounds are assessed, and the record each recommendation becomes | `agents/theorem-based-pr-reviewer.md` |
| A linear procedure for one moment of a round | the file for that moment under `skills/lib/theorem-based-pr-reviewer/`, which the agent file names once, at its moment |
| The argued review's sections, the finding format, and the calls that store and post it | `skills/lib/theorem-based-pr-reviewer/review-body.md` |
| The resume loop, the deadline arm and its figure, and the running `wait` | `skills/lib/theorem-based-pr-reviewer/resume.md` |
| The contract of `bin/sdlc-agent-result-persist`: its modes, paths, record grammar, derivation tables, the carry form, the `leave` checks, a child's hand-back, and how a payload is staged | `skills/agent-result-persist-interface/SKILL.md` |
| What a brief parameter, a `--mode` and a consequence class mean, and which brief the generator and the assessor each receive | `skills/theorem-agents-interface/SKILL.md` |
| The seed reviewer's spawn, the order the seed is shown in, and the ruling set | `skills/orchestrate/SKILL.md` |
| The round-0 write, and the documentation-loop briefs | `skills/orchestrate/lib/pr-lifecycle.md` |
| What grounds a theorem in each mode, and the generator's retries on a refused `leave` | `agents/theorem-generator.md` |
| What a list is assessed on, and the assessment's format | `agents/theorem-assessor.md` |
| The order a verdict is decided in | `agents/theorem-disprover.md` |

## State and posted detail

| Fact | Owner |
| --- | --- |
| The state root's repository layout, and the fixer-brief, detail-chunk and review-round markers | `bin/lib/sdlc-pr-common.sh` |
| What the PR-read CLIs take, print and exit with, which reviews are pipeline reviews, and what makes a chain complete | `skills/pr-read-cli-interface/SKILL.md` |
| Which rounds and records a detail chain holds, in what order, and how a piece is split | `bin/sdlc-pr-post-theorem-records` |
| What a detail-post report means for the final section, which body claims are checked, and how a closing-line correction is applied | `agents/pr-finalizer.md` |
| What a cleanup removes, keeps and prints | `bin/sdlc-orchestrate-cleanup` |

## Agents and hooks

| Fact | Owner |
| --- | --- |
| Which file classes an agent edits, checks or reviews | that agent's file under `agents/` |
| Which file class a path falls in | the global Claude configuration, outside this repository |
| An agent's `model:`, `effort:`, `tools:` and `isolation:` | that agent's frontmatter; `isolation: worktree` on every agent but the loop agents, which declare none, and `Glob` and `Grep` kept wherever the line lists them |
| What a compaction reloads, and the reload message's shape and row | `hooks/reload-after-compact.ts` |
| Which hook modules are registered, and in what order | `hooks/register.ts` |
