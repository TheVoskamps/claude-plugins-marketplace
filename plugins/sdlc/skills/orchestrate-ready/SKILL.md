---
name: orchestrate-ready
description: Assess whether an issue is specified well enough for /sdlc:orchestrate to run without mid-run escalation, resolve gaps interactively, rewrite the body in place, and set its status to the repo's orchestrate-ready status.
---

# Orchestrate-Ready Grooming

You are grooming exactly one issue up to the bar `/sdlc:orchestrate`
needs, then flipping its status. That bar is
`sdlc:orchestrate-readiness`'s. Issues are filed at the tracker's
default backlog status; they reach the orchestrate-ready status once
they are sound enough that an
`issue-developer` can implement them without stopping to ask a
question the body should have answered.

Run this **in the main session**, not in a subagent. The whole point
is the conversation with the user: you surface gaps, propose answers,
and the user decides. A subagent cannot ask, so it would have to
answer the open design questions itself — which is the exact failure
this skill exists to prevent.

Every read and write of the issue goes through an `issues:*` skill —
`/issue-view`, `/issue-update`, `/issue-set-status`, and the
relationship verbs. Never hand-roll a `gh api graphql` issue mutation
here: the skills read repo-config, dispatch on the repo's tracker, and
emit the namespace's canonical abort wording, and a raw call silently
skips all of it.

## Resolve the sdlc config first

Before anything else — the questions "Invocation" below asks included —
read `skills/lib/sdlc-config.md` and resolve its three tiers per its
"Reading" section, once. An abort it calls for stops the run before
any question is asked or the issue is read. Print every key's resolved
value beside the tier it came from, one `<key>: <value> (<tier>)` line
per key, under an `sdlc config:` line. Throughout the rest of the run,
each key's name means its resolved value.

## Invocation

```text
/sdlc:orchestrate-ready <issue-number>
```

Exactly one issue number per invocation, with or without a leading
`#`. Once the config is resolved, if `$ARGUMENTS` is empty, ask which
issue to groom before proceeding; that is not a decision, since it
offers nothing to choose between and no issue exists yet to key a
record on. If it names more than one, put to the user which single
issue to groom as a decision, per "Putting a decision to the user",
keyed on the first issue named, with the issues named as its options —
grooming is a conversation per issue, and interleaving two of them
loses track of which decision belongs to which. The user can decline
it: skipping grooms no issue and ends the session.

## Putting a decision to the user

You put a decision to the user only by printing what
`sdlc-decision ask` printed for it. Read `skills/lib/decision-record.md`
the first time a turn raises one, and put every decision through it,
keyed on the issue as `--issue <host>/<owner>/<repo>#<N>`, the
reference read off the URL `/issue-view` prints. Kernel: what `ask`
printed goes last in the reply and ends the turn, unless it printed
every problem as resolved by a standing ruling. An open design
question is class `design-gap`. A yes to one action you named — filing
a side-effect issue — is an approval, not a decision.

## Procedure

1. **Fetch the issue.**

   ```text
   /issue-view <N>
   ```

   That gives you the body, the labels and assignees, the type, every
   configured project-field slot, and the parent/sub-issue/blockedBy/
   blocking edges in one call. Read the edges from that output rather
   than inferring them.

2. **Run the check, then report the verdict first and the gaps
   after.** Invoke `/sdlc:orchestrate-readiness <N>`; its verdict, its
   `Searched:` line and its gap list are what you report. Open with the
   verdict, so the user knows the size of the conversation before
   reading the detail. Relay the `Searched:` line as it stands, then
   list the gaps as a numbered list, each gap the rewrite repairs, per
   step 3, with the repair step 4 makes and each other gap with a
   **proposed default answer** — your best reading of what the issue
   intends, stated as a proposal.

   An issue that is already `ready` still gets step 6: the status flip
   is the deliverable even when the body needs no edit.

