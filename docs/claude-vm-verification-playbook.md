# claude-vm verification playbook

How to establish a fact about `plugins/claude-vm` without booting a
guest: probe the real hypervisor, the real kernel, the real image
build, and the real launcher, each in the cheapest harness that still
exercises the thing the claim is about — and, when a real boot has
been run, how to read what its green actually establishes.

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

## A green boot marker is three claims, not one

`payload/test/host-acceptance.sh` proves that a launcher step ran by
grepping a fixed marker string out of the guest console capture —
`(b4)` greps `seeded host working rules` for issue #108's
`claude-home/` seed. Reporting that green is the cheap half; the
structural claims a PR body then makes around it are separable, and
each is one command.

**Who else emits the marker, and from which branch?**
`grep -rn "<marker>" plugins/claude-vm/`. For `(b4)` the hits are the
launcher's own `log` line, the assertion, and the off-VM seed suite.
Then read the emitting branch rather than stopping at the grep: that
`log` line sits under `[ -n "$seeded_entries" ]`, so a green means an
entry really installed, where the sibling branch logs a distinct
"nothing to seed" line. A marker emitted unconditionally at the top of
a step would prove only that the step was reached.

**Was the image stale?** The launcher's source is not part of the
image-identity hash — `compute_pinned_version` in
`build-guest-image.sh` appends only
`CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS`, and `LAUNCHER_LOGIC_REV` is the
only constant that invalidates a cached image — so criterion (a)'s
version-stamp assertion is the staleness control.
`build-guest-image.sh --print-version` prints `<base>+launcher<N>`;
compare that `<N>` against
`git show origin/main:<path>/build-guest-image.sh | grep
LAUNCHER_LOGIC_REV`. A higher `<N>` rules out a *pre-branch* launcher.
It does not rule out an earlier commit on the same branch that already
carried the same rev, so word the claim that way rather than as "built
from the launcher this branch emits".

**Which interpreter ran the harness?** `bash -c 'echo $BASH_VERSION'`.
Do not infer it from the invocation spelling: `bash host-acceptance.sh`
and `./host-acceptance.sh` are the same binary wherever the PATH `bash`
*is* `/bin/bash`, which is the stock macOS layout and what this repo's
host measures (3.2.57 either way). Running a suite "the runbook way"
therefore buys no second interpreter on its own — and the cross-domain
playbook's slice advice, to run a fragment under `/bin/bash` and under
`bash`, assumes a newer `bash` earlier in PATH, which is the
assumption to measure before claiming a two-interpreter run.

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

## A guest boot is an assertion runner, via a stub `claude`

The boot launcher runs `"$CLAUDE_BIN" "$@"` as the hvc1 session, and
`CLAUDE_BIN` is `/mnt/claudebin/claude` — a path on a share the host
stands up. Put a `#!/bin/sh` script there instead of the real binary.
It only has to be executable, since the seam's check is
`[ ! -x "$CLAUDE_BIN" ]`. It runs as root inside the booted guest, can
assert anything, and `exit 0` makes the guest power itself off.
`payload/test/host-acceptance.sh` criterion (b) already works this way.

Write results to `/dev/console` (hvc0), not stdout: hvc0 is the
host-captured `logFilePath`, so the assertions survive in a file to
grep afterward. Bracket the block with unambiguous
`BEGIN`/`END` markers so a host poll loop has something to wait on.

Such a build needs no claude binary at all.
`CLAUDE_VM_GUEST_CLAUDE_BIN` is consumed only when the plugin manifest
is non-empty, so driving `build-guest-image.sh --output` with a bake
config derived from two `{}` documents skips the whole
verified-cache and GPG path. Set `CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS`
to a probe-specific string or the probe races the operator's real
cached images, and give `CLAUDE_VM_ROOT_HEADROOM_MB` a small value to
shave the build.

Skip the boot phases the probe is not testing by writing empty
`apt-install.list`, `apt-sources.tsv`, `plugin-marketplaces.tsv` and
`plugin-install.list` onto the runconfig share, with
`CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT=false` and
`CLAUDE_VM_PLUGINS_UPDATE_AT_BOOT=false` in run.env. The boot then
needs no egress at all.

