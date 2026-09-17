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

## Invocation

```text
/sdlc:orchestrate-ready <issue-number>
```

Exactly one issue number per invocation, with or without a leading
`#`. If `$ARGUMENTS` is empty, ask which issue to groom before
proceeding. If it names more than one, ask the user which single issue
to groom — grooming is a conversation per issue, and interleaving two
of them loses track of which decision belongs to which.

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
   after.** Invoke `/sdlc:orchestrate-readiness <N>`; its verdict and
   its gap list are what you report. Open with the verdict, so the
   user knows the size of the conversation before reading the detail.
   Then list the gaps as a numbered list, each with a **proposed
   default answer** — your best reading of what the issue intends,
   stated as a proposal.

   An issue that is already `ready` still gets step 6: the status flip
   is the deliverable even when the body needs no edit.

3. **Discuss the gaps as plain conversation, one topic at a time.**
   Do not present a multiple-choice form for an open design question:
   a form caps the answer space at what you thought of and assumes
   your framing is right, which is exactly what is in question here.
   Ask one plain question, reflect back what you hear in the user's
   own words, and move to the next topic once it is settled. Your
   proposed defaults are proposals; the user decides.

   **The acceptance section is a gap like any other.** When the
   body has none, derive candidate criteria from the design prose —
   one per load-bearing commitment it makes, and never past it: a
   commitment the design does not make is a design decision to settle
   first, not a criterion to invent. When the body has one, split a
   bullet that bundles several checks one claim per bullet, drop a
   bullet that restates the design prose without adding a checkable
   claim, and rewrite a bullet that names no artifact to name the
   file, section, or command it is about. Either way, put the
   resulting list to the user with the other decisions before step 4
   rewrites the body.

   Group that list into the two sub-lists the acceptance section of
   `sdlc:orchestrate-readiness`'s grammar defines, splitting it by
   that skill's sub-heading definitions so the writer and every reader
   agree by construction. An issue that touches `plugins/<name>/`
   always gets the plugin version bump as a mechanical criterion:
   every PR that changes a plugin bumps its version, and the generator
   makes a theorem of every criterion.

   **The files-affected section is a gap the same way.** Derive the
   list from the placement decisions settled with the user and from
   the tree: every path the design names or plainly has to touch,
   each tagged with one of the tags `sdlc:orchestrate-readiness`'s
   grammar defines for that section. A path the design does not reach
   is a design decision to settle, not a file to guess. When the body
   already has a list, check it against the design prose and the
   tree, and surface any path the prose reaches that the list omits
   and any bullet the check reported malformed. Put the tagged list to
   the user with the other decisions before step 4 rewrites the body.

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
   by removing rather than noting: every reference the bar excludes
   and every provenance sentence comes out, a fact the body needs
   from a referenced document is restated in the body in the present
   tense, and a dependency the prose stated is created with
   `/issue-set-blocked-by <blocked> <blocker>`. The agreed acceptance
   section goes in as its two grouped sub-lists, and the agreed
   files-affected section goes in as its tagged list, both in the
   shape `sdlc:orchestrate-readiness`'s grammar spells.

   Then run the check again. The rewrite loop ends when
   `/sdlc:orchestrate-readiness <N>` returns an empty gap list; a gap
   it still reports goes back to step 3 as a topic, and a malformed
   files-affected bullet is repaired here without a conversation.

5. **Create side-effect issues only on an explicit yes, per issue.**
   Where the discussion establishes work that belongs in another repo,
   name it, show the user the title and body you would file, and file
   it only after they say yes to that specific issue. One yes covers
   one issue; it does not carry to the next.

   - **In this repo** → `/issue-create --title "…" --body-file <path>`.
   - **In another repo** → `/issue-create` files into the current
     repo only, so there is no skill for this. File it with
     `gh issue create --repo <owner>/<repo> --title "…"
     --body-file <path>`. This is a write outside the current
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
   only after the check passes, and it is still skipped where the repo
   has no board, per "Status resolution" below. Otherwise resolve the
   orchestrate-ready status name per that section, then:

   ```text
   /issue-set-status <N> <status-name>
   ```

   Re-read the issue live afterwards with `/issue-view <N>` and
   confirm the status row shows the value you set. A mutation
   reporting success is not evidence the intended value landed; only
   the re-read is. Do not claim the flip until you have seen it.

7. **Final report.** State: what changed in the body (the substantive
   changes, not a diff), which side-effect issues you created and
   where, the status you set and that you confirmed it by re-reading,
   and the issue URL. When step 6 was skipped, say instead that the
   issue is not ready, name the gaps still open, and say the status is
   unchanged — never report an unflipped status as a success.

## Status resolution

Read `.issues/repo-config.md` →
`github-project.fields.status.options`:

- A `Ready` option exists → use it.
- Otherwise a `Todo` option exists → use it.
- Otherwise → ask the user which of the configured options means
  orchestrate-ready, and use their answer.

If `.issues/repo-config.md` is missing, abort with: "This repo has
no `.issues/repo-config.md`. Run `/repo-config` to create one." (the
same wording the full reader contract uses for its "File missing"
case, so the namespace's abort messages stay consistent even though
this skill doesn't consume the whole contract).

If the repo has no `github-project:` block, or the block has no
`status` slot, there is nothing to flip: say so plainly, deliver the
groomed body, and stop rather than inventing a status.

## Non-goals

- **Implements nothing.** No code edits, no branches, no PRs. The
  deliverable is an issue that an `issue-developer` can implement.
- **Does not set priority or size unasked.** You may flag a value that
  looks obviously wrong for what the issue turned out to be, and
  change it only if the user agrees.
- **Never answers a design question silently.** An answer you invented
  and did not surface is indistinguishable, in the rewritten body,
  from one the user chose — and the implementer will build it either
  way. If a gap goes unresolved because the user did not settle it,
  the issue is not ready; say so and leave the status alone.
