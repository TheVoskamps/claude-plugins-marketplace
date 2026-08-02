---
name: baked-plugin-changes-verifiable-pre-merge-via-local-marketplace
description: A claude-vm guest bakes plugins from the marketplace's DEFAULT branch, but that does NOT make a plugin change unverifiable pre-merge -- launch the guest from a PR-branch worktree and install the branch as a local-path marketplace from /mnt/repo; only the bake-from-default-branch step waits for the merge.
metadata:
  type: project
---

`claude plugin marketplace add <git-url>` clones the marketplace's
**default branch**. There is no ref/branch/tag selection. So when a
claude-vm bake config lists `<plugin>@thevoskamps`, the *baked* image
gets whatever version is on `main` — never your feature branch.

**That fact is true; the conclusion once drawn from it was wrong.** An
earlier version of this memory said baked-plugin changes are therefore
unverifiable in a real guest before merge. They are not. Issue #216
(guardrails `0.9.14` -> `0.9.15`) was verified *in a live guest
session, pre-merge*: the incident reproduced against the baked
`0.9.14`, then flipped to a real containment deny once the branch's
binary was in place, and the fail-closed path was observed hard-denying
every gated call. Do not tell the human that a guest verification is
structurally impossible.

**How to apply — the pre-merge in-guest recipe:**

1. Launch the guest from a **worktree of the PR branch**: copy the
   repo's untracked `.claude-vm/` config pair into the worktree and run
   `plugins/claude-vm/bin/claude-vm` from the worktree root.
2. The branch checkout is available inside the guest at `/mnt/repo`.
   In-guest `/plugin`: marketplace remove `thevoskamps`, add
   `/mnt/repo`, then install the plugin — that installs the *branch's*
   version, no merge required.
3. `/reload-plugins` re-registers the plugin's hooks in the live
   session, so a hook change takes effect without relaunching.
4. Keep the baked version as the **negative control**: exercise the bug
   against it first, then flip to the branch's version in the same
   session. A before/after inside one live session is the strongest
   evidence available.
5. For a **local-path** marketplace, `CLAUDE_PLUGIN_ROOT` resolves to
   the marketplace *source tree* (`/mnt/repo/plugins/<plugin>`), not
   the version cache under `~/.claude/plugins/cache/...`. Paths in hook
   output and in any probe you write follow that, and it differs from
   the baked (git-marketplace) layout.

**What genuinely waits for post-merge:** only the bake path itself —
the image build installing the new version from the GitHub
marketplace's default branch. That is one line in the PR ("the first
guest launch after merge exercises it"), not a headline, and not a
five-step test plan handed to the human. Everything the bake path
depends on above it is verifiable now.

See [[claude-vm-real-build-and-boot-is-doable]] for the out-of-guest
container probes, which remain useful corroboration alongside — not
instead of — the live guest run, and [[unit-tests-are-not-real-runs]]
for why the live run is the standard.
