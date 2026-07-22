---
name: mkosi-v26-source-verification-technique
description: how to fetch and read mkosi's actual Python source (pinned tag v26) to verify claude-vm claims about its default behavior (repart sizing, apt sources) instead of trusting docs/training-data recall
metadata:
  type: project
---

When a claude-vm fix depends on a specific claim about what mkosi v26 does
by default (e.g. "mkosi's default apt sources include deb-src + a
debian-debug repo", "mkosi has no `[Content]` size setting, only
`mkosi.repart/`"), the mkosi man page (`mkosi.1.md`, fetchable via
`WebFetch` on the raw GitHub URL) is necessary but not sufficient —
several answers (default partition sizing when no `mkosi.repart/` exists,
the exact Debian repo stanzas written into the guest image) are only in
the Python source, not the docs.

**How to fetch it** (found the hard way — the directory name changed
between mkosi versions and a wrong guess 404s silently):

1. `gh api "repos/systemd/mkosi/git/trees/v26?recursive=true"` (redirect to
   a file, NOT stdout directly — the JSON is large) to get the full tree
   listing. Grep the `path` fields for the module of interest.
2. mkosi's per-distro installers live at `mkosi/distribution/debian.py`
   (**singular** `distribution/`, not `distributions/` — guessing the
   plural 404s). The core orchestration (`make_disk`, `build_image`,
   `run_finalize_scripts`) lives in `mkosi/__init__.py` (a single ~5300
   line file, not split into submodules for the main build flow).
3. Fetch file content: `gh api "repos/systemd/mkosi/contents/<path>?ref=v26" --jq '.content' | base64 -d > out.py`.
   `WebFetch` on `raw.githubusercontent.com/.../v26/<path>` 404s for
   `mkosi/distribution/debian.py` even though the file exists — use the
   `gh api contents` route instead, it's reliable.
4. Bare `curl` to `github.com`/`raw.githubusercontent.com`/`api.github.com`
   from a Bash tool call in this sandbox returns nothing / exit 56 — no
   direct network egress; `gh api` and `WebFetch` both work (they go
   through the harness's own network path), plain `curl` does not.

**What this verified for issue #106 round 2** (see the PR 174 diff /
[[claude-vm-mkosi-installs-from-outside-image]] for the prior round's
sibling finding):

- `mkosi/distribution/debian.py`'s `repositories()`: default Debian repos
  are `types=("deb","deb-src")` for FOUR stanzas (main, `debian-debug`,
  `-updates`, `-security`) — `install_apt_sources()` writes these into the
  GUEST image itself (`for_image=True`) at
  `etc/apt/sources.list.d/<release>.sources`, but **only if that file
  doesn't already exist** (`if not sources.exists(): ...`).
- `mkosi/__init__.py`'s `install_skeleton_trees(context)` runs BEFORE
  `install_distribution(context)` in `build_image()` — so a file placed at
  the same path under `mkosi.skeleton/` (copied into the OS tree before the
  package manager step) pre-empts mkosi's own write. `mkosi.extra/` is
  copied AFTER package install and is too late for this trick.
- `mkosi/__init__.py`'s `make_disk()`: when `context.config.repart_dirs` is
  empty (no `mkosi.repart/` provided), it generates `00-esp.conf`
  (`Type=esp`, `Format=vfat`, `SizeMinBytes=SizeMaxBytes=512M` when no BIOS
  boot) and `10-root.conf` (`Type=root`, `Format=<installer's filesystem()>`,
  `CopyFiles=/`, `Minimize=guess`, **no `SizeMinBytes=`at all**) — this is
  the literal root cause of an auto-sized root with zero headroom margin.
  Providing your OWN `mkosi.repart/` is all-or-nothing (verified from the
  `if context.config.repart_dirs: ... else: <generate defaults>` branch,
  an either/or not a merge) — you must supply a complete replacement
  ESP+root pair, not just an addendum root file.
