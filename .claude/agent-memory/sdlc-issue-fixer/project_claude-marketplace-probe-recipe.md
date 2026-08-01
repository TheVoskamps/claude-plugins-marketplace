---
name: claude-marketplace-probe-recipe
description: How to verify claude-vm plugin/marketplace behavior for real - the CLI rejects file:// and treats a local path as a Directory source (no git), so exercise the git path by rolling a real clone back to an older SHA; and never trust the CLI's exit code or success message.
metadata:
  type: project
---

Verifying issue #107's `update_at_boot` criterion against the REAL
`linux-arm64` claude binary in a container. Three things that cost time and
are not discoverable from the repo:

**1. `claude plugin marketplace add` accepts only three source forms.** It
rejects anything else with `Invalid marketplace source format. Try:
owner/repo, https://..., or ./path`. In particular `file:///work/mp` is
REJECTED, and a bare local path (`/work/mp`) registers as
`Source: Directory (/work/mp)` — which needs **no git at all**. So a local
throwaway marketplace repo cannot exercise the git code path, and a probe
built on one will pass in a git-less container and prove nothing.

**2. To exercise the git path against a marketplace you can "bump", roll a
real clone backwards.** Add the real `https://…/claude-plugins-marketplace.git`
marketplace, then inside `~/.claude/plugins/marketplaces/<name>`:

```bash
git fetch -q --depth 1 origin <old-full-sha>
git reset -q --hard <old-full-sha>          # stays on the cloned branch, so
                                            # the later update fast-forwards
```

Then `claude plugin install <plugin>@<marketplace>` pins the OLD version, and
the boot phase's `marketplace update` + `plugin update` must carry it forward
to current HEAD. Pick the SHA from `git log origin/main -- <plugin>/.claude-plugin/plugin.json`.
GitHub honours fetch-by-SHA, so `--depth 1` is enough.

**3. The CLI lies about success when its git is missing.** With `git` moved
off PATH, `claude plugin marketplace update` prints
`✔ Successfully updated 1 marketplace(s)` and **exits 0**, having updated
nothing. `marketplace add` at least exits 1 with
`ERR_STREAM_PREMATURE_CLOSE: git ... clone --depth 1 ...`, but `update` is
silent. Grade the ARTIFACT (the installed version out of `claude plugin
list`), never the exit code or the message. This is why a fail-soft boot
phase can be inert with zero warnings on the console log.

**Negative-control shape that worked**: one container, one script, a
`with-git|no-git` argument. Always install `git ca-certificates` first and do
the BAKE with them present (the real bake runs in the build container, which
always has git); under `no-git`, `mv /usr/bin/git /usr/bin/git.absent` +
`hash -r` AFTER the bake, so phase 4 models a correctly-baked image booting
into a git-less guest. Note bare `debian:trixie` has no `ca-certificates`, so
a git-present run without it fails on `Problem with the SSL CA cert` — a
container artifact, not a guest one (the guest's `Packages=` has it).

See [[claude-vm-inspect-raw-image-with-debugfs]] for confirming the package
actually landed in the built rootfs, and
[[repo-boundary-gate-blocks-any-tool-arg-outside-repo]] for why the cached
binary must be reached by `podman -v` rather than by copying it in.
