# CLAUDE.md

## Bump the plugin version when you change a plugin

When a PR modifies any file under `plugins/<name>/`, it MUST also bump
that plugin's `version` in `plugins/<name>/.claude-plugin/plugin.json`,
in the same PR. The version bump is a separate, deliberate edit. A
plugin change without a version bump is incomplete.

## MD041 on a SKILL.md is convention, not debt

`npx markdownlint-cli2` reports
`MD041/first-line-heading/first-line-h1` on essentially every
`plugins/*/skills/**/SKILL.md`, always at the first prose line after
the YAML frontmatter. Leave it alone. A `SKILL.md` body is a *prompt*
the model reads, not a document, so it opens with an instruction ("You
are running the `/foo` skill…") rather than an H1, and MD041 is the
only error class those files produce — a rule that fires uniformly and
alone, in a tree whose Markdown is otherwise spotless, is a tolerated
convention.

The global "Leave Markdown clean" rule would otherwise push you into
adding an H1 to a skill file, which changes the prompt payload the
model receives and, swept per "sweep the class", churns every skill
file in every plugin. Don't. When you edit a `SKILL.md`, verify you
introduced **no new** error classes — re-lint the base and compare
counts, rather than reading the raw total as debt you inherited — and
say in the PR body that the remaining MD041 hits are pre-existing and
why. Changing the convention is a repo-wide decision, not a doc-pass
sweep — the same carve-out shape as the `Phase 1` / `Phase 2` headings
below.

`lib/*.md` files under a plugin's `skills/` are ordinary documents and
DO carry an H1. They lint clean, and a new one you write must too.

## Never invoke a GitHub publishing verb

A `gh` verb that publishes — `gist create`, `gist edit`, `release
create`, `release upload`, `pr create`, `issue create`, `pr comment`,
`issue comment` — is never run to establish behavior, in any spelling,
for any reason. Not with `--help`, not with an invalid flag value, not
with a nonexistent path, not "because it will obviously error first".
Every abort story of the shape "the operand is absent" or "stdin is
empty" is exactly the story that fails: `gh gist create -pd <path>`
looks like it must abort on a missing `-d` value, but `-d` eats the
operand, `gist create` then falls back to stdin, and it POSTs. The
permission gate escalates a publishing verb to a human click rather
than denying it, so the gate is not the backstop for this — the rule
is. The prohibition is on establishing behavior; publishing a PR or a
comment the task actually asks for is ordinary work.

The two questions that tempt an agent into one both have a safe answer:

- **A gate verdict** is settled by replaying a synthetic `PreToolUse`
  event against the built `permission-gate` binary. No verdict
  question is answered better by a real invocation.
- **A vendor parse fact** — which flags a verb takes, what its
  positionals mean, whether it defaults to stdin — is settled by
  reading `cli/cli`'s own source at the tag `gh` is pinned to:
  `gh api "repos/cli/cli/contents/<path>?ref=<tag>" --jq .content`
  piped through `base64 -d`. That is a non-mutating GET, and the
  command's registration block is stronger evidence than `--help`,
  which renders neither the whole accepted grammar nor the stdin
  fallbacks.

When a claim looks like it can only be settled by a real publish, stop
and report that, rather than deciding it is fine because you expect an
error first.

## Sweep orchestrate/SKILL.md when an sdlc agent's contract changes

The `sdlc` plugin ships no `plugins/sdlc/README.md`. An agent's
contract — what it commits, when it runs, what it returns — is
restated outside that agent's own file in
`plugins/sdlc/skills/orchestrate/SKILL.md`, in several places at once:
the teammate-agent roster near the top (one bullet per agent, each
closing with what that agent leaves behind — a push, a PR, or a posted
review), and again in running prose in the "After each issue-developer
or issue-fixer" section and the fix-loop's `doc-updater` step. A PR
that edits only `plugins/sdlc/agents/*.md` falsifies every one of them
silently. Grep SKILL.md for each agent the PR touches and check every
hit against that agent's current Output section, rather than fixing
only the roster bullet.

Frontmatter tiers are a partial exception, and the halves differ.
SKILL.md deliberately names no agent's `model:`, so a model change is
confined to the agent file. It does state the `effort: medium` default
— twice, in the teammate-frontmatter prose near the top and in the
"Token Efficiency" bullet — because that value is a decision (the
bounded, spec-driven tasks the teammates get are more solid at medium)
rather than a per-agent tier, and because effort has no `Agent`-tool
override, so frontmatter is the only lever. A PR that changes any
teammate's `effort:` therefore updates both SKILL.md statements as
well; grep SKILL.md for `effort` and confirm every hit still describes
the agents it claims to.

Both statements carry a named exception, so neither reads "every
teammate" unqualified: `pr-reviewer-high` and `pr-reviewer-xhigh` pin
`effort: high` and `effort: xhigh`. That is not effort varying per
spawn — the thing the same statements forbid — but a different agent
definition being spawned, per "The reviewer skeletons are copies of one
file" below. A PR that adds a further off-default variant extends the
exception in both places rather than deleting the default.

Cross-reference strings need the same sweep:
`plugins/sdlc/agents/doc-updater.md` and SKILL.md's own fix-loop step
quote a `### After each ...` heading verbatim, so renaming a heading in
SKILL.md means grepping the quoted title across `plugins/sdlc/`.

Lower-yield surfaces name the agents and go stale only when a PR
changes which skill or config field an agent uses:
`plugins/github-prs/README.md` attributes one PR verb per agent in its
opening paragraph and repeats the diff-consumer list in its `/pr-diff`
section, and `plugins/issues/skills/**` names the agents as repo-config
readers, with `lib/repo-config.md` adding which of them dispatch on
`source-control`. The root `README.md`'s `sdlc` bullet names them by
shorthand only, with no behavior to falsify.
`docs/plugin-migration-plan.md` mentions the agents but is a frozen
historical plan — never edit it.

A rule that already lives in `~/.claude/rules/` is **cited** in an sdlc
agent file, a spawn-prompt template, or a Hard Constraint — never
copied into one. Every teammate reads those rules at start of run, so a
local copy is a second source of truth that outranks the original in
the agent's context and drifts without anything noticing. Write the
pointer plus the consequence local to that step, and resist the pull to
re-inline "just the important part" of the rule; see
`docs/plugin-authoring-constraints.md` → "Citing a global rule instead
of restating it in an agent".

SKILL.md's `Phase 1` / `Phase 2` / `Phase 3` headings stay as they
are. They violate the writing-style no-sequence-names rule, but they
are load-bearing across the file's own report templates and a Hard
Constraint ("wait for confirmation before starting Phase 2"), so
renaming them is a cross-file refactor rather than a doc-pass sweep.
Say so in the report instead of churning on them.

## The reviewer skeletons are copies of one file

`plugins/sdlc/agents/pr-reviewer.md`, `pr-reviewer-high.md`, and
`pr-reviewer-xhigh.md` are byte-identical except for the frontmatter
lines `name:` and `effort:` and the tier word inside `description:`.
That is the whole design — the reviewing instructions live in
`plugins/sdlc/skills/pr-review-protocol/SKILL.md`, preloaded into each
skeleton through its `skills:` frontmatter, so a tier is a choice of
which definition to spawn rather than a parameter anything passes.

So an edit to any one skeleton sweeps every other one, and the check
is mechanical:

```bash
diff plugins/sdlc/agents/pr-reviewer.md \
     plugins/sdlc/agents/pr-reviewer-high.md
diff plugins/sdlc/agents/pr-reviewer.md \
     plugins/sdlc/agents/pr-reviewer-xhigh.md
```

Each must report only those lines. Any further differing line is a
defect however sensible it reads: a variant that says something the
base does not is a second source of truth for review behavior, which
is exactly what moving the protocol out of the agent files removed.

Review guidance itself never goes in a skeleton. It goes in the
protocol skill, which is tier-blind by construction — it takes `--pr`,
`--issues`, `--branch` and no tier parameter, and asking it which
variant is running would let the tiers drift apart in behavior as well
as budget. The orchestrator's selection rule lives in
`plugins/sdlc/skills/orchestrate/SKILL.md` → "Picking a reviewer tier";
adding or removing a variant updates that section, the teammate roster
above it, and both `effort` statements the sdlc sweep section already
names.

## Sweep the claude-vm docs when guardrails hook packaging changes

How the `guardrails` permission-gate is *shipped* — prebuilt, committed
binaries under `plugins/guardrails/hooks/bin/<goos>-<goarch>/`, selected
at run time by `uname` — is described outside the `guardrails` tree as
well as inside it, because it decides what a claude-vm bake file's
`packages:` list must contain. The mirroring surfaces are
`plugins/claude-vm/payload/README.md`,
`plugins/claude-vm/payload/config-bake.example.yml`, and
`plugins/claude-vm/skills/claude-vm/SKILL.md` (both the commented config
block and the derived-keys section). What those surfaces mirror is the
*packaging shape*, so the trigger is a PR that changes it: the set of
`<goos>-<goarch>` directories under `plugins/guardrails/hooks/bin/`, the
selection or fail-closed logic in `plugins/guardrails/hooks/hooks.json`,
or the gate's build recipe. Such a PR must update those surfaces in the
same PR, and therefore bumps both plugins' versions.

Rebuilding the committed binaries in place — same directories, same
`uname` selection, still nothing needed in `packages:` — mirrors
nothing, so it fires no claude-vm sweep and no `claude-vm` version bump.
Every classifier-change PR touches `hooks/bin/`, so treating the path
itself as the trigger would demand a no-op edit on every one of them.

Gate *classifier* behavior is nearly the opposite: it lives in
`plugins/guardrails/hooks/permission-gate/README.md`, and no other
plugin or `/docs` markdown describes it. Its one in-plugin sibling is
`plugins/guardrails/rules/scratch-file-location.md`, which describes
verdicts only where they decide **which destination an agent should
write a scratch file to** — the containment and `.git/` denies, their
prescriptive wording, the #225 redirect, the #229 publish read. A
verdict change that leaves that choice
unchanged needs no edit there; one that makes a previously-safe
destination unsafe — or newly grades a path an agent parks a scratch
file in — does. The other exception is
`.claude/agent-memory/`, where notes teaching agents to route around a
gate verdict DO describe classifier behavior and are silently falsified
when the verdict changes. Grep the agent-memory tree — all agent
subdirectories, not one — for the gate's own message fragments ("not all
static literals", "resolves outside the current repository", "cannot
resolve statically") whenever a verdict changes.

## Keep claude-vm's declaration prose and image-state prose apart

`plugins/claude-vm` uses the word "baked" for two different things, and
a sweep that flattens one into the other introduces errors. Before
rewording any "baked" / "already carries" sentence, check which side of
the host/guest seam the code it describes sits on.

- **Declaration (host side).**
  `claude_vm_boot_marketplace_egress_needed` in `payload/lib/config.sh`
  tests a boot-declared marketplace's name against
  `claude_vm_baked_marketplace_names` — the bake *declaration*. The
  build only *tries* to pre-register a boot-declared marketplace, so the
  host cannot know the image state and the gate is deliberately
  conservative. Prose here says "bake-declared", never "already baked
  into the image".
- **Image state (guest side).** `build-guest-image.sh`'s
  `boot_plugin_phase` genuinely reads the image, shelling out to
  `claude plugin marketplace list`. State wording is correct there and
  must survive a sweep; say which of the two a given step reads.
- **Neither.** The apt paragraphs' "hard-secure all-baked config"
  (`payload/README.md`, `payload/build-guest-image.sh`,
  `payload/claude-vm.sh`, `payload/config-boot.example.yml`,
  `payload/lib/config.sh`, `payload/provisioners/podman-mkosi.sh`,
  `skills/claude-vm/SKILL.md`) are about apt packages, which really are
  image bytes, and that gate has no membership test at all. Editing
  those is churn. Grep the exact phrase before deciding a hit is in this
  class: the marketplace sibling in
  `payload/provisioners/podman-mkosi.sh` is spelled "hard-secure
  all-bake-declared config" and belongs to the Declaration bullet above,
  not here.

That one derived-egress gate is described in several places, so a doc
pass that fixes the obvious ones looks complete: `payload/README.md`'s helper
bullet for `claude_vm_boot_marketplace_egress_needed`,
`payload/README.md`'s separate *Derived egress* paragraph much further
down in the guest-image section, and `skills/claude-vm/SKILL.md`'s
`add_marketplace_uris_to_allowlist` bullet. Grep the criterion wording,
not the helper name — the Derived egress paragraph never names the
helper. When the per-entry policy gains skip paths, count them in the
code and check the prose enumerates the same set.

## Sweep every "no read-only mounts" surface when read-only lands

`plugins/claude-vm` extra mounts are read-write only, and the config
carries no `mode:` key: read-only cannot be enforced on this stack
(vfkit's virtio-fs device has no read-only export, and the guest session
is root, so a guest-side `-o ro` is undoable from inside). Issue #233
carries the enforced design — a read-only block device, so the
hypervisor refuses the write and guest root is irrelevant — and it need
not spell its config surface `mode:`.

Until it lands, an explicitly-supplied `mode:` is a hard abort at config
load rather than an ignored key, because silently accepting `mode: ro`
leaves an operator believing a share is read-only when the guest can
write it. The abort is a *presence* test (`claude_vm_mount_mode_entries`
asks yq `has("mode")`), since `mode: ""` and a valueless `mode:` render
as the same empty field an omitted key does. It is asked of the MERGED
boot document, which today lets `mode: {}` through — see the
presence-gate section below before restating "any `mode:` aborts" as a
complete claim.

The "there is no read-only option" claim is restated on every surface an
operator or an agent can reach, so a PR that adds enforced read-only in
one place leaves the rest asserting the opposite: `payload/README.md`
(*No read-only mounts*), `payload/config-boot.example.yml`'s boxed
`mounts` warning, `payload/lib/config.sh`'s extra-mount block and the
abort's own operator message, `payload/claude-vm.sh` in **two** places —
its extra-mount block *and* its `claude_vm_check_mounts` call-site
comment, which restates the same rule in one line —
`payload/build-guest-image.sh`'s `boot_mount_phase` block and its
`-o rw` comment, `skills/claude-vm/SKILL.md`, and
`skills/claude-vm-config-repo/SKILL.md`. `payload/test/config-test.sh`
pins the abort in every spelling.

A `read-only` grep across `plugins/claude-vm/` also turns up a second,
opposite class, and the two are easy to conflate: the **built-in** shares
(`runconfig`, `claudebin`, `claudecreds`) really are read-only, but
**guest-side only**. The host attaches each as a plain
`--device virtio-fs,sharedDir=…,mountTag=…` — the only shape vfkit accepts,
so read-write like any extra mount — and the `ro` comes from the image's own
`/etc/fstab`, authored in `payload/provisioners/podman-mkosi.sh` (the source
of truth for which tag is `ro` and which is `rw`). Write "shared into the
guest, where the image's fstab mounts it `ro`", never "shared read-only into
the guest": the latter puts the guarantee on the side of the seam that
cannot make it, and contradicts the no-read-only-mounts surfaces above.

`payload/README.md` → *Where the `ro` on a built-in share comes from* is the
one place that explains this; every other mention is a restatement that
should point there rather than re-derive it. The restating surfaces are
`payload/README.md` (its credential section and its *Verified claude cache*
section, twice in the latter), `payload/claude-vm.sh`,
`payload/build-guest-image.sh`, `payload/lib/claude-cache.sh`,
`payload/config-boot.example.yml`, `payload/test/host-acceptance.sh`,
`skills/claude-vm/SKILL.md` and `skills/claude-vm-config-global/SKILL.md`.
Grep both `read-only` and `RO` across `plugins/claude-vm/` and sort every hit
into one of these two classes rather than fixing the surfaces a diff happens
to touch.

## Grade a new use of a claude-vm mount tag against the enumeration

A `mounts` tag in `plugins/claude-vm` is consumed **verbatim** in every
position it reaches: vfkit's `mountTag=`, a bare argv word in the guest's
`mount -t virtiofs -o rw <tag> <path>`, a path *component* — in the
`/mnt/<tag>` default mountpoint, in the host-side wrap directory a
single-file source is staged in, and in that wrap's own guest mountpoint —
and a `mounts.tsv` field. `claude_vm_check_mounts`'s charset check
(`[A-Za-z0-9._-]`) is therefore necessary and not sufficient, and its `.` /
`..` and leading-`-` arms exist because two of those positions reject
spellings the charset admits.

`payload/README.md` → *The tag is not just a tag* is the enumeration those
arms are derived from. Code that gives the tag a **new** position — a
filename, another argv slot, a shell-interpolated string — must be graded
against that list and add an arm when the new position rejects something the
existing ones accept, rather than being assumed safe because the charset
passed. The restating surfaces to keep in step are
`payload/lib/config.sh`'s block comment, `payload/claude-vm.sh`'s
`claude_vm_check_mounts` call-site comment — which enumerates the validator's
whole rejection set in one paragraph, a file away from the check itself —
`payload/config-boot.example.yml`'s `tag:` bullet,
`skills/claude-vm/SKILL.md` and `skills/claude-vm-config-repo/SKILL.md`.

The same verbatim-interpolation exposure runs one level wider than the
config: every vfkit argument carrying a host path — the built-in `--device`
shares, the EFI variable store, the disk, the console log, the gvproxy socket
— embeds it in a comma-delimited option string with no comma check, so a
repo, `$HOME` or `$TMPDIR` path carrying a comma breaks a launch that has no
`mounts` entry at all. `$TMPDIR` reaches it on every launch, through the
gvproxy socket's own `mktemp -d`, whatever the mount mode. That is deliberate
and documented in the same README section — do not "fix" it inside
`claude_vm_check_mounts`, which never sees those paths. The single-file wrap
share (`sharedDir=$MOUNT_WRAP_DIR/<tag>`) is the one member the launcher does
check, and only because this feature adds it: the check sits in the
extra-mount loop's single-file branch — at the point of use, not beside the
`$MOUNT_WRAP_DIR` assignment, since only there is there an entry to name —
and blames `$TMPDIR` or the run dir rather than the operator's `mounts` entry.
It buys an early, cause-naming abort, not survivability — the other arguments
still break the same launch, and a directory-only `mounts` list under the same
comma-carrying `$TMPDIR` is not aborted at all.

## Never split a claude-vm TSV record with a tab-IFS `read`

`plugins/claude-vm` moves multi-field records between its scripts as
yq `@tsv` lines. A consumer must not take one apart with
`IFS=$'\t' read -r a b`: a tab is IFS *whitespace*, so `read` collapses
a run of tabs into one separator *and* strips a leading one. A record
with an empty **middle** field loses it, shifting every later field
left; a record with an empty **leading** field loses that. Both are
silent. Issue #226 found the middle-field case on a marketplace url, an
apt `key_url` and a mount `tag`, and the leading-field case on a
marketplace `name` and a `claude.plugins.enabled` key — each producing
a wrong-but-plausible value rather than a failure, so two-field records
are no safer than three-field ones. Read the whole line with
`IFS= read -r` and split it with `${rec%%$TAB*}` / `${rec#*$TAB}`,
which is total because `@tsv` always writes every separator. Skip a
wholly empty record first: an empty result set from these emitters is
one empty *line*, not zero bytes.

Splitting correctly only makes a malformed entry visible. An entry
whose KEY field (a marketplace `name`, a mount `tag`, an `enabled` ref)
is empty must then abort at config load, naming the entry — not be
skipped. The reasoning, the affected loops, the load-time gates, and
the test shape (run the real loop against the real emitter, plus a
negative control rebuilt from the same captured lines) are in
`plugins/claude-vm/payload/README.md` → *Splitting a TSV record back
apart*.

One collection deliberately never travels as `@tsv` at all: `env.set`
(issue #135). An environment value may legitimately contain a tab or a
newline, and `@tsv` escapes those into a literal `\t` / `\n` — silently
changing what the operator wrote, with nothing to detect it downstream.
So `claude_vm_env_set_names` / `_tag` / `_value` fetch one entry per yq
call instead, and the value never shares a line with anything else.
Folding them back into a single record emitter, for symmetry with the
other loops or to save yq invocations, is the bug this paragraph exists
to prevent: the map holds a handful of entries, so the extra calls are
not a cost worth the exposure.

Avoiding `@tsv` is only half of it: `$( )` strips **all** trailing
newlines, and yq adds one of its own, so capturing an `env.set` value
raw loses the newlines the operator wrote and cannot even distinguish
one from three. That is the same silent mutation, and it is worse than a
bad value on its own because the bake tier has no such loss — the value
rides `claude_vm_bake_config_json`'s JSON and Python `shlex.quote`s it —
so the two tiers ship different bytes for the same literal.
`claude_vm_env_set_value` therefore captures behind a sentinel byte,
strips exactly yq's one newline, and returns the value already
`%q`-quoted, so its own caller's `$( )` has no newline left to eat. Any
new reader of an `env.set` value calls that helper rather than adding a
second raw capture. The reasoning and the test shape (source both tiers'
rendered assignments for the same trailing-newline literal and compare
bytes, plus a negative control on the raw-capture shape) are in
`plugins/claude-vm/payload/README.md` → *Guest environment variables*.

## Write claude-vm's config-load guards for bash 3.2, not for bash 5

Every `plugins/claude-vm` script is `#!/usr/bin/env bash`, so on a stock
macOS the interpreter is `/bin/bash` **3.2**. Parts of `lib/config.sh`
need bash 4, but they run late and fail loudly; the config-load guards
run first and decide whether a mount is safe, so a construct that
behaves differently on 3.2 silently changes a guard's verdict instead of
stopping the launch. "The file needs bash 4 anyway" never justifies a
version-dependent construct inside a guard. Specifically: never write a
backslash-escaped delimiter in the **replacement** half of
`${var//pattern/replacement}` (bash ≥ 4.3 unescapes `\/`, 3.2 does not —
hold the literal in a variable), and never expand `"${arr[@]}"` on a
possibly-empty array under `set -u` (write `${arr[@]+"${arr[@]}"}`). Pin
such a guard by *running* it under the host's pre-4 bash, with a negative
control on the spelling it avoids, skipping the block when the host has
no old bash rather than faking it with a fixture. `test/config-test.sh`
carries the same shebang, so the suite is under the same rule, not only
the code it checks: a `case` written inline in an assertion's own `$( )`
mis-parses on 3.2 — the substitution ends at the pattern's `)`, and what
comes back is a fragment of the assertion's own source — so the harness
FAILs on a guard that is fine. Lift the `case` into a function and call
that from the substitution. Say which side of the line such a failure
sits on: a 3.2-only construct in an assertion costs a reader's trust
with a false FAIL, where the same construct in a guard ships a hole. The
reasoning, the measured outputs and the test shape are in
`plugins/claude-vm/payload/README.md` → *A guard must survive the oldest
bash that can reach it*.

## Sweep the ordering notes and share lists on a boot-launcher insertion

Inserting a step into the boot launcher that
`plugins/claude-vm/payload/build-guest-image.sh` emits leaves two
surfaces stale, both far from the diff: the launcher is one long
heredoc, so phase-ordering prose sits hundreds of lines from any
insertion point, and the credential share a new step may read is
described from a different file entirely.

- **The next phase's `ORDERING:` note.** Each phase's block comment
  states its own position as "first thing after X, before Y", so a step
  inserted between two phases silently falsifies the note on the one
  that follows it. Grep `ORDERING:` in `build-guest-image.sh` after any
  insertion, not only the block the insertion lands in.
- **The `claudecreds` content enumerations.** Three headers list what
  the transient credential share carries: `claude-vm.sh`'s run.env
  `CLAUDECREDS_TAG` comment, `claude-vm.sh`'s `CREDS_DIR=` header
  several hundred lines earlier, and `build-guest-image.sh`'s
  `CLAUDECREDS_MNT=` header. Only the first sits next to a change that
  adds an entry. The latter two also assert what the launcher *does*
  with each entry — installs it into `$HOME/.claude/` — so an entry the
  guest merely sources needs that sentence widened rather than a list
  item appended under it.

Re-run `payload/test/boot-launcher-test.sh` on any launcher edit,
including a comment-only one: it parses the emitted script.

## A claude-vm presence gate asks the raw config file, not the merged one

`claude_vm_merge_config`'s last step is
`claude_vm_prune_empty_skeleton`, which deletes every
`CLAUDE_VM_LIST_KEYS` entry whose merged value is an empty list, plus
any map left empty as a result. That prune is correct and stays: it is
what stops a consumer conflating "the operator configured this as
empty" with "the operator never touched it". Its consequence is the
trap — **adding a key to `CLAUDE_VM_LIST_KEYS` silently disarms any
`has()` presence gate on that key**, because the merged document no
longer carries the key in exactly the spellings the gate exists to
catch (a valueless `copy:`, `copy: []`, `copy: ""`). Nothing errors;
the gate just answers *false* and the launch proceeds.

The list-key route is only the loudest of three, and the other two
reach keys that are **not** list keys at all, so "this key does not
union" never clears a merged-document read. Pass 2 deletes an empty
*map* wherever it sits, so any key written `key: {}` vanishes. And a
valueless `key:` arrives as a genuine null, which a `!= null` value
test reads as absent — except in the global-file-with-no-repo-file
layering, where the deep merge against the empty document coerces it
to `''` and the same test says present. A gate reading a merged
document can therefore give two verdicts for one config, decided by
which layer the file sat in.

That is what the first round of issue #135 shipped and what a real
launch caught: `.env.copy` / `.env.files` joined
`CLAUDE_VM_LIST_KEYS`, `claude_vm_check_env` asked `MERGED_BAKE`, and
a bake file holding a valueless `copy:` built an image. The repair is
to ask the RAW files the operator wrote — `claude_vm_env_bake_has_key`
takes one raw bake path, and `claude_vm_check_env` takes the global
and repo bake paths after the two merged documents, which is also what
lets the diagnostic name *which* file carries the key. Never exempt a
key from the prune instead: an exemption reinstates the
configured-empty-looks-configured trap for the next reader and changes
merge semantics for keys that have nothing to do with the gate.
Presence is a property of what was WRITTEN, and only the raw files
still hold it.

So: any gate that asks "did the operator write this key?" asks the raw
file, whatever spelling the test is written in. Grep
`plugins/claude-vm/payload/` for `has(`, `!= null` and `== null` and
grade every hit against all three prune routes — not just against
`CLAUDE_VM_LIST_KEYS`, and not by the document the gate happens to
read. `claude_vm_check_plugin_key_placement` shipped a `!= null` value
test on the merged documents and was measured accepting a misplaced
key in four spellings out of four for `bake` / `install_at_boot` and
two out of four for `update_at_boot` /
`add_marketplace_uris_to_allowlist` / `enabled`; it now asks
`claude_vm_plugin_raw_has_key` of the four raw config paths and takes
no merged document. Its two directions are asymmetric — a BOOT-only
key is hunted in the two BAKE files, a BAKE-only key in the two BOOT
files — which is why it takes four raw paths where
`claude_vm_check_env` takes the bake pair only.

Sitting inside a list *element* is not the exemption it looks like.
`claude_vm_mount_mode_entries` asks `has("mode")` of the merged boot
document on that reasoning, and pass 1 (whole empty list keys) does
leave it alone — but pass 2 is `del(.. | select(tag == "!!map" and
length == 0))`, and `..` descends into list elements, so a `mode: {}`
written inside an entry is deleted and that config launches while
`mode: ro` / `""` / `[]` / valueless all abort (measured through the
real merge against yq v4.53.3, both layers). Treat that as an open gap
in the `mode:` abort, not as a documented exemption. A fallback READER
is fine — `claude_vm_bool_scalar`'s `(<path> == null)` treats a pruned key as
unconfigured, which is what the prune means. Pin the difference by
driving `claude_vm_merge_config` in the launcher's own argument shape
rather than calling the gate on a hand-written fixture —
`config-test.sh`'s env battery was green on fixtures for four review
rounds while the launcher was letting the config through, and the
placement battery had the same shape. The local reasoning and the
measured per-key table are in
`plugins/claude-vm/payload/README.md` → *Guest environment variables*.

## Sweep the claude-vm config wizards when its schema or validation changes

`plugins/claude-vm/skills/claude-vm-config-global/SKILL.md` and
`plugins/claude-vm/skills/claude-vm-config-repo/SKILL.md` duplicate the
config key tables and the YAML templates rather than referencing
`payload/README.md`, `skills/claude-vm/SKILL.md` and the
`config-*.example.yml` files, so nothing forces them to move when those
do. A claude-vm doc pass covers the latter three naturally and misses the
wizards, and the miss is a live defect rather than a cosmetic one: the
wizards instruct the model to write a config verbatim, so a key sitting
in the boot template when it belongs in the bake one — or an entry shape
the launcher now rejects — makes the wizard produce a config that aborts
the launch.

Any change to the config schema **or to its validation** therefore sweeps
both wizard files. These classes land there and nowhere else:

- **Key placement.** Check the key table's bake/boot *file* column, the
  YAML template the skill writes verbatim, and the "Hard constraints"
  placement bullet.
- **A new load-time gate**, even when no key changed — an entry the
  launcher now refuses, a subkey that became required. The wizard writes
  entries verbatim, so a gate it does not know about is a config that
  will not launch. A gate that runs over the MERGED global+repo lists
  belongs in the per-repo wizard's bullet too: the `mounts` tag and path
  checks work that way, so a per-repo entry can collide with a global one
  the wizard has just shown the operator.
- **A behavioral caveat about a value the wizard offers** — proposing a
  single file as a `source:`, say. The wizard is what talks the operator
  into the entry, so a caveat that reaches `payload/README.md`,
  `skills/claude-vm/SKILL.md` and `config-boot.example.yml` and stops
  there leaves the wizard recommending the shape the caveat warns about.

Grep the wizards for `sibling slice` and `schema + merge only` on the
same trigger: a key described there as having no consumer yet keeps that
description after it gains one.

Two neighbours go stale on the same trigger and are missed the same way.
`payload/README.md`'s helper-function list carries new `lib/config.sh`
helpers and changed signatures. And the summary comments that enumerate a
validator's cases or the launcher's phases from *elsewhere in the same
file* — `claude_vm_check_mounts`'s call-site comment in `claude-vm.sh`,
and the emitted boot launcher's file-header step list in
`build-guest-image.sh` — go stale while the function's own header and the
phase's own block comment get updated.

## Sweep every App-permission surface when the starter set changes

The PR-automation GitHub App's permission set is restated as a literal
list in several `plugins/github-setup` places, each a separate edit:

- `skills/gh-create-app/SKILL.md` — the *Starter permission set* table,
  the `required_permissions` code block under it, the "Permissions →
  Repository permissions" bullets the user is told to click through
  during registration, and the `__APP_PERMISSIONS__` rendering example
  in the metadata-doc step.
- `skills/gh-repo-setup-pr-automation/SKILL.md` — the *Required GitHub
  App permissions* block and the `required_permissions = { … }` line in
  its App-resolution step.
- `skills/lib/gh-app.md` — the `required_permissions` example in the
  caller-passes list.

`payload/gh-create-app/app-metadata.md` renders the set from
`__APP_PERMISSIONS__` and holds no literal list, so it never takes this
edit — hard-coding a map there would freeze one caller's scopes into
every rendered metadata doc.
`plugins/github-claude-identity/skills/gh-create-identity-app/SKILL.md`
does carry a literal permission list, but it belongs to a **different**
App (the per-user commit identity, provisioned with its own scopes).
Never sweep it along with this set.

Widening the set has a converge-time consequence worth stating wherever
the new scope is introduced: a scope added to an already-registered App
is not live until every installing account approves it
(`skills/lib/gh-app.md` → "Granting a missing permission to an existing
App"), so every previously-provisioned App fails the library's
permission filter until that approval lands.

That failure is determinate in every caller: the library aborts the
calling skill with its "missing permissions" report and the pointer to
the two-step remediation — on the discovery path from Step 3's
no-suitable-candidates branch, on the `--app-name` path from that
path's own permission check. No caller routes such an App into
registration instead.

## Add a README roster entry when you publish a plugin

When a PR adds a new plugin entry to `.claude-plugin/marketplace.json`,
it MUST also add a matching bullet to the top-level `README.md`
"Published plugins" list, in the same PR. Registering the plugin in
`marketplace.json` and writing its own `plugins/<name>/README.md` does
not update that roster — it is a separate, easy-to-miss doc surface.
Word the bullet like its neighbors: the plugin name in bold backticks,
an em-dash, and a one-line description (pull language from the plugin's
`plugin.json` `description` or its README's opening line).