### What the claudecreds share must carry

Two of its files are hard aborts and one is optional, and the
difference is not guessable from their names — each missing one costs
a whole boot to discover:

- `settings.json` — `[ ! -s … ]` → `exit 1`. It is the security-posture
  file (the deny-list backstop), so the launcher refuses to boot
  without it. Render one with the real
  `claude_vm_render_guest_settings` over a `{}` document.
- `.credentials.json` — `[ ! -s … ]` → `exit 1` as well. A probe that
  treats the credential as optional because it is not testing
  authentication still has to supply a non-empty one.
- `claude-json-seed.json` — guarded by `[ -s … ]` and simply skipped
  when absent. This is the only genuinely optional member.

### Boot-probe requirements that each cost a boot

- Attach a **second** `virtio-serial,logFilePath` device even when
  headless. Without it `serial-getty@hvc1` has no tty, the boot
  launcher never runs, and nothing appears at all. Device order is
  load-bearing: the first is hvc0, the second hvc1.
- The gvproxy socket directory must be a short `$TMPDIR` path. vfkit
  derives a sibling socket in the same directory and the AF_UNIX limit
  is 104 bytes, which a worktree path under `.claude/worktrees/` already
  overflows.
- `efi,variable-store=<path>,create` requires that the path not exist.
  Pre-creating it as a directory fails with `Is a directory`.
- A local-path marketplace does not need a `.git` directory; a plain
  `git archive` export of the tree registers and installs fine.

Write-through is checkable from the host afterward: the shares are
ordinary host directories, so once the VM exits, read them directly.

## Assert the guest environment with the same stub

The stub extends to environment assertions. `printf` each variable to
`/dev/console`, and use `eval "val=\${$v-<unset>}"` so an unset
variable stays distinguishable from an empty one — that difference is
usually the whole point of the probe.

Derive the fixtures through the real helpers rather than by hand: the
boot tier's env file from `claude_vm_resolve_boot_env` over a real boot
document, the bake tier from `claude_vm_bake_config_json` into the
provisioner's own render. A hand-written fixture measures the
transcription, not the code.

Boots of the *same* `.raw` answer separate criteria and the later ones
are nearly free: one with the full boot tier establishes precedence,
one with an empty claudecreds share establishes that the baked half
persists while the boot half is absent.

For a secret-leak check, give the secret a distinctive literal and
`LC_ALL=C grep -a -c '<literal>' guest.raw` after the boots. Because
`virtio-blk,path=` is read-write, anything the guest wrote is in that
file, so the absence is a genuine "not on the guest filesystem"
measurement rather than an inference. Pair it with an in-guest
`grep -rl` over `/root`, `/etc` and `/var`.

## `apt-get update` exits 0 when every fetch fails

The obvious container-egress probe is broken:

```bash
podman run --rm docker.io/library/debian:trixie \
  sh -c 'apt-get update -qq >/dev/null 2>&1 && echo OK || echo FAILED'
```

Failed index fetches are `W:` warnings, not errors, so this prints `OK`
on a machine with no outbound TCP whatsoever — the exact false
reassurance that sends a reader off blaming their own diff for a build
that died on `Unable to connect to deb.debian.org:80`.

Probe the socket instead:

```bash
podman run --rm docker.io/library/debian:trixie bash -c \
  'timeout 10 bash -c "echo > /dev/tcp/deb.debian.org/80" && echo OK || echo FAIL'
```

Use `bash`, not `sh`: debian's `/bin/sh` is dash, which has no
`/dev/tcp` and reports `Directory nonexistent` — a false FAIL that
reads like a network verdict. macOS has no `timeout`, so the host leg
of the same question needs `curl --max-time` instead.

