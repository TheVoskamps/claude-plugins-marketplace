# Working in plugins/claude-vm

**Who reads this and when:** any agent about to edit a file under
`plugins/claude-vm/`, including its example YAML, its config wizards and
its shell tests. Read it before the first edit.

`plugins/claude-vm/payload/README.md` is the plugin's own reference and
carries the measurements behind each rule below; this file carries the
rules that decide how a change must be made.

## Write for bash 3.2

Every script is `#!/usr/bin/env bash`, so on a stock macOS the
interpreter is `/bin/bash` **3.2**. No launcher-reachable code may need
bash 4. The failure mode is not a loud error: an associative-array
assignment mis-parses silently on 3.2, and a config-load guard that
behaves differently there changes its verdict rather than stopping the
launch.

Specifically: no `local -A` / `declare -A` (use parallel indexed arrays
with a last-wins lookup); no backslash-escaped delimiter in the
**replacement** half of `${var//pattern/replacement}` (hold the literal
in a variable); no `"${arr[@]}"` on a possibly-empty array under
`set -u` (write `${arr[@]+"${arr[@]}"}`).

`payload/test/config-test.sh` carries the same shebang, so the suite is
under the same rule — a `case` written inline in an assertion's own
`$( )` mis-parses on 3.2 and FAILs a guard that is fine; lift it into a
function. The suite must be **fully green** under `/bin/bash`. A "these
N always fail on 3.2" baseline is never an acceptable answer: that
baseline is exactly what hid a real render defect for several rounds.
Pin a guard by running it under the host's pre-4 bash with a negative
control on the spelling it avoids, skipping the block when the host has
no old bash rather than faking it with a fixture.

## Never split a TSV record with a tab-IFS `read`

Multi-field records travel between scripts as yq `@tsv` lines. A tab is
IFS *whitespace*, so `IFS=$'\t' read -r a b` collapses a run of tabs and
strips a leading one: an empty middle field shifts every later field
left, an empty leading field vanishes, and both are silent. Read the
whole line with `IFS= read -r` and split with `${rec%%$TAB*}` /
`${rec#*$TAB}`, skipping a wholly empty record first — an empty result
set from these emitters is one empty *line*, not zero bytes.

Splitting correctly only makes a malformed entry visible. An entry whose
KEY field is empty must then **abort at config load, naming the entry**,
not be skipped.

`env.set` deliberately never travels as `@tsv` at all: a value may
legitimately contain a tab or a newline, which `@tsv` would silently
escape. Fetch one entry per yq call. And never capture such a value with
a bare `$( )`, which strips trailing newlines the operator wrote — call
`claude_vm_env_set_value`, which captures behind a sentinel byte and
returns the value already `%q`-quoted. Folding these back together for
symmetry, or adding a second raw capture, is the bug this paragraph
exists to prevent.

## A presence gate asks the raw config file, not the merged one

`claude_vm_merge_config` ends by pruning empty structures, which is what
stops a consumer conflating "configured empty" with "never touched". The
consequence is that a merged document cannot answer "did the operator
write this key?" — separate routes erase the key in exactly the
spellings a gate exists to catch, and no one of them is the whole
story:

- a key in `CLAUDE_VM_LIST_KEYS` whose merged value is an empty list;
- any key written `key: {}`, wherever it sits — the prune descends into
  list elements too, so sitting inside one is not the exemption it looks
  like;
- a valueless `key:`, which arrives as null and which a `!= null` test
  reads as absent — except in the global-file-with-no-repo-file
  layering, where the merge coerces it to `''` and the same test says
  present. One config, two verdicts, decided by which layer it sat in.

So any gate asking what the operator **wrote** takes raw config paths,
whatever spelling the test uses — which is also what lets its diagnostic
name the offending file. Never exempt a key from the prune instead: that
reinstates the trap for the next reader and changes merge semantics for
unrelated keys. A fallback *reader* treating a pruned key as
unconfigured is fine.

Grep `payload/` for `has(`, `!= null` and `== null` and grade every hit
against every route above. Pin the difference by driving
`claude_vm_merge_config` in the launcher's own argument shape — a
hand-written fixture kept two such batteries green for four rounds while
the launcher was letting bad configs through.

## Keep declaration prose and image-state prose apart

"Baked" means two different things here, and flattening them introduces
errors. Before rewording any "baked" / "already carries" sentence, check
which side of the host/guest seam its code sits on:

- **Host side** tests a name against a bake *declaration*. The build
  only *tries* to pre-register, so the host cannot know the image state
  and the gate is deliberately conservative. Say "bake-declared".
- **Guest side** genuinely reads the image. State wording is correct
  there, and must survive a sweep — say which of the two a step reads.
