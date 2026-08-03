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
block and the derived-keys section). A PR touching
`plugins/guardrails/hooks/hooks.json`, `plugins/guardrails/hooks/bin/`,
or the gate's build recipe must update those surfaces in the same PR,
and therefore bumps both plugins' versions. Gate *classifier* behavior
is the opposite: it lives only in
`plugins/guardrails/hooks/permission-gate/README.md`, and no other
markdown in the repo describes it.

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
  (`payload/README.md`, `payload/podman-mkosi.sh`,
  `payload/config-boot.example.yml`, `skills/claude-vm/SKILL.md`) are
  about apt packages, which really are image bytes, and that gate has no
  membership test at all. Editing those is churn.

That one derived-egress gate is described in three places, so a doc pass
that fixes two of them looks complete: `payload/README.md`'s helper
bullet for `claude_vm_boot_marketplace_egress_needed`,
`payload/README.md`'s separate *Derived egress* paragraph much further
down in the guest-image section, and `skills/claude-vm/SKILL.md`'s
`add_marketplace_uris_to_allowlist` bullet. Grep the criterion wording,
not the helper name — the Derived egress paragraph never names the
helper. When the per-entry policy gains skip paths, count them in the
code and check the prose enumerates the same set.

## Add a README roster entry when you publish a plugin

When a PR adds a new plugin entry to `.claude-plugin/marketplace.json`,
it MUST also add a matching bullet to the top-level `README.md`
"Published plugins" list, in the same PR. Registering the plugin in
`marketplace.json` and writing its own `plugins/<name>/README.md` does
not update that roster — it is a separate, easy-to-miss doc surface.
Word the bullet like its neighbors: the plugin name in bold backticks,
an em-dash, and a one-line description (pull language from the plugin's
`plugin.json` `description` or its README's opening line).
