---
name: gh-repo-setup-public
description: "Promote a PRIVATE repo to genuinely PUBLIC: run the converge setup skills, re-assert the public posture (CODEOWNERS, conversation-resolution, issues/PRs open to outside contributors, no unexpected collaborators), add public-facing docs/community files, gate on history scrubbing, propose a clean rename, then flip visibility private -> public. The mirror skill is never run."
---

You are running the `/gh-repo-setup-public` skill. Your job is to
promote the **current repo** (the repo `cd`-ed into when this skill was
invoked) from **private** to genuinely **public**: flip its visibility,
rename it to a clean name, and nail down the public-appropriate posture.

This skill makes the **live repo itself** public. It is distinct from
`/repo-public-mirror-setup`, which publishes a filtered, read-only
*mirror* of a repo that stays private. The two are opposites — **this
flow must never run `/repo-public-mirror-setup`.** This skill assumes
no paired public mirror exists; retiring any mirror is the user's job
(out of scope).

Follow the steps in order. There are explicit **halts** where you wait
for the user. Do not skip them. The two consequential halts are the
**scrub gate** (Step 5) and the **visibility flip** (Step 8); each
requires its own explicit approval.

---

## Owner identity

This skill's public posture pins a single code-owner: **`@evoskamp`**
(whole-repo `* @evoskamp` CODEOWNERS). That handle is the canonical
owner for repos this skill promotes; do not substitute the inferred
repo owner login for it. If a future caller needs a different
code-owner, that is a deliberate edit to this skill, not an inference.

## Template payload (community files)

The community-file starters this skill installs — `LICENSE`,
`PATENTS`, `PRIOR_ART.md` — are **reused from the
`repo-public-mirror-setup` payload** rather than reinvented, per the
issue. They live as templates under
`${CLAUDE_PLUGIN_ROOT}/payload/repo-public-mirror-setup/`, following the
bundled-payload convention (see `${CLAUDE_PLUGIN_ROOT}/payload/README.md`
for the placeholder/render/existence-check contract). Treat that
directory as `$PAYLOAD` for the rest of this skill.

`README.md` and `CONTRIBUTORS` are **not** reused from that payload:
the mirror's versions carry a read-only banner and state "PRs are not
accepted", which is exactly wrong for a live public repo that *welcomes*
forks and PRs. This skill renders public-facing versions of those two
itself (Step 4), and reuses only the content-appropriate
`LICENSE` / `PATENTS` / `PRIOR_ART.md` starters.

Placeholders used by the reused templates:

- `__GH_OWNER_NAME__` — human owner name in the `PATENTS` /
  `PRIOR_ART.md` prior-art notice. Prompted from the user (cannot be
  inferred).
- `__RELEASE_DATE__` — public-release date in the `PATENTS` /
  `PRIOR_ART.md` prior-art notice. Use today's date by default; confirm
  with the user.

Render with simple string substitution (the
`${CLAUDE_PLUGIN_ROOT}/payload/README.md` reference recipe): read a
template with `Read`, replace each `__PLACEHOLDER__` with its resolved
value, and write the result with `Write`. Never write a rendered file
that still contains a `__...__` placeholder — abort per the
`${CLAUDE_PLUGIN_ROOT}/payload/README.md` "Resolving placeholder values"
rule if any remains.

---

## Step 0: Payload

The community-file template payloads this skill reuses ship with the
plugin at `${CLAUDE_PLUGIN_ROOT}/payload/repo-public-mirror-setup/`
(`$PAYLOAD`). The placeholder/render convention is documented in
`${CLAUDE_PLUGIN_ROOT}/payload/README.md`. If `$PAYLOAD` is missing,
abort with the standard `${CLAUDE_PLUGIN_ROOT}/payload/README.md`
existence-check message.

## Step 1: Pre-flight — repo root, auth, visibility

Verify you are inside a git working tree and capture the root:

```bash
git rev-parse --show-toplevel
```