3. **Settle the gaps one topic at a time.**

   **An earlier session's open design gaps come first.** Before writing
   any record, run:

   ```bash
   sdlc-decision pending --issue <host>/<owner>/<repo>#<N>
   ```

   Exit 0 means no design gap from an earlier session waits on the
   user. Exit 4 names each one on stderr, by record and problem: put
   each such record to the user again on that record, as
   `skills/lib/decision-record.md` says for a problem still open, and
   raise no new record for a gap it covers. On any other exit, relay
   its stderr verbatim and stop.

   **A gap the rewrite repairs is not raised.** Each such gap is
   repaired in step 4's rewrite, as that step says, and listed in step
   7's report:

   - a gap line opening `mechanical:` — the section or sentence
     deleted, the heading added, or an `## Acceptance` section's
     bullets moved;
   - an "Outcome, not method" gap.

   **A gap about an out-of-scope system is not raised.** A system is
   out of scope when this repository has no source or config for it:
   another repository, a remote backend, a third-party service. A gap
   whose repair lies in one is put to no one; step 4's rewrite states in
   one sentence what the change assumes of that system, and grooming
   continues. A "Sandbox fit" gap is handled the same way: the
   out-of-repo work it names leaves the body for that assumption, with
   no decision record, and filing the work where it lands is step 5's
   offer, an approval rather than a decision.

   **An "Acceptance criteria" or "Files affected" gap** that is not
   `mechanical:` is settled through the closing approval below, as the
   paragraphs on those sections say, and is not raised on a record of
   its own; a design decision those paragraphs find inside it is a
   design gap.

   **Every gap this step names no other handling for is a design gap,
   put to the user as a decision**
   per "Putting a decision to the user", one topic per record: its
   problem, two to four options, one recommendation, and why. Where a
   decision is too open to enumerate, such as a name, the options are
   candidate proposals. The user may always answer in free text, which
   `sdlc-decision answer` stores as the pick `none` beside the reply
   verbatim, and a reply that reframes the topic is its answer. Reflect
   back what you hear in the user's own words, and move to the next
   topic once it is settled. Your proposed defaults are proposals; the
   user decides.

   **Look for the existing pattern before writing a design gap's
   record**, and fill its `existing-pattern` slot from that search, as
   `skills/lib/decision-record.md` says.

   **A contradicted repo statement is the user's to settle.** For a
   "No contradicted repo statement" gap on a policy claim, the user
   decides what happens to the statement, as a design gap whose options
   are the statement's fates that bar item names. Propose deleting a
   capability claim only with the test that showed it false and that
   test's verbatim output, as the option's `command:` evidence.

   **Rework the acceptance sections for the closing approval.** When
   the body has no criteria, derive candidates from the design prose —
   one per load-bearing commitment it makes, and never past it: a
   commitment the design does not make is a design decision to settle
   first, not a criterion to invent. When the body has them, split a
   bullet that bundles several checks one claim per bullet, split a
   bullet whose subject spans the two sections' classes one bullet per
   class, drop a bullet that restates the design prose without adding
   a checkable claim, and rewrite a bullet that names no artifact to
   name the file, section, or command it is about. Write the criteria
   you derived or reworked to a file under
   `.claude/tmp/orchestrate-ready-<N>/` for the closing approval below.
   The bullets of a `## Acceptance` section are criteria the body
   already has: moving each into the section its subject's file class
   names is the mechanical repair step 4 makes, listed in step 7 and
   outside the closing approval, and a moved bullet joins that file
   only when one of the reworkings above changes it.

   Write each agreed criterion into the acceptance section of
   `sdlc:orchestrate-readiness`'s grammar that its subject's file class
   names, and within that section into the sub-list that skill's
   sub-heading definitions name, so the writer and every reader agree
   by construction. Write every `### Mechanical` bullet in that skill's
   check-key vocabulary, never as a command; a criterion no key
   expresses goes under `### Semantic`. An issue that touches
   `plugins/<name>/` always gets `[version-bumped] <name>` as a
   mechanical criterion of the code and instruction Markdown section:
   every PR that changes a plugin bumps its version, and the generator
   makes a theorem of every criterion in that section.

   **Rework the files-affected section the same way.** Derive the
   list from the placement decisions settled with the user and from
   the tree: every path the design names or plainly has to touch,
   each tagged with one of the tags `sdlc:orchestrate-readiness`'s
   grammar defines for that section. A path the design does not reach
   is a design decision to settle, not a file to guess. When the body
   already has a list, check it against the design prose and the
   tree, and surface any path the prose reaches that the list omits
   and any bullet the check reported malformed. Write the tagged list
   to a file beside the criteria.

   **The closing approval** comes once every design gap has an answer.
   When `ready-rewrite-approval` is `ask`, put the files written above
   — the criteria and the files-affected list — to the user as one
   decision before step 4 rewrites the body, citing each as its
   evidence, with adopting them as written among its options. When it
   is `auto`, ask nothing: step 4 rewrites the body once
   `sdlc-decision pending` exits 0 for the issue, and prints the
   criteria and the file list it wrote.

   **If any gap from step 2 is still unresolved when the conversation
   ends** — the user deferred it, answered around it, or stopped
   replying — the issue is **not** orchestrate-ready, and inventing
   the answer yourself is the failure this skill exists to prevent.
   Do not flip the status: skip step 6 entirely, leave the status
   where it is, and skip any other step the conversation did not
   authorize (step 5's side-effect issues have no yes, and step 4's
   rewrite happens only if the user wants the settled decisions
   captured — a body rewritten around an open gap must not read as if
   the gap were closed). Go to step 7 and report which gaps remain
   open, that the issue is not ready, and that the status is
   unchanged.

