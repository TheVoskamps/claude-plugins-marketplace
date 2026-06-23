---
name: gh-repo-scrub-history
description: "Rewrite a repo's entire git history to substitute one string with another across every commit via git-filter-repo --replace-text, then force-push. Purges leaked secrets/names/strings from history. Warns loudly (but does not refuse) on public repos. Prompts for the from/to strings when not passed, using any passed values as editable defaults."
---

You are running the `/gh-repo-scrub-history` skill. Your job is to
rewrite the **entire git history** of the **current repo** (the repo
`cd`-ed into when this skill was invoked) so that one string is
substituted with another across **every commit** in history, then
force-push the rewritten history to the remote.

This is the tool for purging a leaked secret, a name, or any string
that should not live in the repo's history. It is deliberately a
**history rewrite**, not a working-tree edit: a working-tree
substitution leaves the old value sitting in every prior commit, which
is useless for the leaked-secret case this skill exists to serve. The
whole point is that `git log -p`, `git show <old-sha>`, and a fresh
clone all stop containing the value.

The mechanism is `git filter-repo --replace-text`, which rewrites blob
content across all commits. Rewriting blobs changes every commit SHA
from the first rewritten commit onward, so the local history diverges
from the remote and the push is necessarily a **force-push**.

This skill is the pre-flip gate that `gh-repo-setup-public` (a separate
skill, tracked in issue #92) points at: scrub the history clean
*before* a private repo is ever made public. Normal use is therefore on
a **private** repo. Running it on a public repo is the break-glass case
— see "Posture" below.

Follow the steps in order. There are two explicit **halts** where you
wait for the user. Do not skip them.

---

## Inputs (both optional)

- **`from`** — the string to replace (the leaked/unwanted value).
- **`to`** — the replacement string. When the intent is redaction
  rather than substitution, a sentinel like `***REMOVED***` is the
  conventional `to` value (it matches `git-filter-repo`'s own default
  replacement text).

Resolution:

- If **both** are passed, use them as the **defaults** in the Halt #1
  prompt — the user confirms or edits them before anything runs. Passed
  values are never used unconfirmed.
- If **either** is omitted, **prompt** the user for the missing
  value(s) at Halt #1. Any value that *was* passed pre-fills its field
  as the editable default.
- `from` must be non-empty after confirmation. `to` may be empty
  **only if the user explicitly intends deletion** (replace the string
  with nothing); otherwise default an empty/blank `to` to the
  `***REMOVED***` sentinel and show that in the Halt #1 confirmation so
  the user sees what will be written.

Do not echo a `from` value that is itself a live secret more than
necessary; it has to appear in the Halt #1 confirmation (the user must
confirm exactly what is being scrubbed), but do not repeat it
gratuitously elsewhere in the conversation.

---

## Step 1: Pre-flight — repo root

Verify you are inside a git working tree:

```bash
git rev-parse --show-toplevel
```

Treat the path printed by this command as the **repo root** for the
rest of the skill. The skill operates on the repo the user invoked it
from. Do **not** assume `~/.claude` or any other path.

If the command fails (non-zero exit, "not a git repository"), abort
with:

> `/gh-repo-scrub-history` must be run from inside a git repository.
> The current directory is not a git working tree.

## Step 2: Pre-flight — local tooling

Verify `git-filter-repo` is installed locally:

```bash
command -v git-filter-repo
```

If it returns nothing (exit non-zero), abort with:

> `git-filter-repo` is not installed. Install it with
> `brew install git-filter-repo`, then re-run `/gh-repo-scrub-history`.

Do **not** attempt to install it yourself — the user runs
`brew install git-filter-repo` (host-integrity rule: no on-initiative
host-wide installs).

Also verify `gh` is authenticated (needed both to read the repo's
visibility in Step 3 and to push later):

```bash
gh auth status
```

If `gh` reports the user is not authenticated, abort and tell them to
run `gh auth login` first.

## Step 3: Pre-flight — repo visibility (posture branch)

Read the repo's visibility:

```bash
gh repo view --json visibility -q .visibility
```

- If the value is `PRIVATE`: this is the normal, intended use. Note it
  and continue.
- If the value is anything else (`PUBLIC`, `INTERNAL`): this is the
  **break-glass case**. Emit the loud warning below and continue — do
  **not** refuse. Warn, then let the user decide.

### Public-repo warning (break-glass)

Print this verbatim when visibility is not `PRIVATE`, before Halt #1:

```text
⚠️  WARNING: this repo is <visibility>, not private.

Rewriting history on a public repo is a break-glass action. If a secret
or sensitive string has been public, rewriting history helps but does
NOT fully un-leak it:

  - It may already be cached by GitHub, search engines, or the GitHub
    Archive / GH Archive datasets.
  - It may have been forked; forks keep the old history independently.
  - It may have been cloned, crawled, or scraped by third parties.
  - Old commit SHAs may still be reachable via the GitHub API for a
    while, and via anyone's existing clone indefinitely.

If a credential leaked publicly, ROTATE THE CREDENTIAL — that is the
only real remediation. This rewrite reduces casual exposure but is not
a substitute for rotation.

This skill will still proceed if you want it to.
```

Then continue to Halt #1. The warning informs; it does not block.

## Step 4: Halt #1 — confirm strings, posture, and the exact invocation

Resolve the `from` / `to` values per "Inputs" above (prompt for any
not passed; use passed values as editable defaults). Then build the
**exact** `git filter-repo` invocation and show it to the user for
explicit approval before anything runs.

The skill writes a single-rule replacement file in the sandbox and
points `git filter-repo` at it with `--replace-text`. The replacement
file format is one rule per line, `<from>==><to>`:

- A **literal** substitution is the default: `<from>==><to>`.
- When `to` is the redaction sentinel and the user did not give an
  explicit replacement, the rule is `<from>==>***REMOVED***`.
- When the user explicitly intends deletion (replace with nothing),
  the rule is `<from>==>` (empty right side).

> **Critical — never hand-write `#` comment lines into this file, and
> never strip-by-deny-list.** `git filter-repo --replace-text` does
> **not** skip `#` lines: a bare `#` line is parsed as the literal
> rule `# ==> ***REMOVED***`, which would corrupt every `#` in every
> file (shebangs, comments, Markdown headings). This is a known
> `git-filter-repo` behavior — the `--replace-text` parser treats every
> non-empty line as a rule and does not recognize `#` as a comment
> marker. This skill therefore writes a replacement file containing
> **only the single real rule line and nothing else** — no header, no
> comments, no blank lines. Do not add explanatory comments to the
> generated file.

Present this halt verbatim (filling in the resolved values):

```text
About to REWRITE THIS REPO'S ENTIRE GIT HISTORY.

  Repo:         <owner>/<short>   (<visibility>)
  Replace:      <from>
  With:         <to>              (or "(deleted)" when the rule is <from>==> )
  Rule written: <from>==><to>     (in a sandbox replacements file)

Exact command that will run, against a fresh mirror clone in the
sandbox:

  git filter-repo --replace-text <sandbox>/replacements.txt

This rewrites EVERY commit SHA from the first match onward. After the
rewrite I will show you the diff/stat, then ask SEPARATELY before
force-pushing. Consequences, accepted by design:

  - All commit SHAs change. Existing clones and forks are broken;
    collaborators must re-clone or hard-reset.
  - Open PRs built on the old SHAs will need to be recreated/rebased.
  - The force-push overwrites remote history and cannot be cleanly
    undone once others have fetched it.

Proceed with the rewrite? (y to continue, or tell me what to change)
```

