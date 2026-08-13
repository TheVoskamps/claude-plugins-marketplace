---
name: derive-the-stale-name-list-by-parsing-bodies
description: A review finding listing "candidate" stale test names is a sample, not the set — parse each test body for what it actually asserts and diff that against the name, since hand-lists both miss members and include false positives
metadata:
  type: project
---

When a finding hands you a list of stale identifiers with the word
"candidates", treat the list as evidence that a CLASS exists, not as the
class. Derive the real set mechanically from the two things that
disagree.

For a bucket-rename round in `plugins/guardrails/hooks/permission-gate`,
that is a ~15-line script: split each `*_test.go` on a leading `func`,
take the
name, regex the body for `Bucket(Ask|Deny|Allow|Defer)`, and report any
test whose NAME claims a bucket its body never asserts.

**Why:** on #262's fix round the review's six candidates were neither
complete nor correct. It missed `TestAwsAskNonReadOp_124` and
`TestGhUnrecognizedFailsClosedToAsk_163` (both name `Ask`, both assert
`BucketDefer`), and the derived run also surfaced pure false positives
the reviewer would have had you "fix":
`TestContainmentNoRepoNeverAllows`, `TestEvolutionLogSkipsAllow` and
`TestNonAllowlistedCmdSubstStillEscalates` all name a bucket
deliberately BECAUSE they assert its absence, and
`TestAwkDefersHelper_31` names the `awkDefers` helper it calls rather
than a verdict. Grade each hit by reading it; the script picks the
candidates, you decide.

Two traps in the same sweep:

- The finding named `TestAwsUnknownGlobalDesyncAsk_64`, which the script
  did NOT flag — its loop also asserts `BucketAsk` on the mirror rows
  (a known-global + credential read), so the name is stale for the arm
  under test while the body legitimately checks both buckets. A
  name/body diff is a candidate generator, never the verdict.
- The bucket-word sweep that CREATED the class can corrupt prose in the
  same hunks: `"on a file-reading verb"` shipped as `"on afile-reading
  verb"`. Catch it by extracting every `[a-z]*(defer|ask|deny|allow)[a-z]*`
  token from the diff's ADDED lines and subtracting a whitelist of real
  words — the residue is a short, readable list.

**How to apply:** any round whose job is "rename X to Y across a
package" ends with a derived diff of the two surfaces (name vs. body,
declaration vs. use), plus the added-word residue check. Report the
false positives you decided against, so the next reviewer does not
re-file them.

Related: [[feedback_enumerate-completely-derive-from-the-structure]],
[[project_audit-a-prose-sweep-by-added-words]],
[[project_count-tally-class-includes-back-references]].
