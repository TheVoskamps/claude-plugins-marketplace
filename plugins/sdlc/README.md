# sdlc

End-to-end issue orchestration: groom an issue until it can be
implemented without stopping to ask, plan and delegate the
implementation of one or more issues across parallel teammate agents,
review the resulting PRs through a theorem-based pipeline, and hand
the human a set of PRs to bless.

## This README points; it does not restate

Every contract in this plugin has exactly one owner, and it is never
this file. An agent's contract — what it commits, when it runs, what
it returns — is owned by that agent's own definition under `agents/`.
What a review checks and how it is reported is owned by
`skills/pr-review-pipeline/SKILL.md`. What a generator may emit is
owned by `skills/theorem-generation/SKILL.md`. How the whole flow is
sequenced, and what each teammate is briefed with, is owned by
`skills/orchestrate/SKILL.md`.

So the rosters below carry a one-line purpose and a pointer, never a
restatement. That is deliberate: `skills/orchestrate/SKILL.md` already
restates each agent's contract in several places, and the repo's
`CLAUDE.md` carries the sweep rule that keeps those restatements
honest. A README that added a further copy would add a further surface
to sweep — one that no test and no doc pass naturally opens — and it
would go stale silently. When something here and an owner file
disagree, the owner file wins and this file is the thing to fix.

What this file *does* own is the roster itself: which skills and which
agents the plugin ships. A PR that adds, removes, or renames one
updates the matching table below.

## Skills

| Skill | Purpose | Where it runs |
| ------- | --------- | --------------- |
| `/sdlc:orchestrate-ready <issue>` | Groom one issue up to the bar the orchestrator needs, then flip its status | main session, interactive |
| `/sdlc:orchestrate <issue>…` | Plan, delegate, and coordinate the end-to-end fix for one or more issues | main session |
| `/sdlc:git-review-pr <PR>` | Review one PR — a thin standalone wrapper over the review pipeline | main session |
| `sdlc:pr-review-pipeline` | The review itself: generate theorems, fan out disprovers, fan out verifiers, post one argued review | main session, invoked by the two callers above |
| `sdlc:theorem-generation` | How a generator turns a PR into disprovable theorems | preloaded into each generator agent |

The last two carry no leading slash here because they are not user
verbs: `pr-review-pipeline` is invoked by `/sdlc:orchestrate` and
`/sdlc:git-review-pr`, and `theorem-generation` is preloaded into each
`theorem-generator` variant through that agent's `skills:`
frontmatter.

Review runs **in the main session** rather than in an agent, because
it fans out parallel subagents and a subagent cannot spawn subagents.
The worked reasoning is in `docs/plugin-authoring-constraints.md` →
"Fanning out parallel agents: a main-session skill, not an agent".

### `/sdlc:orchestrate-ready <issue>`

The grooming step in front of the flow. Issues are filed at the
tracker's backlog status; this skill assesses one against the
`issue-developer`'s escalation bar — a design decision the issue does
not answer — resolves the gaps with the user in plain conversation,
rewrites the body in place as one current spec, and sets the status
the repo configures as orchestrate-ready.

It is interactive by construction, which is why it is a skill and not
an agent: the gaps it finds are questions only the user can settle,
and a subagent that cannot ask would have to answer them itself.

`/sdlc:orchestrate` does not invoke it. The user runs it first, per
issue, and runs the orchestrator once the issues are ready.

## Agents

Every agent declares `isolation: worktree`, so the harness creates a
throwaway worktree per spawn. Each one's frontmatter is the sole
source of truth for its `model` and `effort`; no value is spelled
here.

| Agent | Purpose |
| ------- | --------- |
| `issue-developer` | Implements one batch of issues on one branch and opens the PR |
| `issue-fixer` | Applies review findings to an open PR's branch |
| `doc-updater` | Updates the docs a PR's changes falsify |
| `agent-memory-scrubber` | Curates the PR's `.claude/agent-memory/` as the last agent to touch the branch |
| `theorem-generator` | Reads a PR and returns disprovable theorems |
| `theorem-generator-high`, `theorem-generator-xhigh` | The same generator at higher reasoning tiers |
| `theorem-disprover` | Tries to break exactly one theorem |
| `counterexample-verifier` | Tries to reject exactly one disprover's counterexample |

The generator definitions are skeletons over
`skills/theorem-generation/SKILL.md`, byte-identical apart from the
frontmatter lines naming the definition and its tier, so picking a
tier is picking which definition to spawn. The
repo's `CLAUDE.md` → "The generator skeletons are copies of one file"
carries the invariant and the `diff` check that enforces it.

Which agents persist memory, and which write nothing at all on the PR
branch, is stated in `skills/orchestrate/SKILL.md` and enforced by the
absence of a `memory:` key and of writing tools on the review agents.
The repo's `CLAUDE.md` → "Review writes nothing, so review lore is a
PR" says where a review lesson lands instead.

## Dependencies

`plugin.json` declares `dependencies` on `issues`, `git-tools`,
`github-prs`, and `cc-tools`. Those edges are what guarantee the
cross-plugin skills this plugin invokes are installed and enabled
wherever it runs — the issue verbs, `git-branch-create` and
`git-issues-from-branch`, the PR verbs, and `agent-memory-cleanup`.
The edge coordinates install and enablement, not file access: plugins
are file-sandboxed, so nothing here reads another plugin's files (see
`docs/plugin-authoring-constraints.md`).