Treat the path printed by this command as the **repo root** for the
rest of the skill. The skill operates on the repo the user invoked it
from. Do **not** assume `~/.claude` or any other path.

If the command fails (non-zero exit, "not a git repository"), abort
with:

> `/gh-repo-setup-public` must be run from inside a git repository.
> The current directory is not a git working tree.

Verify `gh` is authenticated (needed to read/edit settings, manage
collaborators, and flip visibility):

```bash
gh auth status
```

If `gh` reports the user is not authenticated, abort and tell them to
run `gh auth login` first (with `repo` scope and admin rights on the
target repo, since renaming and visibility changes require admin).

Read the repo's current visibility:

```bash
gh repo view --json visibility -q .visibility
```

- If the value is `PRIVATE`: this is the intended use. Note it and
  continue.
- If the value is `PUBLIC`: the repo is already public. Report that the
  visibility flip is already done, and ask whether the user still wants
  to re-assert the public posture (Steps 2–4) and/or propose a rename
  (Step 6). Do not re-flip. Skip the scrub gate (Step 5) and the flip
  (Step 8) — there is nothing private left to expose.
- If the value is `INTERNAL`: treat like `PRIVATE` for posture purposes
  but surface that the flip will be `internal -> public`; confirm the
  user intends a fully public repo before the Step 8 flip.

Capture the owner and short name for later steps:

```bash
gh repo view --json owner,name -q '.owner.login + "/" + .name'
```

## Step 2: Run the converge setup skills

Run the two idempotent converge skills against this repo. They are
**idempotent**, so just run them — do **not** add any "has this been
run before?" detection. **Do NOT** run `/repo-public-mirror-setup`.

1. Run `/gh-repo-setup-protection`. This converges the Security &
   Quality surface and the `protect-main` ruleset, including
   `require_code_owner_review: true` and
   `required_review_thread_resolution: true` — the conversation-
   resolution and code-owner-review requirements this skill also owns
   (Step 3 re-asserts them regardless).
2. Run `/gh-repo-setup-pr-automation`. This installs the PR-automation
   workflows.

Each skill applies its remote settings directly and reports its own
changes; let it. **Do not assume a sub-skill leaves files uncommitted
for this orchestrator to bundle** — that assumption is gone. A sub-skill
owns its own rendered files: it may render-and-commit them into its own
PR, or it may leave them uncommitted, and which it does is the
sub-skill's concern, not this orchestrator's. This orchestrator's job is
to **adapt** to whatever each sub-skill did (Step 2a).

If either skill aborts on a pre-flight (e.g. missing GitHub App identity
for PR automation), surface its abort verbatim and stop — the user
resolves it, then re-runs `/gh-repo-setup-public`.

### Step 2a: For each sub-skill, detect whether it produced a PR

After **each** sub-skill above returns, detect whether that sub-skill
**opened a PR** for its own rendered files, and adapt:

