# CLAUDE.md

## Bump the plugin version when you change a plugin

A PR that modifies any file under `plugins/<name>/` MUST also bump that
plugin's `version` in `plugins/<name>/.claude-plugin/plugin.json`, in
the same PR. The bump is a separate, deliberate edit.

After rebasing such a branch, re-read each touched plugin's `version`
against the default branch and bump again if they now match. When both
sides applied the same bump, git resolves it silently — no conflict, no
marker — and the file simply drops out of the branch's diff. The only
signal is a diff line you have to notice is missing.

## Add a README roster entry when you publish a plugin

A PR that adds an entry to `.claude-plugin/marketplace.json` also adds a
matching bullet to the top-level `README.md` "Published plugins" list,
worded like its neighbours. Writing `plugins/<name>/README.md` does not
cover this.

## Never invoke a GitHub publishing verb to establish behavior

`gh gist create|edit`, `release create|upload`, `pr create`,
`issue create`, `pr comment` and `issue comment` are never run to find
out how something behaves — not with `--help`, not with an invalid flag
value, not "because it will obviously error first". Every abort story of
the shape "the operand is absent" is exactly the one that fails:
`gh gist create -pd <path>` looks like it must abort, but `-d` eats the
operand, `gist create` falls back to stdin, and it POSTs. The permission
gate escalates a publishing verb to a human click rather than denying
it, so the gate is not the backstop for this — the rule is.

Publishing a PR or a comment the task actually asks for is ordinary
work. The prohibition is on *establishing behavior*, and the questions
that tempt you into one have safe answers: a gate verdict is settled by
replaying a synthetic `PreToolUse` event against the built
`permission-gate` binary, and a vendor parse fact by reading `cli/cli`'s
source at the tag `gh` is pinned to —
`gh api "repos/cli/cli/contents/<path>?ref=<tag>" --jq .content` piped
through `base64 -d`, a non-mutating GET whose registration block beats
`--help`. When a claim looks like it can only be settled by a real
publish, stop and report that.

One named exception: a PR whose deliverable **is** the publish path may
run one `gh pr comment --body-file` against a scratch PR, carrying a
body its author wrote, as its acceptance test. Nothing is being learned
about the verb's parsing there — the flags, target and content are all
chosen in advance, and what the run establishes is that a body that size
survives the trip. One publish, scratch PR, no second run "to be sure".

## Never test the package's own prose

A test suite asserts what code does. Never write a test that parses or
greps the package's own source for prose shapes — issue references in
comments, comment wording, TODO formats — and when told to remove one,
do not replace it with a differently shaped mechanism: no build tag, no
generator, no linter config added in the same PR, no equivalent check
relocated elsewhere.

Documentation standards change independently of behavior, so a style
rule living in the suite fails the build over prose; and a pattern match
encodes the narrow syntactic case as the definition of the class, making
the tree look clean when the wrap-split instances are still there. A
check over text the program **emits** is behavior and stays.

Removing such a mechanism sweeps every claim it spawned in the same
round — README sections, comments, the PR body — including any "every X
is gone" or "fails the build if reintroduced". Keep the convention and
its rationale; drop the enforcement story.

## MD041 on a SKILL.md is convention, not debt

`npx markdownlint-cli2` reports `MD041/first-line-heading/first-line-h1`
on a `plugins/*/skills/**/SKILL.md` whose body opens with an instruction
rather than an H1. Both openings are in use, within a plugin as well as
between, so run the linter rather than predicting a hit from the
convention. Leave one alone: a SKILL.md body is a prompt, and an H1
changes the payload the model receives. When you edit one, re-lint the
base and compare counts to confirm you introduced no **new** error
class, and say so in the PR body.

`lib/*.md` under a plugin's `skills/` are ordinary documents, carry an
H1, and lint clean.

## Grade a repo statement an issue contradicts, don't pick a side

An issue can specify something a repo document already forbids. Never
ship one half silently: implement the issue **and** settle the
contradicted statement in the same PR. The issue's version alone leaves
the repo asserting the opposite in a file a future agent reads as
policy; the repo's version alone leaves an acceptance criterion unmet
with no explanation.

Which repair is right turns on the kind of claim, and the two take
opposite repairs. A **capability** claim — what the harness can or
cannot do — is verifiable, so a false one is deleted; carving an
exception out of it preserves a false claim as the general rule. A
**policy** claim — a choice this repo made where the harness permits
both — is not falsifiable, so an issue may carve a named exception out
of it with the reason stated inline. Prescriptive wording ("may only",
"never") does not settle the grade; that is exactly how a false
capability claim reads.

Sweep every restatement rather than the one the issue names, and say in
the PR body which grade you gave, so the reviewer grades that judgment
rather than re-finding the contradiction. This is not an escalation.

## An issue's "Known gaps" section is a doc requirement

