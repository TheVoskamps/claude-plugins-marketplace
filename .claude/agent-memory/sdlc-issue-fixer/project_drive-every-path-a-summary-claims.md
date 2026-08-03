---
name: drive-every-path-a-summary-claims
description: a finding of the form "several code paths produce this, the summary names one" hands you an enumeration — RUN each listed path before rewording, because one of them can be dead code; on PR #228 the dead one was a tab-IFS read swallowing an empty MIDDLE field
metadata:
  type: project
---

A review finding that says "*several paths reach this condition, and the
summary names only one cause*" is not just a prose task. It hands you an
enumeration of paths, and the cheapest way to reword the summary
honestly is to **drive every path in the list** and read what each one
actually logs. That run is where the real defect turns up.

**Why:** PR #228 (issue #226) round 2 handed a Low prose finding — the
`BAKED_ITEMS == 0` summary in `podman-mkosi.sh` asserted "unreachable"
as the sole cause. Rewording it takes two minutes. Instead, each of the
three listed paths was driven through the *generated* in-container
script. Path 2 and 3 logged their reason and continued. Path 1 — a
boot-declared marketplace with no url — **aborted the build**, the exact
failure the branch existed to prevent, and the branch's own new no-url
branch turned out to be unreachable. The prose finding was the only
thing pointing at it; no test, no reviewer, and no amount of reading
would have.

**The bash fact underneath, which will recur here.** A tab is an IFS
*whitespace* character, so `IFS=$'\t' read -r a b c` collapses a RUN of
tabs into one separator and an empty **middle** field vanishes. On
`name<TAB><TAB>origin` you get `b=origin`, `c=""` — silently shifted.
Two-field reads are safe (a trailing empty field just yields an empty
var), so **the trigger is adding a THIRD column to an existing TSV**,
which is precisely what that PR did. The fix is parameter expansion
(`${rec%%$TAB*}` / `${rec#*$TAB}`), which is indifferent to empty
fields. Same latent hazard, unfixed and reported as out-of-hunk, in the
`apt_sources` loops (`podman-mkosi.sh`, `build-guest-image.sh`) and
`claude-vm.sh`'s mounts loop — all three-field tab reads.

**How to apply:** when a finding enumerates code paths, build a driver
that exercises each one against the *real* generated artifact (for the
provisioner: stub `podman` at `run` to capture `build-in-container.sh`,
slice the loop out, repoint `/work/recipe`, drive it with a stub
`claude`). Print each path's exit status and stderr side by side; a path
that produces the wrong verdict stands out immediately. Then
negative-control the new assertions by copying the payload, restoring
only the old code, and running the new suite against it — four of six
new assertions failed there, which is what makes them worth committing.

Sibling shapes: [[shared-predicate-list-is-one-claim]] (a blanket
predicate over a list is one claim — same "the wrong member is the one
nobody opened" failure), [[real-build-verification-not-unit-tests]]
(why the generated artifact, not the source, is what to exercise),
[[verify-a-predicted-verdict-before-implementing-it]] (measure each
row rather than trusting the brief's prediction of current behavior).