- **Neither**: the apt paragraphs' "hard-secure all-baked config" really
  are about image bytes. Editing those is churn. Grep the exact phrase
  before classing a hit here — the marketplace sibling is spelled
  "all-bake-declared" and belongs to the first bullet.

The derived-egress gate is described in several places, one of which
never names its helper, so grep the **criterion wording** rather than
the function name.

## Narrow a surface-only claim to the layer it measures

Several files assert that the guest's Claude configuration comes from
the claude-vm configs only, because the host's `~/.claude/settings.json`
is never read. Each such sentence names the layer it actually measures —
the permission surface, the plugin surface — never "the Claude surface"
as a whole. A change that seeds further host `~/.claude` content into
the guest must re-narrow every one of them, and the false half of such a
sentence is its **noun**: the `settings.json` grep that finds these
sites keeps returning true statements while the subject above them is
wrong. Grep the surface wording across the whole plugin, including the
example YAML that no test and no doc pass opens.

## Sort every read-only mention into one of two classes

Extra mounts are read-write only and the config carries no `mode:` key:
read-only cannot be enforced on this stack, and an explicitly-supplied
`mode:` is a hard abort at config load rather than an ignored key,
because silently accepting `mode: ro` leaves an operator believing a
share is protected. The abort is a *presence* test, and the merged
document lets `mode: {}` through — an open gap, not a documented
exemption. Issue #233 carries the enforced design.

Built-in shares are the opposite class and read the same way in a grep:
they really are read-only, but **guest-side only** — the host attaches
each read-write, and the `ro` comes from the image's own `/etc/fstab`.
Write "shared into the guest, where the image's fstab mounts it `ro`",
never "shared read-only into the guest".

Grep both `read-only` and `RO` across the plugin and sort every hit into
one of these classes rather than fixing the files a diff happens to
touch. A PR that lands enforced read-only must update every surface
asserting it is impossible, including the tests that pin the abort and
the verification playbook that carries the measurements the claim rests
on.

## Grade a new use of a mount tag against the enumeration

A `mounts` tag is consumed **verbatim** in every position it reaches:
vfkit's `mountTag=`, a bare argv word in the guest's `mount`, a path
*component* in several places, and a TSV field. The validator's charset
check is therefore necessary and not sufficient, and its `.` / `..` and
leading-`-` arms exist because two of those positions reject spellings
the charset admits. Code that gives the tag a **new** position must be
graded against `payload/README.md` → *The tag is not just a tag* and add
an arm when the new position rejects something the existing ones accept.

The same verbatim-interpolation exposure runs wider than the config:
every vfkit argument carrying a host path embeds it in a comma-delimited
option string with no comma check, so a repo, `$HOME` or `$TMPDIR` path
containing a comma breaks a launch with no `mounts` entry at all. That
is deliberate and documented — do not "fix" it inside the mount
validator, which never sees those paths.

## Sweep the far-away surfaces on a launcher or schema change

These classes of surface sit far from the diff that falsifies them:

- **Ordering notes.** The boot launcher is one long heredoc and each
  phase states its own position as "first thing after X, before Y", so
  an inserted step falsifies the *next* phase's note. Grep `ORDERING:`
  after any insertion. Re-run `payload/test/boot-launcher-test.sh` on
  any launcher edit, including a comment-only one — it parses the
  emitted script.
- **Content enumerations.** Four headers list what the transient
  credential share carries, only one of them next to a change that adds
  an entry, and one of them inside a test file. Most also assert what
  the launcher *does* with each entry and the mode it lands with — an
  entry the guest merely sources, or copies without a `chmod`, makes
  that clause false, so narrow the clause rather than appending to the
  list.
- **The config wizards.** `skills/claude-vm-config-global/SKILL.md` and
  `skills/claude-vm-config-repo/SKILL.md` duplicate the key tables and
  YAML templates instead of referencing them, and a doc pass over the
  README and the examples misses both. They instruct the model to write
  a config verbatim, so a stale key placement or entry shape produces a
  config that aborts the launch. Any change to the schema **or to its
  validation** — including a new load-time gate with no key change, and
  including a behavioral caveat about a value a wizard offers — sweeps
  both. A gate that runs over the merged global+repo lists belongs in
  the per-repo wizard too. Grep them for `sibling slice` and
  `schema + merge only`: a key described there as having no consumer
  keeps that description after it gains one.

Neighbouring surfaces go stale on the same trigger:
`payload/README.md`'s helper-function list, and the summary comments
that enumerate a validator's cases or the launcher's phases from
elsewhere in the same file while the function's own header gets updated.