A live gvproxy proves nothing about egress. `podman machine start`
succeeding, and a fresh non-zombie gvproxy with its vfkit in `ps`, are
both compatible with containers having zero connectivity. DNS resolves
through the machine either way, so name resolution is not a
discriminator. When the machine is in that state the honest report is
that a real build is unavailable until it is repaired — corroborate on
the guest's platform in a cached `debian:trixie` container, and restore
the machine to the state you found it in.

## A plugin change is verifiable in a live guest before merge

`claude plugin marketplace add <git-url>` clones the marketplace's
**default branch** — there is no ref, branch or tag selection — so a
baked image carries whatever version is on the default branch, never a
feature branch. That fact is true, and the conclusion once drawn from
it is false: it does not make a plugin change unverifiable before the
merge, and telling a human that a guest verification is structurally
impossible is wrong.

The pre-merge recipe:

1. Launch the guest from a **worktree of the branch**, copying the
   repo's untracked `.claude-vm/` config pair into the worktree and
   running the launcher from the worktree root.
2. The checkout is available inside the guest at `/mnt/repo`. In the
   guest, remove the git marketplace, add `/mnt/repo`, and install the
   plugin from it — that installs the branch's version with no merge.
3. `/reload-plugins` re-registers the plugin's hooks in the live
   session, so a hook change takes effect without relaunching.
4. Keep the baked version as the negative control: exercise the bug
   against it first, then flip to the branch's version in the same
   session. A before/after inside one live session is the strongest
   evidence available.
5. For a local-path marketplace, `CLAUDE_PLUGIN_ROOT` resolves to the
   marketplace *source tree* (`/mnt/repo/plugins/<plugin>`), not the
   version cache. Paths in hook output and in any probe follow that,
   and it differs from the baked layout.

Only the bake path itself waits for the merge — the image build
installing the new version from the marketplace's default branch. That
is one line in a PR, not a test plan handed to the human.

## Driving a real build and boot yourself

The podman machine is usually stopped and must be started explicitly,
and its start does not always produce a working container network.
Verify egress with the socket probe above before concluding anything
about your own diff, and stop the machine again when done.

Drive the build with `build-guest-image.sh --output <path>`, exporting
the same environment the launcher does. Derive the JSON blobs with the
real `claude_vm_bake_config_json` and `claude_vm_bake_plugins_json`
over merged documents; the bake files' own schema has `packages:` as a
flat list, with no `.packages.bake` normalization on that path.

**Getting a real linux-arm64 claude binary.** The host's cache under
`~/.config/claude-vm/` is unreadable from a worktree-isolated agent.
Fetch one into repo scratch through the product's own verified path
instead, setting `CLAUDE_VM_CACHE_DIR` under `.claude/tmp/<slug>/` and
sourcing `lib/claude-cache.sh` to call `claude_cache_ensure`. The
signing-key fingerprint is the only blocker: invoking `gpg` directly is
denied and the pinned value sits in an unreadable config, but
`claude_cache_gpg_verify` prints the real fingerprints in its mismatch
diagnostic, so one run with a dummy pin yields them. Corroborate that
value against the published key by computing the OpenPGP v4 fingerprint
of the key file in pure Python — `sha1(b"\x99" + uint16(len(body)) +
body)` over the first tag-6 packet, stdlib only. gpg still runs fine
inside the product's own scripts; only a top-level call is blocked.

Setting `CLAUDE_ARGS` to `plugin list` makes claude run
non-interactively, print the installed set to hvc1, and exit, which
turns a full boot including the plugin phase into an assertion channel
with no interactive session and no Keychain.

**Inspect the built `.raw` with `debugfs`, not `mount`.** Loop devices
are unavailable in this podman machine even under `--privileged`, which
is why the recipe uses `RepartOffline=yes`, and a macOS bind-mounted
`.raw` cannot back a loop device either. Read the partition table with
`sfdisk -J` (root is the last entry), `dd` that range out, and use
`debugfs -R "ls -l <path>"` or `debugfs -R "rdump <path> <dest>"`.

