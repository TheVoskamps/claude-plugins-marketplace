---
name: claude-vm-config-wizard-skills-lag
description: claude-vm feature work updates payload/README.md + skills/claude-vm/SKILL.md thoroughly and leaves the two config-WIZARD skills (claude-vm-config-global / -repo) stale; sweep them for the changed keys, because a wrong bake/boot placement there makes the wizard write a config that cannot launch.
metadata:
  type: project
---

A claude-vm doc pass naturally covers `payload/README.md`,
`skills/claude-vm/SKILL.md`, and the `config-*.example.yml` files, and
naturally misses `skills/claude-vm-config-global/SKILL.md` and
`skills/claude-vm-config-repo/SKILL.md`. Two classes of staleness collect
there:

- **Key placement in the YAML template the wizard writes.** These skills
  instruct the model to write a config verbatim, so a key sitting in the boot
  template when it belongs in the bake template makes the wizard produce a
  config that aborts the launch. This is a live defect, not a cosmetic one.
- **"The consumer lands in a #39 sibling slice" / "schema + merge only"
  claims** for keys that have since gained a real consumer. `github.auth` is
  the only key those claims are still true of.

**Why:** the wizard skills are one directory over from the skill being edited,
and they duplicate the key tables and templates rather than referencing them —
so nothing forces them to move together. This is the same "comments elsewhere
in the same plugin don't get updated" pattern as
[[claude-vm-config-redesign-stale-comment-classes]], one level up at the
doc-file granularity.

A third class, seen on issue #226: a new **load-time validation gate** (an
entry the launcher now rejects) is a wizard concern even though no key
changed — the wizard writes entries verbatim, so a gate it does not know
about turns into a config that aborts the launch. #226's gates (a
`claude.marketplaces` entry with no `name`, a `mounts` entry with no
`source`/`tag`) were swept into README/SKILL/examples but not the wizards.
Issue #157 repeated it exactly: the `mounts` entry gained `mode: ro|rw`
enforcement, a `path:` key and seven new abort conditions, all of which
landed in README/SKILL/`config-boot.example.yml` while
`claude-vm-config-repo/SKILL.md`'s "Extra `mounts` this repo needs" bullet
still described only the #226 source/tag pair. The wizard bullet is also
where the cross-tier warning belongs — the tag/path collision checks run
over the MERGED global+repo list, so a per-repo entry can collide with a
global one the wizard just read in its "show the global basis" step.

A fourth class, also #157: the launcher's **call-site** comment for a
validator (`claude_vm_check_mounts` in `claude-vm.sh`) and the emitted boot
launcher's **file-header step list** in `build-guest-image.sh` both go stale
when the validator gains cases or the launcher gains a phase. The developer
updates the function's own header and the phase's own block comment; the
summary comments that enumerate them elsewhere in the same file do not move.

**How to apply:** after ANY claude-vm config-schema OR config-validation
change, grep
`plugins/claude-vm/skills/claude-vm-config-{global,repo}/SKILL.md` for the
changed key names AND for `#39`/`sibling slice`/`schema + merge only`. Check
three surfaces in each: the key table's bake/boot **file** column, the YAML
templates the skill writes verbatim, and the "Hard constraints" placement
bullet. Also check `payload/README.md`'s helper-function list — new
`lib/config.sh` helpers and changed signatures land there and were again not
updated by the developer.
