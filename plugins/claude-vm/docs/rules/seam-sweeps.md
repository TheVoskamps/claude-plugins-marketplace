# claude-vm seam sweeps

Statements about the host→guest seam are restated far from the code
they describe, and a change that moves the seam falsifies the ones it
does not touch. Each section names a trigger and the sweep it owes.
Sweep by grepping the wording across `plugins/claude-vm/`, not only the
files the diff touched: the example YAML and the skills are files no
test opens.

## What crosses into the guest's `~/.claude`

The guest's **permission** and **plugin** surface — everything the
rendered `settings.json` carries — comes from the claude-vm configs
only; the host's working rules (`CLAUDE.md`, `rules/`, `agents/`,
`skills/`, `keybindings.json`) are seeded in. Every restatement names
those two layers rather than "the Claude surface" as a whole:
`config-boot.example.yml`'s permissions block,
`config-bake.example.yml`'s marketplaces and plugins block,
`claude-vm.sh`'s settings-render call site, `lib/config.sh`'s rendered
key list, and the `claude-vm` skill and its `config-keys.md`. A change
that seeds further host content widens the seam and re-narrows all of
them. The false half of such a sentence is its noun, so a grep for
`settings.json` keeps returning true statements while the subject above
them is wrong.

## Declaration versus image

Check which side of the seam the code a sentence describes sits on
before rewording it. A host-side test reads a bake **declaration**, so
it says "bake-declared", never "already baked into the image". A
guest-side step, such as `boot_plugin_phase` asking
`claude plugin marketplace list`, reads the image, so state wording is
right there and survives a sweep. The apt paragraphs' "hard-secure
all-baked config" is about image bytes and is neither; grep the exact
phrase, since the marketplace sibling in `provisioners/podman-mkosi.sh`
is spelled "all-bake-declared". The marketplace derived-egress gate is
described in places that never name
`claude_vm_boot_marketplace_egress_needed`, so sweep it by its criterion
wording, and when the per-entry build policy gains a skip path, count
the paths in the code and check the prose names the same set.

## Where a built-in share's `ro` comes from

vfkit's virtio-fs device has no read-only export, so the host shares
`runconfig`, `claudebin` and `claudecreds` read-write, and the image's
own `/etc/fstab` mounts them `ro`. Say "shared into the guest, where the
image's fstab mounts it `ro`", never "shared read-only into the guest",
which puts the guarantee on the side that cannot make it.

The enforced read-only design is issue #233. When it lands, every
surface saying no read-only option exists stops saying it: grep both
`read-only` and `RO` across `plugins/claude-vm/` and sort each hit into
this class or the built-in shares'. The hits a file-by-file pass misses
are a one-line restatement a file from its code (`claude-vm.sh` carries
the rule in its extra-mount block and again at its
`claude_vm_check_mounts` call site), the operator surfaces no test opens
(`config-boot.example.yml`'s boxed warning and the skills), and the
evidence in `test/config-test.sh`, which pins the `mode:` abort in every
spelling.

## Inserting a boot-launcher phase

The boot launcher is one long heredoc in `build-guest-image.sh`, and
each phase's block comment states its position as "first thing after X,
before Y", so an inserted step falsifies the note on the phase that
follows it: grep `ORDERING:` after any insertion. Several headers
enumerate what the `claudecreds` share carries — `claude-vm.sh`'s
run.env `CLAUDECREDS_TAG` comment and its `CREDS_DIR=` header,
`build-guest-image.sh`'s `CLAUDECREDS_MNT=` header, and
`test/host-acceptance.sh`'s share-topology block — and only the first
sits beside a change that adds an entry. Most also say what the launcher
does with each entry and the mode it lands with, a clause true only of
the files the launcher `chmod`s, so an entry the guest only sources, or
copies with no `chmod`, narrows that clause rather than joining the
list. Re-run `test/boot-launcher-test.sh` on any launcher edit, a
comment-only one included: it parses the emitted script.