When an issue body states what the change deliberately does *not* do,
treat it as an unmet doc requirement until the PR proves otherwise. The
gaps read as nothing to write down, and they are exactly what a future
agent cannot recover from the code — the absence of a check looks like
an oversight to fix rather than a decision to respect. Grep the README
for each gap's mechanism name before concluding it is covered, and check
whether nearby prose now reads as a completeness claim it cannot
support.

## The PR description is a doc surface

A PR body goes stale for the same reasons a README does, and nothing
tests it, so a hand-listed count or an unjustified "the list is closed
because …" survives there longest. Read it with
`gh pr view <N> --json body -q .body`, edit a scratch copy, and pass it
back with `--body-file`. Two constraints bound that work and only two:
the closing keyword survives byte for byte — never add, remove or
retarget one — and nothing else on the PR is in scope.

## The rebase automation can move a PR branch mid-session

A scheduled sweep force-rebases open PR branches onto the default
branch, and it can fire while you are working on one. The symptom is a
checkout reporting diverged histories right after a fetch, with the same
logical commits under different hashes on a newer merge. Rebuild your
work onto the new tip rather than resetting — a worktree must never
reset away commits it has not pushed. The sweep skips conflicted
states, so a conflicted PR never self-heals and is yours to rebase.

## Read on demand

These files carry what does not apply on every turn. Read the matching
one **before** asserting behavior you have not run, or before editing
the tree it governs — not afterwards. Each entry names its trigger and
its hardest rule. Playbooks record technique, not policy: when a
playbook step and a rule above disagree, the rule wins and the playbook
is the thing to fix.

- [`docs/verification-playbook.md`](docs/verification-playbook.md) —
  read before claiming a change was verified, in any domain. Kernel: a
  measurement without a baseline and a negative control establishes
  nothing.
- [`docs/guardrails-verification-playbook.md`](docs/guardrails-verification-playbook.md)
  — read before asserting what the permission gate does. Kernel: the
  gate ships policy inside a committed binary, so settle a verdict by
  replaying a synthetic event against that binary, never by reading the
  Go source.
- [`docs/claude-vm-verification-playbook.md`](docs/claude-vm-verification-playbook.md)
  — read before asserting what a claude-vm launch, image build or guest
  does. Kernel: probe the real hypervisor, kernel and launcher; a green
  fixture-driven suite has measured the fixture.
- [`docs/prose-claim-shapes.md`](docs/prose-claim-shapes.md) — read
  before grading prose, and add to it when a round turns up a new shape.
  Kernel: it collects sentences that go false while every test stays
  green; a sentence that was simply wrong when written is not one.
- [`docs/agent-tooling-notes.md`](docs/agent-tooling-notes.md) — read
  when a command here succeeds but the result surprises you. Kernel: the
  Bash tool's shell is zsh, `gh`'s GraphQL verbs can fail while REST is
  healthy, and a worktree-isolated agent reads the worktree, never the
  primary clone's path.
- [`docs/hook-event-notes.md`](docs/hook-event-notes.md) — read before
  writing or changing a hook, or asserting how the harness treats one.
  Kernel: a PreToolUse hook abstains by omitting `permissionDecision`;
  emitting the literal `"defer"` ends a headless subagent's run.
- [`docs/plugin-authoring-constraints.md`](docs/plugin-authoring-constraints.md)
  — read before adding a plugin, or a file one plugin expects another to
  reach. Kernel: plugins are file-sandboxed, so a cross-plugin `Read`
  does not resolve; skill invocation is what crosses instead.
- [`docs/plugin-sdlc.md`](docs/plugin-sdlc.md) — read before editing
  anything under `plugins/sdlc/`. Kernel: every fact has one owner, so a
  contract change repairs pointers rather than being restated, and
  review writes nothing on the branch it reviews.
- [`docs/plugin-claude-vm.md`](docs/plugin-claude-vm.md) — read before
  editing anything under `plugins/claude-vm/`. Kernel: write for bash
  3.2, never split a TSV record with a tab-IFS `read`, and ask the raw
  config file — never the merged one — whether the operator wrote a key.
- [`docs/plugin-guardrails.md`](docs/plugin-guardrails.md) — read before
  changing how the permission gate is packaged or what verdict it
  returns. Kernel: a packaging-shape change sweeps `plugins/claude-vm/`
  and bumps both plugins; a rebuild in place sweeps nothing.
- [`docs/plugin-issues.md`](docs/plugin-issues.md) — read before moving,
  renaming or newly consuming an issues config path. Kernel: every
  consumer spells the path itself, so a move edits every plugin that
  spells it.
- [`plugins/github-setup/README.md`](plugins/github-setup/README.md) →
  "Sweep every App-permission surface when the starter set changes" —
  read before editing any `plugins/github-setup/` file that names a
  permission scope. Kernel: the starter set is restated as a literal
  list in several files and rendered in one, and widening it has a
  converge-time consequence.
