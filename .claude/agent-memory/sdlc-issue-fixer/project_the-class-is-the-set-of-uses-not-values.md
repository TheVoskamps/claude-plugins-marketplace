---
name: the-class-is-the-set-of-uses-not-values
description: when a finding names one bad VALUE of a validated field, the class to sweep is the field's USE SITES, not more bad values — grep the variable, and grade each use against the grammar that position demands (path component, argv word, delimited field)
metadata:
  type: project
---

A finding like "`tag: \"..\"` walks out of the wrap directory" invites
the wrong sweep: hunt for more bad *strings*. The productive sweep is
the other axis — every **position** the value is consumed in — because
a validator's charset check is written against the positions its author
had in mind, and the hole is always a position nobody listed.

**Why:** PR #231 round 4. The tag's charset comment justified itself
with two uses (vfkit's `mountTag=`, the guest's `mount` argument). A
`grep -n '\$tag'` across the three payload scripts returned six
non-diagnostic uses: those two, plus a path component in *three*
separate trees (the default mountpoint `/mnt/<tag>`, the launcher's
host-side wrap dir, the guest's wrap mountpoint) and a `mounts.tsv`
field. The reported `..` is simply "not a usable path component". Doing
the same grep for the *sibling* fields found the real second member:
`source:` is interpolated into the same comma-delimited `--device`
string as the tag, and had no charset check at all.

**How to apply:**

1. Grep the variable across every script in the path, minus the
   diagnostic `echo`s. The list is short and the categories fall out.
2. For each use, name the *grammar* that position requires — a path
   component, a bare argv word, a field in a delimited string, a
   filename — and ask which charset-legal values violate it. `.`/`..`
   fail "component"; a leading `-` fails "argv word"; a comma fails
   "field in a comma-delimited string".
3. Measure each candidate against the real consumer rather than
   reasoning: vfkit and the guest's own util-linux are both reachable
   from this host — vfkit is installed at `/opt/homebrew/bin/vfkit`,
   and guest-mount kernel claims settle in a `--privileged` podman
   container run with `--platform linux/arm64`. That is what
   separated the members worth guarding from the ones that already fail
   closed — only `mount -a` fails **open** among the dash spellings.
4. Write the enumeration into a durable doc and point the guard's
   comment at it, so the next use added to the code is graded against
   the list instead of against the charset.

**Grade by fail-open vs fail-closed, not by "is it wrong".** Most
charset-legal-but-wrong values just break loudly, and a guard for those
is only ergonomics. The ones that earn a guard are the ones that
*silently* produce a wrong-but-plausible result — the share pointing at
a directory the config never named, the mount the guest reports as
succeeding while nothing was mounted. Say which is which in the report;
the reviewer grades the same way.

Related: [[implement-the-findings-broader-rule]] (the finding's
recommended one-arm fix is a floor), and
[[make-the-reach-structural-when-enumeration-stalls]].
