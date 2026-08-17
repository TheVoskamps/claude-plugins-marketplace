# claude-vm verification playbook

How to establish a fact about `plugins/claude-vm` without booting a
guest: probe the real hypervisor, the real kernel, the real image
build, and the real launcher, each in the cheapest harness that still
exercises the thing the claim is about.

## Probe vfkit directly — it is installed

claude-vm makes load-bearing claims about what vfkit's `--device`
parser accepts. Do not verify those from the vfkit source when the
binary is on the machine (`/opt/homebrew/bin/vfkit`):

```bash
vfkit --version
vfkit --bootloader "linux,kernel=/nonexistent/vmlinuz,initrd=/nonexistent/initrd,cmdline=console=hvc0" \
      --device "virtio-fs,sharedDir=/tmp/nx,mountTag=probe,readOnly=true" 2>&1 | tail -1
```

Three traps:

- **`--bootloader` is validated before `--device`.** Without one, every
  probe dies on `empty option list in --bootloader command line
  argument` and the device string is never parsed.
- **The `Error:` line is not line 1.** vfkit logs
  `level=info msg="virtual machine parameters:"` first, so a `head -1`
  probe reports the log line and looks like the device was accepted.
  Read the last line, or grep for the error.
- **A device string that parses proceeds to a real boot.** Keep the
  probe non-booting. The `linux` bootloader with a nonexistent kernel
  is the safest harness: every `--device` after it is parsed, and the
  run then dies on `open /nonexistent/vmlinuz: no such file or
  directory`. It works for every device type with no temp dir and no
  existence footwork. The EFI form has no kernel to fail on, so a
  bootloader-only EFI probe that parses really does start a VM.

Pointing `sharedDir=` at a path that does not exist is the other
non-booting form: the run dies on `stat <path>: no such file or
directory`, which also proves the parse succeeded. Never probe a valid
device with an existing directory.

### What the parser establishes

- **The comma is the only metacharacter** in a device option string.
  An `=` or a space inside a path reaches `stat` intact, so a guard
  that widens a comma check into a charset is over-reach. A bare comma
  gives `unknown option for virtio-<kind> devices: <rest of the path
  up to the next comma>`.
- **The comma splits every host-path argument**, not just
  `sharedDir=`: `efi,variable-store=`, `virtio-blk,path=`,
  `virtio-net,unixSocketPath=` and `virtio-serial,logFilePath=` all
  behave the same way. Since `$TMPDIR` reaches
  `virtio-net,unixSocketPath=` through a `mktemp -d` on every launch,
  "no built-in argument touches `$TMPDIR`" is false.
- **A repeated key parses silently, last occurrence winning.** Prove
  that with a position-reversal control: two repeated keys, both
  nonexistent, and the error names the survivor; then swap them and
  the survivor swaps too, which rules out "the second name just
  happens to be the one it stats".
- **`virtio-fs` has no read-only knob.** It rejects `readOnly`,
  `readonly` and a bare `ro` as `unknown option`, while
  `virtio-blk,…,readonly=true` fails on the *value*. Run the
  block-device control too — that contrast is the whole evidence that
  the read-only gap is specific to virtio-fs rather than a quirk of
  the option parser.

## Probe kernel mount semantics in a privileged container