4. **Rewrite the body in full.** Write the whole new body to a file
   under `.claude/tmp/orchestrate-ready-<N>/` and full-replace with
   it:

   ```text
   /issue-update <N> --body-file .claude/tmp/orchestrate-ready-<N>/body.md
   ```

   Integrate every decision **in place** — the body reads as one
   current spec written by someone who already knew the answers.
   Never append the decisions as an amendment section, and never
   leave superseded wording standing next to its replacement: an
   amendment layer is one of the gaps this skill exists to remove, so
   introducing one while resolving the others is self-defeating.

   The rewrite is also what enforces the readiness bar's exclusions,
   by removing rather than noting: every provenance sentence comes
   out, every sentence that fails
   "Outcome, not method" comes out and is restated as the outcome it
   was meant to produce, every mechanical gap is repaired, and a gap
   about an out-of-scope system becomes its one-sentence assumption.
   Each design gap is repaired as the user's answer to its decision
   says, and only so: a reference the bar excludes comes out, with the
   facts the answer says the body needs from the referenced document
   restated in the body in the present tense, and a dependency the
   answer confirms is created with
   `/issue-set-blocked-by <blocked> <blocker>`. The agreed acceptance
   criteria, and each bullet moved out of an `## Acceptance` section
   into the section its subject's file class names, go in as the
   acceptance sections, each with its two
   grouped sub-lists and each omitted when no agreed criterion is in
   its class, and the agreed
   files-affected section goes in as its tagged list, both in the
   shape `sdlc:orchestrate-readiness`'s grammar spells.

   Then run the check again. The rewrite loop ends when
   `/sdlc:orchestrate-readiness <N>` returns an empty gap list; a gap
   it still reports goes back to step 3, which handles it as it
   handles any gap.

