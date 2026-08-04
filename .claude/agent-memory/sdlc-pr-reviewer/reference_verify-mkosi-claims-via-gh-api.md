---
name: verify-mkosi-claims-via-gh-api
description: claude-vm PRs make load-bearing claims about mkosi's default repart/apt-sources behavior; verify them against the pinned mkosi source with `gh api contents ...?ref=vNN`, not from recall.
metadata:
  type: reference
---

claude-vm image-build PRs (issue #105/#106 lineage) routinely assert
things about what mkosi does BY DEFAULT — "mkosi's default ESP is
512M / Type=esp / CopyFiles=/boot:/ + /efi:/", "the default root is
Minimize=guess with no SizeMinBytes", "install_apt_sources only writes
`if not sources.exists()`", "install_skeleton_trees runs before
install_distribution". These are all verifiable against mkosi's pinned
source (the recipe pins a version, e.g. v26) rather than trusted from
the PR body.

**How to fetch** (plain curl to github.com returns nothing in this
sandbox; `gh api` works):

```bash
gh api "repos/systemd/mkosi/contents/mkosi/__init__.py?ref=v26" \
  --jq '.content' | base64 -d > <repo>/.claude/tmp/<slug>/mkosi_init.py
```

Key locations in v26: `make_disk()` (repart defaults, ~line 3507) in
`mkosi/__init__.py`; `install_apt_sources()` + `filesystem()` in
`mkosi/distribution/debian.py`; `build_image()` ordering
(install_skeleton_trees THEN install_distribution) in `__init__.py`.
systemd's `Minimize=`/`SizeMinBytes=` composition is in
`repos/systemd/systemd/contents/man/repart.d.xml?ref=vNNN` — both are
independent lower bounds, so effective size is max(guessed, floor).

**Write fetched files under the repo's own `.claude/tmp/`** — it keeps
them with the worktree for the rest of the review. The harness
scratchpad works as well; reads and writes there are allowed. See
[[guardrails-binary-verification]] for the sibling "exercise the real
artifact, don't trust the description" pattern.
