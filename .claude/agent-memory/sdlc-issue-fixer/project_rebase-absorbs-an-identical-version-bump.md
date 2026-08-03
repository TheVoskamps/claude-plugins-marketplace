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

The third case is the loud, safe one and needs no re-bump: both sides
bumped the same plugin to *different* values (PR #220 — main 0.9.1 →
0.9.2, branch 0.9.1 → 0.10.0) and `plugin.json` conflicts outright.
Resolve to whichever value is greater and stop there; the branch's own
bump is still present, so the per-PR rule is already satisfied and a
further bump would be a second bump in one PR.

**It can fire twice in one fix round.** On PR #217 the branch carried
guardrails `0.9.15`; #208 merged with `0.9.15` and the rebase absorbed
it, so the fixer re-bumped to `0.9.16` — and while the round was still
running, #222 merged with `0.9.16`, so the *second* rebase absorbed the
re-bump the same way and it had to go to `0.9.17`. The trigger is not
"a rebase happened once"; it is "main moved", and on an active repo main
can move again between your rebase and your push.

**The check that actually catches it** is the absence of the file from
`git diff --stat origin/main HEAD`, not reading `plugin.json`'s value —
the value looks perfectly plausible (it is a bump, just not *yours*).
Run that diff after every rebase and confirm each touched plugin's
`plugin.json` is still listed.

**How to apply:** treat the re-bump as a mandatory step of any rebase
onto main, alongside the checks in
[[git-status-cannot-see-main-staleness]], and re-run the whole
rebase → re-bump → rebuild → re-verify loop rather than assuming one
pass settled it. The PR body may also name the version — see
[[pr-body-is-a-swept-surface]]. If the plugin ships committed binaries,
the rebase invalidates those too:
[[buildvcs-stamp-is-primary-clone-head]].