Wait for explicit approval (`y`, `yes`, `go`, `do it`). If the user
wants to change `from`, `to`, or cancel, update and re-display this
halt — do not proceed without confirmation. This halt approves the
**rewrite**, not the push (the push has its own approval at Halt #2).

## Step 5: Perform the rewrite in a sandbox clone

Do the rewrite against a **fresh mirror clone in the sandbox**, never
against the user's working clone directly. Mirroring first means the
user's working repo is untouched until the explicit force-push at
Halt #2 — if anything looks wrong, the working clone and the remote
are both still intact.

All scratch work goes under `<repo-root>/.claude/tmp/gh-repo-scrub-history/`
— never `/tmp/`, never the home directory, never outside the repo.

```bash
# Capture the absolute repo root BEFORE building paths.
REPO_ROOT="$(git rev-parse --show-toplevel)"
SANDBOX="$REPO_ROOT/.claude/tmp/gh-repo-scrub-history"
mkdir -p "$SANDBOX"
WORK="$SANDBOX/scrub.git"
rm -rf "$WORK"
# A mirror clone carries all refs (branches + tags) so the rewrite
# covers the whole history, not just the current branch.
git clone --mirror "$REPO_ROOT" "$WORK"
```

Write the single-rule replacement file (exactly one line, no comments
— see the `#`-comment warning in Step 4). Use the `Write` tool to write
`<SANDBOX>/replacements.txt` containing only:

```text
<from>==><to>
```

Also use the `Write` tool to write a one-line needle file
`<SANDBOX>/needle.txt` containing exactly the `from` value (no trailing
rule syntax, no `==>`). Step 6's verification grep reads this file with
`git grep -F -f` so the leak-shaped `from` string is never interpolated
onto a shell command line:

```text
<from>
```

Then run the filter against the mirror clone. `--replace-text` defaults
to operating on all refs in the mirror, so every branch and tag is
rewritten.

Run this as **two separate steps** — a bare `cd` into the sandbox
mirror, then the bare `git filter-repo` command. Do **not** combine
them as `cd "$WORK" && git ...` (the `cd <path> && git` form trips the
harness's CVE-2025-59536 gate) or as a `( cd … ; … )` subshell:

```bash
cd "$WORK"
```

```bash
git filter-repo --replace-text "$SANDBOX/replacements.txt" --force
```

`--force` is required here: `git filter-repo` refuses to rewrite a repo
that is not a fresh, single-purpose clone, and the mirror clone in the
sandbox is exactly such a throwaway, so `--force` is the correct flag.
(It forces filter-repo to run against the already-cloned mirror; it is
unrelated to the later `git push --force`.)

## Step 6: Show what changed; report whether the string was found

Show the user the effect of the rewrite before any push. You are still
`cd`-ed into the sandbox mirror (`$WORK`) from Step 5, so these run as
bare commands; if a prior Bash call reset the cwd, re-run `cd "$WORK"`
first (its own Bash call, never `cd "$WORK" && git …`):

```bash
git log --oneline -n 20
```

Verify the string is actually gone from the rewritten history. Pass the
`from` value through a file and use `git grep -F -f` so the
leak-shaped string is never interpolated into the shell command line
(no quoting/escaping hazard, and the value stays off `ps` listings).
Feed the refs to `git grep` via `xargs` reading
`git rev-list --all` on stdin, so a repo with many refs cannot blow
`ARG_MAX`:

```bash
# Write the search needle to a sandbox file (Write tool, not echo) so
# the raw `from` value is never placed on a command line:
#   <SANDBOX>/needle.txt  ->  a single line containing exactly <from>
#
# Then search every ref. Prints NOTHING if the scrub worked. Any output
# means the string still survives somewhere (e.g. it appears in a
# path/filename, which --replace-text does not rewrite — only blob
# CONTENT).
git rev-list --all | xargs git grep -I -n -F -f "$SANDBOX/needle.txt" -- 2>/dev/null | head
```

Report to the user:

- Whether the string was found and replaced at all. If
  `git filter-repo` reports **no replacements made**, tell the user
  plainly: the string did not appear in any blob content. Possible
  reasons — it never existed in history, it was already scrubbed, or it
  exists only in a **filename/path** or a **commit message** (neither
  of which `--replace-text` rewrites; `--replace-text` is blob content
  only). Ask whether they want to stop or proceed anyway.
- The number of commits whose SHAs changed (the divergence point).

This step is read-only reporting. The next step is the destructive one.

## Step 7: Halt #2 — confirm the force-push

The mirror clone in the sandbox now has the rewritten history, but
**nothing has been pushed and the working clone is untouched.** Ask
explicitly before the force-push:

```text
The rewrite is done in the sandbox and the string is no longer in the
rewritten history. Nothing has been pushed yet.

Force-pushing will OVERWRITE the remote's history on all rewritten
branches and tags. This is destructive and breaks existing clones,
forks, and open PRs. It cannot be cleanly undone once others fetch it.

Force-push the rewritten history to origin now? (y to push, or no to
stop and leave the sandbox for inspection)
```

Wait for explicit `y`/`yes`/`push`. If the user declines, stop and
tell them the rewritten mirror is preserved at `<WORK>` for inspection;
do not delete the sandbox.

On approval, force-push all rewritten refs from the mirror clone to the
**real GitHub remote**.

`git clone --mirror "$REPO_ROOT"` set the sandbox's `origin` to the
user's *local working clone path*, not to GitHub. The push must
therefore be re-pointed at the true remote **before** any force-push —
otherwise it rewrites the local working clone instead of GitHub. Do
this in order, each as its own Bash call (never `cd "$WORK" && git …`,
never `git -C <path> …`):

First, read the real remote URL from the working clone:

```bash
cd "$REPO_ROOT"
```

```bash
REMOTE_URL="$(git remote get-url origin)"
```

Then enter the sandbox mirror and re-point its `origin` at that URL:

```bash
cd "$WORK"
```

```bash
git remote set-url origin "$REMOTE_URL"
```

Confirm the re-point landed on GitHub (not the local path) before
pushing — this guards against an empty/unset `REMOTE_URL`:

```bash
git remote get-url origin
```

Only once that prints the real GitHub URL, force-push all rewritten
refs to that explicit remote URL:

```bash
git push --force --mirror "$REMOTE_URL"
```

Pushing to the resolved `"$REMOTE_URL"` (rather than the bare name
`origin`) makes the target unambiguous even if the re-point above were
somehow skipped. `--mirror` pushes all rewritten branches and tags so
the remote matches the scrubbed history exactly.

## Step 8: Tell the user to refresh their working clone

After the force-push, the user's **working clone still has the old,
pre-rewrite history** (the rewrite happened in the sandbox mirror, not
the working clone). They must reconcile it:

```text
Force-push complete. The remote now has the scrubbed history.

Your working clone at <repo-root> still has the OLD history. Reconcile
it with:

    git fetch origin
    git reset --hard origin/<current-branch>

Tell any collaborators to do the same (or re-clone). Their old clones
and any forks still contain the old value until they do.

If a real credential leaked, ROTATE IT — the rewrite is not a
substitute for rotation.
```

Then clean up the sandbox **only if every step succeeded**:

```bash
rm -rf "$REPO_ROOT/.claude/tmp/gh-repo-scrub-history"
```

Leave the sandbox in place if any step from 5 onward failed (or if the
user declined the push at Halt #2), so it can be inspected.

---

## Halts and approval gates (summary)

The skill **must** halt and wait for explicit user confirmation at:

- **Halt #1 (Step 4)** — confirm the `from`/`to` strings, the posture
  (public-repo warning if applicable), and the exact `git filter-repo`
  invocation. Approves the rewrite.
- **Halt #2 (Step 7)** — confirm the force-push. Approves the
  destructive remote overwrite. This is a separate approval from
  Halt #1; "yes" at Halt #1 never implies the push.

---

## Hard constraints

- **It is a history rewrite, not a working-tree edit.** A working-tree
  substitution leaves the old value in every prior commit and does not
  serve the leaked-secret purpose. Always use
  `git filter-repo --replace-text` across all history.
- **Warn, do not refuse, on a public repo.** Step 3 prints the
  break-glass warning when visibility is not `PRIVATE`, then continues.
  The user decides; the skill does not block.
- **Show the exact command before running it; get approval before the
  rewrite (Halt #1) AND before the force-push (Halt #2).** Two separate
  approvals.
- **Never hand-write `#` comments into the replacement file**, and
  never feed filter-repo a file with comment/blank lines — `git
  filter-repo --replace-text` does not treat `#` as a comment marker,
  so bare `#` lines are parsed as literal rules and corrupt every `#`
  in the repo. Write exactly one rule line.
- **Do the rewrite in a sandbox mirror clone, never against the user's
  working clone.** The working clone stays intact until the explicit
  force-push, and is reconciled afterward (Step 8) with
  `git fetch && git reset --hard`.
- **SHA rewrite / force-push / broken clones & forks are accepted by
  design.** Call them out at both halts; do not block on them.
- **All scratch work goes under
  `<repo-root>/.claude/tmp/gh-repo-scrub-history/`** — never `/tmp/`,
  never the home directory, never outside the repo. Clean up on
  success; leave in place on failure or on a declined push.
- **Never install `git-filter-repo` yourself.** Step 2 aborts with the
  `brew install git-filter-repo` instruction; the user installs it.

---

## Out of scope

- **`git-filter-repo` installation.** The user installs it out-of-band
  (`brew install git-filter-repo`); Step 2 aborts if it is missing.
- **Filename / path scrubbing.** `--replace-text` rewrites blob
  *content* only. A secret that appears in a filename or directory name
  is not removed by this skill; Step 6 reports when the string survives
  for this reason. Path-based filtering (`--path`, `--invert-paths`) is
  a different operation, out of scope here.
- **Commit-message scrubbing.** `--replace-text` does not touch commit
  messages (`--replace-message` is a separate pass). Out of scope for
  this skill, which targets blob content.
- **Credential rotation.** The skill reminds the user to rotate a
  leaked credential, but rotating it is the user's responsibility and
  outside this skill.
- **Coordinating collaborators' re-clones.** The skill tells the user
  what to communicate (Step 8) but cannot force others to refresh their
  clones or forks.
- **Making the repo public.** That is `gh-repo-setup-public` (issue
  #92), which points at this skill as its pre-flip gate. This skill
  only scrubs; it does not change visibility.
