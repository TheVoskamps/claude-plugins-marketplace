---
name: rebase-absorbs-an-identical-version-bump
description: when a branch and main both bumped a plugin to the SAME version, the rebase resolves the plugin.json cleanly and the branch ends up shipping exactly main's version — re-bump after every rebase, because the repo's per-PR bump rule is now unsatisfied and nothing conflicts to tell you
metadata:
  type: project
---

After rebasing a plugin-touching branch onto main, re-read each touched
plugin's `version` against `git show origin/main:plugins/<name>/.claude-plugin/plugin.json`
and bump again if they now match.

**Why:** when both sides bumped the same plugin to the same value (both
`0.9.0` → `0.9.1`, which is what happens when the branch and a
concurrently-merged PR each apply the repo's "bump the plugin version
when you change a plugin" rule), git sees an identical change on both
sides and resolves it silently — no conflict, no marker, no mention in
the rebase output. The file simply drops out of
`git diff origin/main..HEAD` entirely. The branch still modifies files
under `plugins/<name>/`, so `CLAUDE.md`'s per-PR bump rule is now
violated, and the only signal is the *absence* of a diff line you have
to notice is missing. This bit PR #208: sdlc went 0.9.0 → 0.9.1 on both
sides, and the rebase left the branch shipping main's 0.9.1 until a
fresh 0.9.2 was committed.

The sibling case is benign and easy to confuse with it: a plugin main
never touched (guardrails, 0.9.14 on main vs 0.9.15 on the branch)
survives the rebase untouched and needs nothing. So check *every*
touched plugin, and compare against main's value rather than against
your memory of what the branch shipped.

**How to apply:** treat the re-bump as a mandatory step of any rebase
onto main, alongside the checks in
[[git-status-cannot-see-main-staleness]]. The PR body may also name the
version — see [[pr-body-is-a-swept-surface]].
