# Writing and storing the round's review (`skills/lib/theorem-based-pr-reviewer/review-body.md`)

The **argued review** says how the review was conducted, argues each
standing counterexample in full, and keeps the near-misses visible. It
goes to the round's review file, per "Persist the round's records and
review" below; the PR gets what `--mode summary` renders from it, per
"Post one review".

## The argued review's sections

Its sections, in order, each under a `##` heading spelled as its bold
name below:

1. **Verdicts** — one line per member of the set you review against,
   and the overall line, per "Per-issue verdicts, one overall".
2. **Review method** — the **head SHA reviewed**, which pins every
   verdict to a revision; the tier that ran and what picked it; how many
   theorems were live and how many the generator emitted; one paragraph
   on the method, for a reader new to it — theorems generated against
   the PR and its issues, a disprover per live theorem, a verifier per
   disproved one, severities transcribed from the surviving class; and:

   - the **mode** the round ran under;
   - the **kind of round**: a fallback round (the condition that fired,
     saying it ran without seed records or is the first documentation
     round, or naming `<prev-round>` as the round it carried from), a
     delta round (naming `<prev-head>`,
     and round 0 when the carried records were the seed's), an
     adjustment-only round (what the comments changed), an empty-delta
     round whose verdicts all carried forward, or a `--full` round, per
     the precedence in "Carry the previous round's theorems forward";
   - for a **resumed** round, the theorems inherited settled, the
     resume passes taken, and any duplicate `leave`; for a moved head,
     both SHAs;
   - the **assessment**: each recommendation other than accept that
     you applied, by theorem id and action, and the ids its adds took;
   - what was **skipped**: one line listing each acceptance-criterion
     theorem carried as retired, and each theorem retired as `subject
     removed` — by a `RETIREMENTS` line or a `retired-subject-removed`
     row — each with its `state-detail`;
   - every **unsettled** theorem as a **pipeline defect**: its id and
     the `dispose` disposition that left it unsettled, an
     `unsettled-subject-removed-minted` one included.
3. **Change counts** — files changed, additions, deletions.
4. **Disproved theorems** — one entry per theorem `dispose` left
   `disproved`, in id order: the claim, the counterexample narrative
   built on the disprover's `**Evidence:**` quote verbatim, the
   consequence as the verifier confirmed or corrected it, and a closing
   `→ Finding N`. With a malformed verifier report, or none, give the
   disprover's consequence and say which; with none, carry no
   `→ Finding N`.
5. **Findings** — terse and actionable, numbered as `dispose` numbers
   them, each in the `**Finding:** / **Evidence:** / **Recommendation:**` format,
   tagged with its theorem id and member(s). Beside — never instead of —
   the Critical / High / Medium / Low grade, a finding may carry a
   free-text character phrase, and each carries a fix-size
   characterization: "mechanical", "one line", "needs a human ruling",
   or the like. Section 4 holds the evidence narrative.
6. **Verified** — every survived or refuted theorem, one line each: id,
   claim, and what the disprover checked; a refuted one adds the offered
   counterexample and the rejection reason, worded as one counterexample
   rejected, not a proof. Unnumbered, never counted toward severity.
7. **Theorems that could not be settled**, if any — id and claim, no
   severity.
8. **Overall verdict** — the overall verdict in prose, with a path to
   approve: what must change for APPROVED, summarizing section 5's fix
   sizes; on APPROVED, what the approval rests on.
9. **Closing-line corrections** — every correction "Identify the issue
   set" reported, one per line as `add <issue>` or `remove <issue>` and
   nothing else on the line, or `none`. Nothing here counts toward
   section 1 or section 8.

Sections 4, 6 and 7 are the **full theorem list**: every theorem the
round fanned out over appears in exactly one, but a
`retired-subject-removed` one, which the skipped line lists instead,
and each section-5 finding is the actionable face of a section-4 entry.

A finding row's entry uses the format in "Findings must quote, not
paraphrase", its `**Evidence:**` block the disprover's quote
**verbatim** — never re-quoted or paraphrased — tagged to the theorem's
member issue(s). A `verified-refuted` theorem is **not** proved: one
counterexample was offered and rejected, and its Verified line says
exactly that.

## Findings must quote, not paraphrase

Every finding that references the content of a file, PR body, commit
message, or code line **must include verbatim quoted evidence** from the
source, in this exact format:

```markdown
**Finding:** <description>
**Evidence:** in `<file-or-location>` at <line/section>:
> <verbatim quote of the offending text>
**Recommendation:** <what to change>
```

- The `>` line under `**Evidence:**` is a byte-for-byte copy of the
  source text, arriving from the disprover and copied through
  unchanged; you never re-derive it.
- A finding about the **absence** of something must (a) name where it
  would normally appear, AND (b) quote verbatim the surrounding code
  that should have contained it.
- A finding without a verbatim `**Evidence:**` quote is malformed.

## Per-issue verdicts, one overall

Every member of the resolved set gets its own verdict line, transcribed
from the `verdict` line `--mode dispose` printed for it, with what it
rests on in parentheses:

```markdown
## Verdicts

- #206 — APPROVED
- #196 — NEEDS_CHANGES (1 High)
- #201 — BLOCKED (1 unsettled)
- **Overall — BLOCKED**
```

An issue a closing-line correction names gets no line, and neither does
a sanctioned deferral; note the deferral as context below the block.
The overall line is `dispose`'s `verdict overall` line, and is what
`/github-prs:pr-review-submit` receives, spelled per "Post one review".
A finding spanning members is tagged to every member its theorem's
`issues` carries. For a batch of one the block collapses to one line
equal to the overall verdict.

## The theorem records file

Every round stores one records file holding every recorded theorem, in
the layout the preloaded `sdlc:agent-result-persist-interface` skill
gives under `records` in "The modes". `state-detail` takes the values
the `dispose` rows, `RETIREMENTS` and the adjustment table give,
`assessor-rejected` for a theorem the assessment rejected or merged,
and `human-refuted` for a seed theorem the human rejected or merged at
round 0. `settled-at` is the head the state was established against, an
older one on a carried-forward retired theorem. A `severity-override`
sits only on a theorem an adjustment comment overrode and is carried
verbatim; a later override replaces it, and nothing else clears it.

## Persist the round's records and review

Store the round's output under XDG state **before** you post anything,
so a run that dies between the two leaves the round readable rather
than announced, handing each input over by path:

```bash
sdlc-agent-result-persist --mode records --carry \
  --pr <PR_REF> --round <this round's number> \
  --edits .claude/tmp/<task-slug>/stamped-edits.tsv \
  --from .claude/tmp/<task-slug>/stamped-new-records.md

sdlc-agent-result-persist --mode review \
  --pr <PR_REF> --round <this round's number> \
  --from .claude/tmp/<task-slug>/review.md
```

**The script builds the records file; you never assemble it**, per the
preloaded `sdlc:agent-result-persist-interface` skill → "The modes".
You stage both inputs with `Write` — never a program, script or
pipeline you wrote to transform records — as the two files "Assemble
the round's live list" staged, with each `dispose` row's stamps
transcribed in:

- **The stamped edits** — the edits file's lines, then for each row on
  a carried record its `state` and `state-detail`, the empty value
  where the row's is `-`, and on a `retired` row `settled-at`
  `<headRefOid>`. Leave `--edits` out when no line remains.
- **The stamped new records** — the new-records file, each record given
  its row's `state`, `state-detail` and `settled-at` lines the same way,
  replacing any it holds, with no `state-detail` line where the row's
  is `-`; a record with no row keeps the lines it holds. Leave `--from`
  out when there are none.

When `--mode print-records` read no records, store the stamped new
records with `--from` alone; whenever it read records, use `--carry`.
The review file carries every section of "The argued review's
sections" in full. **Both calls run on every round that reaches
disposition**, a resumed one and an empty-delta round included: a round
that stored neither leaves the next carrying forward from an older
round, undetectably.

## Post one review

Render the body to post from the stored round, once both are stored:

```bash
sdlc-agent-result-persist --mode summary \
  --pr <PR_REF> --round <this round's number>
```

**Post its output unedited**: `Write` its stdout byte for byte to
`.claude/tmp/<task-slug>/summary.md`, then post it by path:

```text
/github-prs:pr-review-submit <PR> --verdict <approve|request_changes> --body-file .claude/tmp/<task-slug>/summary.md
```

Pass the **overall** verdict, unconditionally, in the skill's spelling:
APPROVED as `approve`, NEEDS_CHANGES and BLOCKED alike as
`request_changes`; the skill owns what GitHub accepts. Use the **file
form**, never the inline `<body>`: the body's backticks and `${…}` state
root would reach the shell through a double-quoted `--body`. A
`summary` refusing for a missing section means the review file lacks a
heading "The argued review's sections" requires: fix the review, store
it again, and render again.