5. **Create side-effect issues only on an explicit yes, per issue.**
   Where the discussion establishes work that belongs in another repo,
   name it, show the user the title and body you would file, and file
   it only after they say yes to that specific issue. One yes covers
   one issue; it does not carry to the next. Each field the user named
   no value for is filed as its `follow-up-issue-*` key calls for, per
   `skills/lib/sdlc-config.md`, and a field that file makes a question
   of its own is a decision, per "Putting a decision to the user", with
   values the target accepts for the field as its options. The user can
   decline it. Skipping the type passes no `--type`, and the issue gets
   whatever type `/issue-create` resolves; skipping the assignee files
   the issue unassigned, passing `--no-assignee`.

   - **In this repo** → `/issue-create --title "…" --body-file <path>`.
   - **In another repo** →
     `/issue-create <owner>/<repo> --title "…" --body-file <path>`,
     which applies that repo's own repo-config, or files a plain issue
     and says so when it has none. This is a write outside the current
     repository, which is why the explicit per-issue yes is the gate
     rather than a formality.

   Link the new issue back with a real edge, in whichever direction
   the work actually runs:
   `/issue-set-blocked-by <blocked> <blocker>` when the new issue is a
   prerequisite of the groomed one,
   `/issue-set-blocks <blocker> <blocked>` when it is the other way
   round. **Never** a closing keyword in either body — a closing
   keyword auto-closes the referenced issue on merge, and one aimed at
   an issue outside a branch's own set is precisely what the
   closing-keyword rule forbids.

6. **Set the status, then verify the write landed.** Skip this step
   whenever a gap from step 2 went unresolved (see step 3) or the
   check has not yet returned an empty gap list (see step 4) — the
   issue is not ready and the status stays where it is. The flip is a
   Kanban visibility aid for humans, not part of readiness: it runs
   only after the check passes, and it is still skipped wherever the
   `status` slot reports unconfigured, or the user picks leaving the
   status where it is, per "Status resolution" below.
   Otherwise resolve the
   orchestrate-ready status name per that section, then run, directly
   before the flip and whatever the check printed:

   ```bash
   sdlc-decision pending --issue <host>/<owner>/<repo>#<N>
   ```

   A non-zero exit means a design gap still waits on the user's answer:
   set no status, and report the issue as not ready, naming each
   problem its stderr names. On exit 0:

   ```text
   /issue-set-status <N> <status-name>
   ```

   Re-read the issue live afterwards with `/issue-view <N>` and
   confirm the status row shows the value you set. A mutation
   reporting success is not evidence the intended value landed; only
   the re-read is. Do not claim the flip until you have seen it.

7. **Final report.** State: what changed in the body (the substantive
   changes, not a diff), each gap the rewrite repaired and its repair,
   which
   side-effect issues you created and
   where, the status you set and that you confirmed it by re-reading,
   and the issue URL. When step 6 was skipped because a gap is still
   open, say instead that the issue is not ready, name the gaps still
   open, and say the status is unchanged. When it was skipped only
   because the `status` slot reports unconfigured, say the issue is
   ready and that the repo has no status to flip, and when the user
   picked leaving the status where it is, say the issue is ready and
   the status unchanged on that pick. Either way, never
   report an unflipped status as a success.

## Status resolution

Ask the `issues` namespace which status options exist:

```text
/issue-field-options status
```

Apply this rule to the option names it reports — the indented lines
under the slot's first line, which carries only the kind and any
`(default: …)`:

- A `Ready` option exists → use it.
- Otherwise a `Todo` option exists → use it.
- Otherwise → put it to the user as a decision, per "Putting a
  decision to the user", with the configured options that could mean
  orchestrate-ready as its options, and use the pick. The user can
  decline it: skipping leaves the status where it is, and step 6 sets
  none.
- When no configured option could mean orchestrate-ready, there is
  nothing to choose: treat the slot as unconfigured, below.

If it reports the `status` slot as unconfigured, there is nothing to
flip: say so plainly, deliver the groomed body, and stop rather than
inventing a status.

## Non-goals

- **Implements nothing.** No code edits, no branches, no PRs. The
  deliverable is an issue that an `issue-developer` can implement.
- **Does not set priority or size unasked.** You may flag a value that
  looks obviously wrong for what the issue turned out to be, as a
  decision per "Putting a decision to the user" with keeping it among
  its options, and change it only on the user's pick.
- **Never answers a design question silently.** An answer you invented
  and did not surface is indistinguishable, in the rewritten body,
  from one the user chose — and the implementer will build it either
  way. If a gap goes unresolved because the user did not settle it,
  the issue is not ready; say so and leave the status alone.