- **`/gh-repo-setup-protection`** opens a PR for its rendered files on
  the `gh-repo-setup-protection` branch (a single approval covers its
  commit, push, and PR; see that skill's Step 7). On a converged no-op
  run it opens none.
- **`/gh-repo-setup-pr-automation`** opens a PR for its rendered files on
  the `gh-repo-setup-pr-automation` branch (a single approval covers its
  commit, push, and PR; see that skill's Step 6b). On a converged no-op
  run (no file changes) it opens none. This same detect-and-adapt path
  covers it with no change here.

Detect a sub-skill's PR generically — do not hard-code one skill's
branch name. The sub-skill reports its PR URL when it opens one; you can
also confirm against the live list of open PRs and match the branch the
sub-skill is named after:

```bash
# Open PRs and their head branches; match the branch the sub-skill names
# itself after (e.g. gh-repo-setup-protection), or the URL the sub-skill
# reported.
gh pr list --state open --json number,url,headRefName,title
```

For each sub-skill **that produced a PR**, run the merge-decision prompt
(Step 2b). A sub-skill that produced **no** PR (a converged no-op run,
or a skill that does not yet open PRs) needs no such handling — there is
nothing to merge — so skip the prompt for it.

### Step 2b: Prompt to merge each sub-skill PR (proper merge, never blind)

For each detected sub-skill PR, ask the user whether this skill should
merge it now or leave it for the user:

```text
/<sub-skill> opened a PR for its rendered files:

  <PR URL>  (branch: <head-branch>)

  (m) Merge it now — I will use the repo's configured merge method and
      WAIT for required checks to pass before it merges.
  (l) Leave it — you will merge it yourself.
```

- **If the user chooses leave** (`l`): record the PR URL for the
  completion checklist (Step 9) and move on. Do not merge.
- **If the user chooses merge** (`m`): perform a **proper** merge —
  **never** a blind immediate merge. "Proper" means: respect the repo's
  configured merge method and do not merge until required checks pass.
  The repo's converged posture is merge-commit-only
  (`/gh-repo-setup-protection` Step 4e sets `allow_squash_merge=false` /
  `allow_rebase_merge=false`, leaving merge-commit), so use the merge
  method (`--merge`), and gate on checks via `--auto`:

  ```bash
  # Enable auto-merge with the repo's merge method; GitHub merges it
  # only once required status checks pass and review requirements are
  # met. This respects protect-main's required checks rather than
  # bypassing them.
  gh pr merge <PR number or URL> --merge --auto
  ```

  If the repo does not have auto-merge enabled for some reason (it is
  enabled by `/gh-repo-setup-protection` Step 4e), fall back to
  poll-checks-then-merge: wait for the PR's required checks to report
  success (`gh pr checks <PR> --watch`), then `gh pr merge <PR> --merge`.
  Either way, **wait for checks** — do not merge a PR with pending or
  failing required checks.

  Report the outcome: "merged (auto-merge enabled; will merge once checks
  pass)" or "merged" once it lands.

This detect-then-prompt-to-merge path is **generic** — it applies to any
sub-skill that produces a PR, present or future. Both
`/gh-repo-setup-protection` and `/gh-repo-setup-pr-automation` open their
own PRs today, and each flows through this same path with no change here.

## Step 3: Re-assert the public posture this skill owns

This skill is the **last word** on the settings that must be correct
for a public repo, regardless of what the setup skills left them at.
Double-ownership with `/gh-repo-setup-protection` is fine — re-assert
anyway so this skill is self-contained.

Most "keep control" guarantees are **free by default** on a public
repo: outside contributors are read-only. They can fork, open PRs (from
their fork), file issues, and comment, but **cannot** push to branches,
merge, or edit/close/relabel/assign issues — all of which need write
access this skill grants to nobody new. So this step mostly **verifies**
rather than sets.

### 3a. CODEOWNERS — whole-repo `* @evoskamp`

Ensure a `CODEOWNERS` file exists with a single whole-repo rule
assigning ownership to `@evoskamp`. The conventional location is
`.github/CODEOWNERS` (root and `docs/` are also valid GitHub
locations). Read whichever exists; if none does, write
`.github/CODEOWNERS`. The required content is exactly:

```text
* @evoskamp
```

If a `CODEOWNERS` exists with different content, report the difference
and converge it to `* @evoskamp` (this skill's posture is whole-repo
single-owner). Write the file uncommitted — the user reviews and
commits (global rule §0). Code-owner review is **required** via the
`protect-main` ruleset's `require_code_owner_review: true`, which
`/gh-repo-setup-protection` already set in Step 2; verify that rule is
present (read the ruleset back as that skill documents) and report if
it is not.

### 3b. Conversation resolution required before merge

Verify the `protect-main` ruleset's `pull_request` rule has
`required_review_thread_resolution: true` ("Require conversation
resolution before merging"). `/gh-repo-setup-protection` sets this in
Step 2; read the ruleset back and report `present`/`missing`. If
missing (e.g. the protection skill was skipped or an org rule stripped
it), re-assert it by PUTting the ruleset with the flag set, following
the protection skill's ruleset-converge shape — do not invent a new
ruleset.

### 3c. Issues enabled and open to outside contributors

Ensure Issues are enabled:

```bash
gh repo edit <owner>/<short> --enable-issues=true
```

On a public repo, issue **filing** and **commenting** are open to any
logged-in GitHub user by default — that is the desired posture. Leave
issue comments **open**: do **not** set an interaction limit. The
interaction-limit lever is blunt and would also block legitimate
issue-filing, which defeats the purpose of a public repo. Outside
users still **cannot** edit, close, relabel, or assign issues without
write access — those stay controlled for free.

### 3d. PRs open to outside contributors

PRs from forks are open to any user by default on a public repo;
nothing to set. Outside contributors open PRs from their own fork and
**cannot** push to this repo's branches or merge without write access.
No action beyond confirming the repo is not configured to forbid forks
(forking is on by default; do not disable it).

### 3e. Verify no unexpected outside collaborators

The real control check: confirm that no unexpected collaborators have
write (or higher) access, since write access is what would let an
outside party bypass every guarantee above. List direct collaborators
and their permission:

```bash
gh api repos/<owner>/<short>/collaborators \
  --jq '.[] | {login: .login, permission: .role_name}'
```

Report the full list to the user. Expected: the owner (`admin`) and any
intentional maintainers. **Do not remove anyone on your own
initiative** — flag any unexpected collaborator (especially `write`,
`maintain`, or `admin` roles held by accounts the user does not
recognize) and ask the user whether to remove them. Removing a
collaborator is a posture decision the user owns. This step **verifies**
and surfaces; it does not silently mutate the collaborator set.

## Step 4: Add public-facing docs and community files

Render or update the public-facing files below in the repo root (all
uncommitted — the user reviews and commits). The two that are reused
from the mirror payload (`LICENSE`, `PATENTS`, `PRIOR_ART.md`) are
content-appropriate; `README.md` and `CONTRIBUTORS` are written here
with **public-repo** wording, not the mirror's read-only wording.

### 4a. `README.md` — public contribution instructions

If `README.md` exists, **append** a public-facing "Contributing"
section rather than overwriting the existing content (preserve the
project's own README body). If it does not exist, create a minimal one.
The section tells outside contributors how to participate:

```markdown
## Contributing

This is a public repository. Contributions are welcome:

- **Fork** the repository and create a feature branch from the default
  branch.
- **Open a pull request** from your fork. PRs require a passing CI run,
  code-owner review (`@evoskamp`), and all review conversations
  resolved before they can merge.
- **File an issue** to report a bug or propose a change. Any logged-in
  GitHub user can open and comment on issues.

Outside contributors have read access: you can fork, open PRs from your
fork, and file/comment on issues. Push access, merging, and issue
triage are reserved for maintainers.
```

If the repo already has a CONTRIBUTING.md or a contribution section,
reconcile rather than duplicate — report what you found and converge to
the public-facing instructions above.

### 4b. `CONTRIBUTORS` — public-facing version

The mirror payload's `CONTRIBUTORS.template` says "Contributions are
not accepted in this mirror", which is wrong for a live public repo.
Write a public-facing `CONTRIBUTORS` instead:

```text
# Contributors

This is a public repository and contributions are welcome — see the
"Contributing" section of README.md for how to fork, open a pull
request, and file issues.

This file deliberately does not embed a frozen contributor list: that
data is reproducible from the repository's own history and would go
stale on every commit. To list contributors from the current history,
run:

    git shortlog -sne
```

### 4c. `LICENSE` — reuse the mirror payload

If the repo already has a `LICENSE`, leave it as-is and report it. If
it does not, render `$PAYLOAD/LICENSE` (GPL v3, no placeholders) to
`<repo-root>/LICENSE`.

### 4d. `PATENTS` and `PRIOR_ART.md` — reuse the mirror payload

For each of `PATENTS` and `PRIOR_ART.md`: if the repo already has the
file, leave it as-is and report it. If it does not, render the
corresponding `$PAYLOAD/PATENTS` / `$PAYLOAD/PRIOR_ART.md` starter,
substituting `__GH_OWNER_NAME__` (prompt the user) and `__RELEASE_DATE__`
(default today's date; confirm). After rendering, confirm no `__...__`
placeholder remains.

## Step 5: Halt — gate on history scrubbing

**This halt must clear before the visibility flip (Step 8).** Once a
repo is public, its history is exposed instantly and irreversibly:
GitHub caches, forks, crawlers, and the GH Archive dataset can all
capture it within minutes. Scrubbing **after** the flip does not
un-expose what was already public. So the scrub must happen **before**
the flip, not after.

Ask the user explicitly:

```text
Before this repo goes public, its ENTIRE git history becomes visible —
every commit, every diff, every old file version, forever (caches,
forks, crawlers).

Does this repo's history contain anything that must NOT be public?
For example:
  - leaked secrets / credentials / tokens (these must also be ROTATED)
  - private names, emails, or identifiers
  - internal-only content, customer data, or paths

  (y) Yes — history needs scrubbing first. I will STOP here.
  (n) No — history is clean; proceed to rename and flip.
```

- If the user answers **yes** (history needs scrubbing): **hard-stop.**
  Do not rename, do not flip. Point them at `/gh-repo-scrub-history`
  (issue #93) to rewrite history before exposure, and tell them to
  re-run `/gh-repo-setup-public` once the scrub is done:

  > Stopping before the visibility flip. Run `/gh-repo-scrub-history`
  > to rewrite the history (and ROTATE any leaked credential — a
  > rewrite is not a substitute for rotation), then re-run
  > `/gh-repo-setup-public`. The flip must not happen until the history
  > is clean, because going public exposes the unscrubbed history
  > immediately and irreversibly.

  This skill does **not** perform the scrub itself — scrubbing lives
  entirely in `/gh-repo-scrub-history`; this skill only gates on it.

- If the user answers **no** (history is clean): record the explicit
  confirmation and continue to Step 6. The flip in Step 8 is permitted
  only because the user has confirmed here that no scrub is needed.

Do not flip visibility until this gate is cleared with an explicit "no".

## Step 6: Propose a cleaned repo name

Propose a public-appropriate name by stripping private-signaling
suffixes from the current short name. Common suffixes to strip
(case-insensitive, including a leading `-`):

- `-private`
- `-source`
- `-mirrored-to-public`
- `-mirror`, `-internal`, `-source-of-truth`, and similar
  private/internal markers.

Compute the proposed new name, then show the rename as `old -> new` and
let the user accept or edit:

```text
Proposed rename (GitHub-side only):

  <owner>/<old-short>  ->  <owner>/<new-short>

Accept this name, give me a different one, or say "keep" to leave the
name unchanged.
```

If stripping the suffixes leaves the name unchanged (no private-
signaling suffix present), say so and offer to keep the current name.
Wait for the user's choice. The rename is **GitHub-side only** — see
Step 7.

## Step 7: Rename the repo on GitHub (if the user chose a new name)

If the user accepted a new name in Step 6, rename the repo on GitHub:

```bash
gh repo rename <new-short> --repo <owner>/<old-short>
```

This is a **GitHub-side rename only**. Do **not** touch the user's
local checkout, remote, or directory. After the rename, tell the user
to fix their local remote themselves:

```text
Renamed on GitHub: <owner>/<old-short> -> <owner>/<new-short>

Update your local clone's remote yourself (GitHub auto-redirects the
old URL for a while, but update it to be safe):

    git remote set-url origin git@github.com:<owner>/<new-short>.git

Renaming the local directory is also up to you; this skill does not
touch your local checkout.
```

If the user chose "keep", skip the rename and continue.

## Step 8: Halt — flip visibility private -> public

This is the irreversible, consequential action. It runs **only after**
the scrub gate (Step 5) cleared with an explicit "no" and the rename
(Steps 6–7) is settled. Confirm explicitly:

```text
About to flip <owner>/<short> from <current-visibility> to PUBLIC.

This exposes the repo and its ENTIRE git history to the world,
immediately and irreversibly (caches/forks/crawlers). You confirmed
earlier that the history needs no scrubbing.

Posture re-asserted:
  - CODEOWNERS: * @evoskamp (code-owner review required)
  - Conversation resolution required before merge
  - Issues enabled, open to outside contributors (no interaction limit)
  - PRs open to outside contributors (read-only; no write granted)
  - Collaborators verified (no unexpected write access)

Flip to PUBLIC now? (y to flip, or no to stop)
```

Wait for explicit `y`/`yes`. On approval, flip:

```bash
gh repo edit <owner>/<short> --visibility public --accept-visibility-change-consequences
```

The `--accept-visibility-change-consequences` flag is required by `gh`
to perform a private→public change non-interactively.

If the user declines, stop and leave the repo private — all the
posture/docs work from Steps 2–4 is still valid and uncommitted for the
user to review.

## Step 9: Print the completion checklist

After a successful flip, print:

```text
Repo is now PUBLIC.

Done on GitHub:
  - Visibility flipped to public (<owner>/<short>)
  - <renamed to <new-short> | name kept>
  - Protection + PR-automation converged (gh-repo-setup-protection,
    gh-repo-setup-pr-automation)
  - Posture verified: CODEOWNERS * @evoskamp, conversation-resolution
    required, issues/PRs open to outside contributors, collaborators
    checked

Sub-skill PRs:
  - gh-repo-setup-protection:  <merged | auto-merge enabled | left: URL | none>
  - gh-repo-setup-pr-automation: <merged | auto-merge enabled | left: URL | none>

Uncommitted in this repo (review and commit when ready):
  - .github/CODEOWNERS                 (if added/changed)
  - README.md                          (Contributing section)
  - CONTRIBUTORS, LICENSE, PATENTS, PRIOR_ART.md   (as needed)
  - any files a sub-skill left uncommitted (those that do not open a PR)

Next steps:
  1. Review the diff:    git status && git diff
  2. Commit and push the docs/community files and CODEOWNERS.
  3. Merge any sub-skill PR you chose to leave (Step 2b).
  4. Update your local remote if you renamed:
       git remote set-url origin git@github.com:<owner>/<new-short>.git
  5. If you retired a paired public mirror, do that by hand — this skill
     does not touch mirrors.
```

---

## Halts and approval gates (summary)

The skill **must** halt and wait for explicit user confirmation at:

- **Step 2b — sub-skill PR merge prompt.** For each sub-skill that
  produced a PR, the user chooses merge-now (proper merge, gated on
  required checks) or leave-for-me. A sub-skill that produced no PR has
  no prompt.
- **Step 5 — scrub gate.** A hard-stop if the user says history needs
  scrubbing; points at `/gh-repo-scrub-history`. The flip cannot
  proceed without an explicit "no, history is clean".
- **Step 6 — propose-rename.** The user accepts, edits, or keeps the
  name before any rename.
- **Step 8 — visibility flip.** The irreversible private→public change.
  A separate approval from every prior step; "yes" earlier never
  implies the flip.

When the repo is already `PUBLIC` at Step 1, the scrub gate and the
flip are skipped (there is nothing private left to expose); the rename
and posture re-assertion are still offered.

---

## Hard constraints

- **Never run `/repo-public-mirror-setup`.** This skill makes the live
  repo public; the mirror skill publishes a read-only *mirror* of a
  repo that stays private. They are opposites. Running the mirror skill
  here is always wrong.
- **Run the two converge skills unconditionally and without "has it
  run?" detection.** `/gh-repo-setup-protection` and
  `/gh-repo-setup-pr-automation` are idempotent — just run them
  (Step 2).
- **Adapt to each sub-skill's PR; never assume uncommitted bundling.**
  A sub-skill owns its own rendered files. This orchestrator does **not**
  assume a sub-skill leaves files uncommitted for it to bundle. After
  each sub-skill runs, detect whether it produced a PR (Step 2a) and, if
  it did, prompt the user to merge-now or leave (Step 2b). Never suppress
  a sub-skill's PR with a flag. The detection is generic — it covers any
  sub-skill that produces a PR (both `/gh-repo-setup-protection` and
  `/gh-repo-setup-pr-automation` do so today).
- **Merge a sub-skill PR only with a proper merge, never blind.** When
  the user chooses to have this skill merge a sub-skill PR, respect the
  repo's configured merge method (merge-commit, per the converged
  posture) and **wait for required checks to pass** — `gh pr merge
  --merge --auto`, or poll-checks-then-merge. Never an immediate blind
  merge that bypasses `protect-main`'s required checks.
- **Scrub before flip, never after.** The Step 5 scrub gate must clear
  with an explicit "no" before the Step 8 flip. Going public exposes
  the unscrubbed history immediately and irreversibly; scrubbing after
  the flip does not un-expose it. This skill only gates on scrubbing —
  the scrub itself lives in `/gh-repo-scrub-history` (issue #93).
- **CODEOWNERS owner is `@evoskamp`.** Whole-repo `* @evoskamp`, with
  code-owner review required via the `protect-main` ruleset. Do not
  substitute the inferred repo-owner login.
- **Leave issue comments open — no interaction limit.** The blunt
  interaction-limit lever would also block legitimate issue-filing.
  Outside users are read-only by default and cannot triage issues
  without write access, which is the real control.
- **Verify collaborators; never remove one on your own initiative.**
  Step 3e lists collaborators and flags unexpected write access, but
  removal is a posture decision the user owns.
- **Reuse the mirror payload for `LICENSE` / `PATENTS` / `PRIOR_ART.md`;
  write public-facing `README.md` / `CONTRIBUTORS` yourself.** The
  mirror's README/CONTRIBUTORS say "PRs not accepted" — wrong for a
  live public repo.
- **GitHub-side rename only.** Step 7 renames on GitHub and tells the
  user to fix their local remote/directory themselves. The skill never
  touches the local checkout.
- **Never write or commit this skill's own files for the user.** Steps
  3–4 write *this skill's* files (CODEOWNERS, README section, community
  files) uncommitted; the user reviews the diff and commits (global rule
  §0). This is about the files this orchestrator renders itself — it does
  not govern a sub-skill's own files, which the sub-skill owns and may
  commit into its own PR (handled by Step 2a/2b). Remote settings (issues
  toggle, visibility flip, collaborator listing) are applied directly
  because they are remote state, not file edits — and each consequential
  remote change has its own halt.
- **Never edit anything outside the current repo.** File writes go
  under `<repo-root>/` (`.github/CODEOWNERS`, root `README.md`,
  `CONTRIBUTORS`, `LICENSE`, `PATENTS`, `PRIOR_ART.md`). Templates are
  **read** from `${CLAUDE_PLUGIN_ROOT}/payload/repo-public-mirror-setup/`
  (read-only). Scratch work, if any, goes under
  `<repo-root>/.claude/tmp/gh-repo-setup-public/`, never `/tmp/`.

---

## Out of scope

- **History scrubbing itself.** Lives in `/gh-repo-scrub-history`
  (issue #93). This skill only gates on it (Step 5) and points at it;
  it never rewrites history.
- **Mirror handling.** This skill assumes no paired public mirror
  exists. Retiring any mirror (`<repo>-public` and its plumbing) is the
  user's job, done by hand.
- **Local checkout cleanup.** The rename (Step 7) is GitHub-side only.
  Fixing the local remote URL and directory name is the user's job.
- **Credential rotation.** If the scrub gate surfaces a leaked
  credential, the user rotates it (and runs `/gh-repo-scrub-history`);
  the skill reminds but does not rotate.
- **The converge skills' own scope.** GHAS toggles, Dependabot, CodeQL,
  the `protect-main` ruleset, and the PR-automation workflows are owned
  by `/gh-repo-setup-protection` and `/gh-repo-setup-pr-automation`;
  this skill runs them (Step 2) but does not re-implement them.