The guest-side boot phases are testable without a VM by slicing the
function out of the launcher heredoc and sourcing it in an arm64
container against a real linux-arm64 binary. A compiled hook binary is
likewise testable on real linux-arm64 without any VM, since the podman
machine is arm64 linux and the debian images are the guest's platform.
`--platform linux/amd64` works under emulation. What is *not* reachable
this way is an interactive in-guest claude session actually firing the
hook — that one needs the live guest run above.

## Unit tests do not reach the generated artifacts

The provisioner's suite exercises pure functions in the config library
and never renders or executes the `mkosi.conf` and in-container build
script the provisioner writes. A real end-to-end build finds failures
those tests had no chance to catch.

The cheap harness that does reach them: put a stub `podman` on PATH in
repo-local scratch that answers the preflight with success and, on
`run`, captures the bind-mount source paths and copies the generated
recipe out. That runs the provisioner's real code path and hands you
the literal artifacts to inspect, without a real build.

The suite's real-boot acceptance run is not coverage for every guest
change either: it attaches only the built-in shares and never writes a
mount manifest, so a change to the guest's mount phase is unverified by
it — that run only proves the launcher still boots.

## Inspect a built image with `debugfs`, not a loop device

Loop devices are unavailable in this podman machine even privileged, so
read the partition table, carve the root partition out with `dd`, and
read the filesystem directly:

```bash
fdisk -l guest.raw                      # partition 2 is the ext4 root
dd if=guest.raw of=rootfs.img bs=512 skip=<start> count=<count>
debugfs -R "stat /usr/bin/apt-get" rootfs.img
debugfs -R "cat /var/lib/dpkg/status" rootfs.img
```

This `e2fsprogs` build has **no** offset flag, so passing the whole
disk image does not work — only a partition-only file does.

Note that the provisioner's staging tree is never copied into the final
image; that is mkosi's design. To see a rendered file that lives there,
inspect the stage directory before its exit trap deletes it, not the
built image.

## mkosi facts that are only in its source

The man page is necessary but not sufficient — default partition sizing
and the exact repository stanzas written into the image are only in the
Python source. Fetch the tree listing through the API and grep the
paths rather than guessing a module path, because the directory name
changed between versions and a wrong guess 404s silently.

**`Minimize=guess` sizes the filesystem, not the partition.** With
offline repart it tight-fits the filesystem to measured content, while
a minimum-size setting only enlarges the GPT slot. The two do not
compose as "the larger wins": the result is a partition with a large
unformatted tail the running guest cannot use, and a guest whose free
space matches the tight-fit filesystem rather than the configured
headroom. Verify by reading the GPT entry and the filesystem
superblock separately out of a real built image.

## The build-time package manager does not land in the image

mkosi's package list is installed by mkosi's own tooling running in the
build container, which builds the guest rootfs from outside it. Those
packages land in the guest; the tool that installed them does not. So a
boot-time step that shells out to the package manager fails with
"command not found" unless that package is *also* named in the recipe's
base package list. Bake it unconditionally when the feature it serves
has a default-on knob — gating the package on "is this configured"
reproduces the same failure.

**`apt-get clean`, measured in a real container:** it deletes fetched
archives and both binary cache files, and does **not** touch the
package-index lists, which a later install needs. Those caches
regenerate on every subsequent invocation, so `clean` must be the last
call in a sequence to leave the working set trimmed. Test this on a
stock image only after removing the vendor drop-in that already
disables those caches, or the measurement is of the drop-in.

**A keyring's extension decides how apt loads it.** apt dispatches on
the file extension, not the content, so binary OpenPGP bytes saved
under an armored name load as an empty keyring and every update fails
unsigned — while a signature verifier that *does* sniff content
validates the same bytes happily. Sniff the first bytes after fetching
and rename accordingly, before the line that composes the
`signed-by=` path. An operator-pinned path is exempt, since renaming
would desync the emitted line from the file on disk.

## Probing the marketplace CLI

The plugin CLI accepts only a few marketplace source forms; a
`file://` URL is rejected outright, and a bare local path registers as
a directory needing no git at all. So a local throwaway marketplace
cannot exercise the git code path, and a probe built on one passes in a
git-less container while proving nothing.