A PR that mounts things in the guest makes kernel claims a unit test
can never reach ("`ro` is enforced", "the bind inherits
read-only-ness", "writes reach the host"). Run the shape:

```bash
podman run --rm --privileged --platform linux/arm64 \
  -v <repo>/.claude/tmp/<slug>:/probe-in:ro \
  docker.io/library/debian:12 bash /probe-in/probe.sh
```

The script goes in a file because the gate blocks compound inline
probes. `findmnt -no OPTIONS <path>` prints the resulting mount's real
flags.

What works there: `mount --bind`, `mount -o remount,ro,bind`, and
writes through them. What does not: a **loop** mount is refused with
`Operation not permitted` even under `--privileged`, so a
superblock-level `ro` filesystem cannot be built that way — reach the
`ro` case with bind plus `remount,ro`, which is the weaker form and
therefore the stronger evidence.

Established facts worth reusing:

- **A file bound out of a read-only mount is read-only.** The
  resulting mount carries `ro` and a write gets `Read-only file
  system`. That is a kernel fact about the bind, not a claude-vm one:
  claude-vm ships no read-only extra mount and no `mode:` key, so do
  not carry it forward as a description of what the launcher does.
- **A file bind mount cannot be replaced by rename.** `mv new target`
  onto the bind fails with `Device or resource busy`. In-place appends
  do reach the source inode, so an `rw` single-file mount serves `>>`
  writers but not `git config`, `sed -i`, or an editor that writes a
  temp file and renames. Probe the named tools, not just `mv`, and
  show the contrast through a **directory** mount where both succeed.
  `docker.io/library/debian:12` has `sed` but no `git`;
  `docker.io/alpine/git` has git and needs `--entrypoint sh`.
- **A leading-dash mount device fails open on exactly one spelling.**
  The guest runs `mount -t virtiofs -o rw "$tag" "$path"`, so a tag is
  a bare argv word. Run that exact shape: `-a` returns `rc=0` with no
  output and nothing mounted, while `--bind`, `-o`, `-r`, `-v`, `-w`
  all fail loudly and an ordinary tag gives `rc=32 permission denied`.
  Run the ordinary-tag control, because `rc=32` is what proves the
  success arm only fires on a real success. Grade such a finding by
  fail-open versus fail-closed.
- **A guest-side `ro` is not a read-only export.** The host always
  shares read-write, and any `ro` is a VFS flag inside a guest whose
  boot launcher runs as root — in the container, root remounts a `ro`
  bind `rw` and the next write lands on the source. An enforced
  read-only design has to move the guarantee to the hypervisor (a
  read-only block device). Raise it as a labelled question whenever a
  doc frames a guest-side `ro` as something the guest "cannot write".

### The probe container must match the guest's package set

A "verified against the real linux-arm64 CLI in a container" claim
does **not** transfer to the guest unless the container's package set
matches the image's. The guest's packages are the mkosi `Packages=`
list in `provisioners/podman-mkosi.sh`; the build container is much
richer, so a probe run there silently carries tools the guest lacks.

The worked incident: a boot phase was verified in a container with
git, the guest bakes no git, and the CLI spawns **system git** for
git-url marketplace operations — so in the real guest every
`claude plugin marketplace add`/`update` fails, fail-soft, and
`update_at_boot: true` is inert. The decisive probe runs the cached
verified guest binary in a plain arm64 `debian:trixie`, with
`HOME=/root` plus the autoupdater and telemetry disables. Note the CLI
can exit 0 on that failure — check the `plugin marketplace list`
output, not the exit code.

Fingerprints that settle "does the CLI shell out or bundle it":
`.git/hooks/*.sample` present means a real system-git clone (a JS git
writes no sample hooks); a tarball path leaves a `.gcs-sha` instead.

A missing guest dependency behind a fail-soft phase still fails the
issue's acceptance criterion in the shipped artifact.

### `--platform` is not optional

`podman run` without `--platform` can silently emulate a cached image's
architecture, printing only:

```text
WARNING: image platform (linux/amd64) does not match the expected
platform (linux/arm64)
```

The probe then "succeeds" — having exercised the wrong architecture's
binary. Always pass `--platform linux/arm64` and prove the platform
inside the run with `uname -m` before trusting the result. Treat that
warning as "this probe is invalid", not as noise.

## Verify mkosi claims against the pinned source

Image-build PRs assert what mkosi does **by default** — the default ESP
size and type, whether the default root is `Minimize=guess` with no
`SizeMinBytes`, whether `install_apt_sources` writes only when the
sources file is absent, whether skeleton trees are installed before the
distribution. All of those are verifiable against the pinned version's
source. Plain `curl` to github.com returns nothing in this sandbox;
`gh api` works:

```bash
gh api "repos/systemd/mkosi/contents/mkosi/__init__.py?ref=v26" \
  --jq '.content' | base64 -d > <repo>/.claude/tmp/<slug>/mkosi_init.py
```

In v26: `make_disk()` carries the repart defaults and `build_image()`
the ordering, both in `mkosi/__init__.py`; `install_apt_sources()` and
`filesystem()` are in `mkosi/distribution/debian.py`. systemd's
`Minimize=` / `SizeMinBytes=` composition is in
`repos/systemd/systemd/contents/man/repart.d.xml?ref=vNNN` — both are
independent lower bounds, so the effective size is the max of the two.

## Slice the real launcher loop to read what it emits

A config validator guards the **config value**. What reaches vfkit is a
**derived** string the launcher builds later
(`sharedDir=$MOUNT_WRAP_DIR/<tag>`, `sharedDir=$MOUNT_SHARED_DIR`) from
host paths the validator never sees (`$RUN`, `$TMPDIR`, `$HOME`). Grade
the guard against the emitted string, and measure it rather than
reading the code.

`config-test.sh` already contains the extraction — reuse it rather than
hand-copying the loop:

```bash
START="$(grep -n '^EXTRA_MOUNT_FLAGS=()$' "$LAUNCHER" | head -1 | cut -d: -f1)"
END="$(awk -v s="$START" 'NR >= s && /^done < <\(claude_vm_mount_specs/ { print NR; exit }' "$LAUNCHER")"
```

Wrap the captured lines in a harness that sources the real
`lib/config.sh` and supplies `MERGED_BOOT`, `RUN`, `MOUNT_SHARED_DIR`
and `CONFIG_DIR`, then `printf` the resulting flags. Pass
`MOUNT_SHARED_DIR` as the tree `$RUN` sits in to get the
`repo.mount: live` branch, or `$RUN/worktree` for `clone`. The same
trick works on the config-load gate block when you want the real
validator.

Before filing such a finding, enumerate the emitted strings with
`grep -n -- '--device'` plus the assignment of each interpolated
variable. A guard on one of them usually buys an earlier, cause-naming
abort rather than a rescue, because the sibling arguments break the
same launch.

### Record the fragment's exit status, not just the tree it leaves

A sliced fragment must run under the `set -euo pipefail` its real
caller sets, and the harness has to capture its **exit status**
separately from its filesystem output. Otherwise the two outcomes that
matter most are indistinguishable: a fragment that skipped one entry
and a fragment that aborted the whole boot at that entry leave the same
partial tree, and a file-only assertion passes on both.
`payload/test/claude-home-seed-test.sh` (issue #108) drives both halves
of a host→guest seam this way — the staging loop sliced out of
`claude-vm.sh` and the install loop sliced out of the emitted launcher,
back to back over a fake host home and a fake guest home — and writes
each half's status to `<case>/host.status` / `<case>/guest.status`. The
unguarded-`mkdir -p` abort it pins is invisible in the tree alone.

A failure injection also has to be planted on the right side of the
seam. Put it on the **mount** when the guest half is what you mean to
exercise: an entry the host itself cannot read is dropped host-side and
never reaches the guest, so injecting it into the fake host home
measures the other loop. And skip a mode-`000` injection under `root`,
which reads such a directory anyway — skip the block rather than faking
the permission.

### A one-filesystem harness cannot see a dropped `-L`

Running both halves of the seam over one local filesystem makes a
dereferencing copy (`cp -RL`) indistinguishable from a plain `cp -R`
by *content*: the copied symlink still resolves, so every assertion on
the consumer tree stays green while the producer ships a link. What
moves is the **shape of the intermediate artifact** the producer
writes — the staged entry is a symlink where it should be a real
directory — so assert that, testing `[ -L ]` before `[ -d ]`, since
`-d` follows symlinks and alone proves nothing. Say in the prose why
content cannot see it: in the real VM the drop is fatal, the link's
target sitting outside the shared dir, which is exactly what an off-VM
harness cannot reproduce.

A slice sanity-check that greps the fragment for the flag under test
(`assert_contains "$(cat "$HOST_FRAGMENT")" 'cp -RL'`) is not that
assertion. It pins a spelling rather than a property — any respelling
that keeps the string passes — and in a mutation run it goes red
alongside the behavioral assertions, leaving a reader to judge which
failure carried the proof. Point the sanity-check at a name that
merely identifies the fragment (`CLAUDE_HOME_SEED_DIR`) instead.

Run the mutation against both `cp` implementations that matter, since
only one of them is on the host you are typing on: macOS BSD `cp`
under `/bin/bash` 3.2, and GNU coreutils in a `debian:trixie` aarch64
container (`podman run --platform linux/arm64 --user 1000`).

## The run dir sits inside the guest's repo share

Trace where a new host-side artifact lands before accepting any
isolation story around it:

- `RUN="$REPO_SRC/.claude/tmp/$RUN_ID"` whenever the launcher starts
  inside a git repo — the run dir is *inside the operator's repo*, not
  in `$TMPDIR`.
- `repo.mount: clone` (the default) shares `$RUN/worktree`, so a
  sibling under `$RUN` is outside the share.
- `repo.mount: live` shares `$REPO_SRC` itself, and the image's fstab
  mounts tag `repo` **rw**. So in live mode everything under `$RUN` is
  reachable and writable from the guest.
- `cleanup()` retains `$RUN`, so whatever lands there outlives the
  run, inside the repo.

For each new `$RUN/<thing>`, ask what it grants the guest in live mode
— a hard link to an arbitrary host file hands the guest a writable
second path to the same inode. The launcher now tests `$RUN` against
`$MOUNT_SHARED_DIR` and falls back to a `$TMPDIR` directory when the
run dir is inside the share, so read that branch before re-filing it.
The hard link is also why `ln` is used rather than `cp` (same inode
means write-through), so "move it out of the repo" trades against "a
hard link cannot cross filesystems" — expect that tension in any fix.

## Measure the emitters before worrying about record injection

**yq `@tsv` quotes a field containing a tab or a newline** rather than
emitting the raw byte. So a control character in a config value reaches
the validator as `"…<TAB>…"` — leading `"`, therefore not absolute,
therefore rejected — and a block-scalar newline cannot split one entry
into a second, unvalidated record. Run the real emitter and dump the
bytes (`claude_vm_mount_specs "$boot.yml" | od -c`) before writing a
word about a forged separator, and re-check it if the repo changes yq
major version: the quoting is yq's behavior, not a property of the
consumer's hand split.

**Command substitution strips all trailing newlines.** A
`value="$(cmd …)"` capture loses them while a sibling path — a JSON
value through Python `shlex.quote`, or a direct `eval` assignment —
preserves them, so one feature with several emitters can ship the same
literal as different bytes depending on which path carried it. Feed
every emitter a fixture whose value ends in a newline and read the
emission with `od -c` rather than by eye. Beware YAML line folding when
building the fixture: write the escape as literal backslash-n bytes in
the file. The correct fix strips exactly the one newline the emitter
appends, via a sentinel capture
(`v="$(cmd; printf x)"; v="${v%x}"; v="${v%$'\n'}"`), never a
strip-all. The same blind spot appears in name validation: Python
`re.match(r"^…$")` accepts a trailing newline, so demand `re.fullmatch`
or `\Z`.

## Name probe fixtures with distinct words, not case pairs

On macOS's default case-insensitive APFS, fixture names differing only
by letter case are **one file**. A probe using `gb.yml`/`gB.yml` for a
bake/boot pair has each boot write silently overwrite its bake sibling,
and the code under review then appears to lag one call behind — a
symptom that reads exactly like a caching bug or a swapped-argument
defect.

The tell: a function returns the right answer standalone but the wrong
one inside a larger flow, and the wrong answer matches a *different*
fixture's content. Before filing that, print the fixture the callee
actually read from inside the flow, and check the fixture names for
case-only distinctness. Name them `gbake.yml` / `gboot.yml`.
