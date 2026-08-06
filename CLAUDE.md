# CLAUDE.md

## Bump the plugin version when you change a plugin

When a PR modifies any file under `plugins/<name>/`, it MUST also bump
that plugin's `version` in `plugins/<name>/.claude-plugin/plugin.json`,
in the same PR. The version bump is a separate, deliberate edit. A
plugin change without a version bump is incomplete.

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

SKILL.md's `Phase 1` / `Phase 2` / `Phase 3` headings stay as they
are. They violate the writing-style no-sequence-names rule, but they
are load-bearing across the file's own report templates and a Hard
Constraint ("wait for confirmation before starting Phase 2"), so
renaming them is a cross-file refactor rather than a doc-pass sweep.
Say so in the report instead of churning on them.

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
plugin or `/docs` markdown describes it. The exception is
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
as the same empty field an omitted key does.

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
no old bash rather than faking it with a fixture. The reasoning, the
measured outputs and the test shape are in
`plugins/claude-vm/payload/README.md` → *A guard must survive the oldest
bash that can reach it*.

## Add a README roster entry when you publish a plugin

When a PR adds a new plugin entry to `.claude-plugin/marketplace.json`,
it MUST also add a matching bullet to the top-level `README.md`
"Published plugins" list, in the same PR. Registering the plugin in
`marketplace.json` and writing its own `plugins/<name>/README.md` does
not update that roster — it is a separate, easy-to-miss doc surface.
Word the bullet like its neighbors: the plugin name in bold backticks,
an em-dash, and a one-line description (pull language from the plugin's
`plugin.json` `description` or its README's opening line).