To exercise the git path, add the real marketplace and then roll the
clone backwards inside it — fetch a specific old revision and hard
reset to it, staying on the cloned branch so the later update
fast-forwards. Installing then pins the old version and the boot
phase's update must carry it forward.

## Two guest-image facts that are easy to get backwards

**Getty respawn is governed by the restart setting, not the leading
dash.** The upstream unit ships an always-restart policy, and
overriding that is the only thing that stops the unit restarting when
its login program exits. The leading dash on the exec line does
something different — it makes a nonzero exit be *reported* as success.
Shipping correct behavior with the wrong rationale invites a future
reader to restore the dash believing it inert, or delete the restart
override believing the missing dash covered it.

**The image identity hash does not cover the boot-launcher source.** It
hashes the bake config files and the repo name, and nothing else, so a
launcher logic change needs its own revision stamp to invalidate cached
images.

## vfkit's own signal handler force-kills after a fixed deadline

vfkit's SIGINT/SIGTERM handler requests an ACPI stop and then waits a
**hardcoded** five seconds before logging a forced stop and killing the
VM. A real guest reliably takes longer than that to halt, so a terminal
interrupt reaching vfkit always force-kills. Its REST channel maps a
stop request to the same underlying call but with no force timer, so
the wait is natural — which is why the guest powering itself off is the
clean path, and why a workaround built on job control is not.

## An unquoted heredoc does not have comments

A heredoc opened unquoted — required whenever a variable must
interpolate into the generated file — gets no `#`-comment parsing. A
prose comment written with paired backticks for a human reader is
**command substitution** to the shell: it executes the quoted text as a
real host command and splices its output into the generated file.

The symptom is misleading, and reads as two or three unrelated bugs
somewhere else entirely — an unknown flag from a command your script
does not contain, a "command not found" for a fragment of your own
prose. Grep the script for the command the error names before believing
it; when it appears nowhere, the heredoc is the place to look.

## A missing key and an explicit empty value differ

Asked whether a downstream reader can see an empty field, the
reachability question splits in two and the halves can have opposite
answers. Probe both against the real emitter before writing "this
cannot happen".

Measured on the TSV emitters: with a guarded expression every absent
key normalizes to a genuinely empty field, but an unguarded field
renders a **missing** key as the literal four-character string `null`
while an explicit empty value renders empty. So the same question is
answered no for the omitted key and yes for the explicit one, in one
emitter. Answering from the omitted-key case alone grades the site
unreachable.

## One named mechanism is usually one of several routes

When a finding says a mechanism destroys the thing a gate tests, resist
reasoning from that mechanism to the whole key set — it is usually one
route of several, and each reaches a different subset. Build the
member-by-spelling-by-layer matrix and run it through the real merge.

Measured on the plugin-key placement gate, the named prune was one of
three routes: the whole-empty-list-key prune, a recursive empty-map
delete that reaches **every** key written as an empty map whether it is
a list key or not, and no prune at all — where a valueless key arrives
as a genuine null that a not-null test reads as absent. Negative-control
with the pre-fix launcher extracted at its own revision.

## Slice the caller to prove a guard is wired

A new validator carries two separable claims: that it rejects bad
input, and that the program actually asks it. A unit test on the helper
proves only the first, and the second is what silently regresses — a
guard can be written, tested, and never wired, or wired after the code
that already consumed the bad value.

Slice the launcher's own config-load block by line range, wrap it in a
harness that sources the library and sets the tier variables from
arguments, append a success marker, and run it with the temporary
directory pointed inside the harness's own workspace. The fixture then
travels the real merge and the real gate order.

## Let re-verification cost break a tie between remedies

A finding often lists several acceptable remedies, and in this plugin
the cost of *re-verification* is usually the deciding one, because the
only real evidence for guest behavior is a real build plus a real boot
and a fix round rarely gets to redo that matrix.

Prefer the remedy that leaves the already-verified path byte-identical,
even when it is more lines than the alternative. Confining a change to
the branch that was never verified anyway preserves the one piece of
expensive evidence the work already has.
