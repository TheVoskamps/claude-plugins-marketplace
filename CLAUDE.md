# CLAUDE.md

## Bump the plugin version when you change a plugin

A PR that modifies any file under `plugins/<name>/` MUST also bump that
plugin's `version` in `plugins/<name>/.claude-plugin/plugin.json`, in
the same PR, as a separate, deliberate edit — a post-review README edit
included; an agent barred from `plugin.json` reports the bump as owed.

A PR that bumps a version adds that version's entry to
`plugins/<name>/CHANGELOG.md`: a `## <version> — <date>` heading, newest
first, over prose or bullets that tell a plugin user what changed
without following a link, so no PR links or numbers. A PR that adds,
delists or retires a plugin also adds a dated bullet to the root
`CHANGELOG.md`.

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
body its author wrote, as its acceptance test. That run learns nothing
about the verb's parsing — flags, target and content are chosen in
advance; it shows only that a body that size survives the trip. One
publish, scratch PR, no second run "to be sure".

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

Removing such a mechanism sweeps every claim it spawned, including any
"every X is gone" or "fails the build if reintroduced". The implementer
sweeps comments and other code in the same round. Under an orchestrated
run, README sections are written after the review loop, and a stale
PR-body claim stays in the body: the orchestrator collects it, and
`pr-finalizer`'s final section corrects it. On a PR no orchestrator
runs, whoever changes the mechanism corrects the body claim. Keep the
convention and its rationale; drop the enforcement story.

## The PR description is a doc surface

A PR body goes stale like a README, nothing tests it, and a hand-listed count
or an unjustified "the list is closed because …" survives there longest. Read
it with `/github-prs:pr-view <N> --json body --jq .body`, edit a scratch copy,
pass it back with `/github-prs:pr-update <N> --body-file <path>`. Three bounds,
and only three: the closing keyword survives byte for byte, nothing else on the
PR is in scope, and no edit lands during a `/sdlc:orchestrate` loop — there the
body is frozen, and `pr-finalizer` amends it at the end.

## The rebase automation can move a PR branch mid-session

A scheduled sweep force-rebases open PR branches onto the default
branch, even while you work on one. The symptom: a checkout reports
diverged histories right after a fetch, the same logical commits under
different hashes on a newer merge. Rebuild your work onto the new tip
rather than resetting — a worktree must never reset away commits it has
not pushed. The sweep skips conflicted states, so a conflicted PR never
self-heals and is yours to rebase.

## Read on demand

These files carry what does not apply on every turn. Read the matching
one **before** asserting behavior you have not run, or before editing
the tree it governs. Each entry names its trigger and hardest rule.
Playbooks record technique, not policy: when a playbook step and a rule
above disagree, the rule wins and the playbook is the thing to fix.

- [`docs/rules/verification-playbook.md`](docs/rules/verification-playbook.md) —
  read before claiming a change was verified, in any domain. Kernel: a
  measurement without a baseline and a negative control establishes
  nothing.
- [`docs/rules/agent-tooling-notes.md`](docs/rules/agent-tooling-notes.md) — read
  when a command here succeeds but the result surprises you. Kernel: the
  Bash tool's shell is zsh, `gh`'s GraphQL verbs can fail while REST is
  healthy, and a worktree-isolated agent reads the worktree, never the
  primary clone's path.
- [`docs/rules/hook-event-notes.md`](docs/rules/hook-event-notes.md) — read before
  writing or changing a hook, or asserting how the harness treats one.
  Kernel: a PreToolUse hook abstains by omitting `permissionDecision`;
  emitting the literal `"defer"` ends a headless subagent's run.
- [`docs/rules/config-file-conventions.md`](docs/rules/config-file-conventions.md)
  — read before a plugin reads or writes a config or state file of its
  own. Kernel: a plugin's own config is YAML or Markdown, never JSON,
  unless the file names it as an exception.
- [`docs/rules/plugin-authoring-constraints.md`](docs/rules/plugin-authoring-constraints.md)
  — read before adding a plugin, or a file one plugin expects another to
  reach. Kernel: plugins are file-sandboxed, so a cross-plugin `Read`
  does not resolve; skill invocation is what crosses instead.
