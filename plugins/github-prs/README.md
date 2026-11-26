# github-prs

Skills for the operations a GitHub pull request goes through: open it
as a draft, read it, fetch its diff, list the files it changes, list
the PRs a branch has opened, review it, comment on it, replace its
body, flip it between draft and ready for review, report whether it can
be merged, enumerate its merge conflicts, and link it to the issues it
closes.

Each skill runs a script of the same name that ships with the plugin.
The script makes the `gh` call, and a verb that changes a PR reads the
PR back afterwards and fails when the change is not there, so a success
means GitHub holds what was asked for.

The plugin works with GitHub only, github.com and GitHub Enterprise
hosts alike. It has no support for any other source-control service.

## Requirements

- `gh`, authenticated for every host you address.
- `git`, `jq` and `curl` on `PATH`.
- The `git-tools` plugin, which `/pr-create` and `/pr-link-issue`
  invoke to read the issue set out of a branch name.
- For `/pr-create` only, a `.issues/repo-config.md` carrying
  `default-pr-target-branch` and `issue-link-prefix`.

## Naming a PR

Every verb that takes a PR takes it as one argument, resolved against
the repository the checkout's remote names:

| Form | PR |
| --- | --- |
| `N`, `#N` | PR N in the current repository |
| `repo#N` | in `repo` under the current repository's owner, on its host |
| `owner/repo#N` | in that repository, on the current repository's host |
| `host/owner/repo#N` | in that repository, on that host |
| `https://host/owner/repo/pull/N` | the same as `host/owner/repo#N` |

Anything else, an issue URL included, is a usage error reported before
anything is sent to GitHub. A form that names a repository sends every
call to that repository on that host, so a verb can address a PR of a
repository other than the one you are in.

A PR number is unique only within its repository. The **canonical
reference**, `host/owner/repo#N`, names the same PR from any checkout
on any host, and `/pr-view <PR> --ref` prints it for a PR given in any
form. It is taken from the repository the PR lives in, so a PR opened
from a fork is named by its base repository, never by the fork.

A message that names the PR spells it `#N` when you named no
repository, and by its canonical reference otherwise.

## Exit statuses

A status means the same thing whichever verb returned it:

| Exit | Meaning |
| --- | --- |
| 0 | the verb did what it says |
| 1 | a command the verb ran failed; that command's own error is on stderr, above a line naming the command and its status |
| 2 | a usage error; nothing was sent to GitHub |
| 3 | the verb's own negative outcome: a change that did not land, a PR that is not open, a merge state GitHub never finished computing |
| 4 | `.issues/repo-config.md` is missing or lacks a key the verb reads |
| 126 | bash: a command the verb ran was not executable |
| 127 | bash: a command the verb ran was not found |
| 128+N | killed by signal N |

A failed `gh` or `git` call always surfaces as 1, never as that tool's
own status. Each verb's section below names the statuses it can return
beyond 0, 1 and 2, and what they mean for that verb.

After an exit 3 from a verb that posts or writes, look at the PR before
running the verb again: the status says the read-back did not match,
which is not proof that nothing was written, and a second
`/pr-comment` leaves two comments when the first landed after all.

## Bodies travel by file

`/pr-comment` and `/pr-update` take their text as `--body-file <path>`,
and `/pr-review-submit` accepts that form too. A body full of backticks
and `$` spelled on a command line is read by the shell before the verb
sees it; a file reaches GitHub as written. The verbs never modify the
file.

A body may hold a literal `\u00XX` escape, such as the six characters
`\u0001`. The verbs store it and read it back unchanged.

## One PR, one issue set

A PR delivers one or more issues implemented on one branch, and the
branch name encodes that set. `/pr-create` and `/pr-link-issue` write
closing keywords only for members of it: a keyword aimed at a parent or
a related issue would close that issue when the PR merges.

Both take the issues you pass as a claim and check it against the
branch name through `/git-tools:git-issues-from-branch`:

- A number you pass that is outside the branch's set gets no closing
  line, and the report names it.
- A member of the branch's set you leave out stays unclosed, which is
  how a deliberately deferred issue is kept open. `/pr-create` names
  the deferred issue in the body it writes.
- When the claim and the branch cannot be reconciled, `/pr-create`
  opens no PR and `/pr-link-issue` leaves the body untouched, and each
  reports both sets.

Each issue gets a line of its own, `Closes #<issue>`. GitHub links only
a reference that carries a keyword immediately before it, so
`Closes #196, #201` links `#196` and silently leaves `#201` unlinked.
The keyword belongs in the PR body: there it both links the PR in the
issue's Development sidebar and closes the issue on merge to the
default branch, where a keyword in a commit message closes the issue
without linking it.

`/pr-closing-issues` and `/pr-link-issue` read those lines back with
one recognizer. An issue counts as closed only when a closing keyword,
as a whole word optionally followed by a colon, is followed by
whitespace and then immediately by a reference to the PR's own
repository: `#N`, `repo#N`, `owner/repo#N`, `host/owner/repo#N`, or the
issue's URL. That is deliberately stricter than GitHub's own linker: a
bare number, `GH-N`, a word between the keyword and the reference, or a
reference to another repository counts as not closed. A line the
recognizer misses therefore costs one extra `Closes` line from
`/pr-link-issue`, and never a missing one.

## Skills

| Skill | Purpose |
| --- | --- |
| `/pr-create <issue>… <branch>` | Open a draft PR for a branch, closing its own issue set |
| `/pr-view <PR> [--ref \| --json <fields> [--jq <expr>]]` | Print a PR: a fixed dump, its canonical reference, or named fields |
| `/pr-diff <PR>` | Print a PR's full diff |
| `/pr-files <PR>` | List every file a PR changes |
| `/pr-list --head <branch> [--state <state>]` | List the PRs opened from a head branch |
| `/pr-review-submit <PR> --verdict <verdict> <body>` | Post one review carrying a verdict and a body |
| `/pr-comment <PR> --body-file <path>` | Post one comment from a file |
| `/pr-update <PR> --body-file <path>` | Replace a PR's whole body with a file |
| `/pr-ready <PR>` | Mark a draft PR ready for review |
| `/pr-draft <PR>` | Convert a ready PR back to a draft |
| `/pr-ready-to-merge <PR>` | Report an open PR's merge readiness |
| `/pr-merge-conflicts <PR>` | Enumerate a PR's merge conflicts with its base |
| `/pr-link-issue <PR> <issue>…` | Make the PR body close every issue given |
| `/pr-closing-issues <PR>` | Report which issues the PR body closes |

### `/pr-create <issue>… <branch>`

Opens a pull request from `<branch>` as a **draft**, against the base
branch `default-pr-target-branch` names in `.issues/repo-config.md`.
The body is a summary followed by one closing line per issue, spelled
`Closes <issue-link-prefix><issue>`, which is `Closes #<issue>` on
GitHub. Issues are given as `N` or `#N`, space-separated, and
`<branch>` is the last argument. "One PR, one issue set" above says
which issues get a line.

Every PR starts as a draft so that it cannot merge, and so cannot close
its issues, until someone marks it ready.

The verb then reads the PR back and checks that it is a draft on that
base and head carrying that body. Stdout is the PR's URL.

- **Exit 3** — the PR did not land as asked: not a draft, the wrong
  base or head, or a different body. Also returned when `gh` reported
  success but printed no PR URL, in which case a PR may exist all the
  same. Stderr says which.
- **Exit 4** — `.issues/repo-config.md` is missing, or lacks one of the
  keys the verb reads.

### `/pr-view <PR> [--ref | --json <fields> [--jq <expr>]]`

Reads one PR.

- With no flag, prints a fixed dump: the canonical reference, title,
  state and draft flag on one line, then the URL, the author, the head
  and base branches, a blank line, and the body verbatim.
- With `--ref`, prints the canonical reference alone.
- With `--json <fields>`, prints exactly the fields named, as
  `gh pr view --json` spells them. `--jq <expr>` reduces that JSON with
  a jq expression, and a string result prints without quotes.

`--ref` and `--json` exclude each other, and `--jq` needs `--json`.

### `/pr-diff <PR>`

Prints the PR's full unified diff, as `gh pr diff` produces it.

### `/pr-files <PR>`

Lists every file the PR changes, one line each, in the order GitHub
lists them:

```text
<changeType>\t<additions>\t<deletions>\t<path>
```

`\t` is a tab. `<changeType>` is GitHub's word for the
change: `ADDED`, `DELETED`, `RENAMED`, `COPIED`, `MODIFIED` or
`CHANGED`. A PR that changes nothing prints nothing.

Use this rather than `/pr-view <PR> --json files` whenever the whole
list matters: that field returns the first 100 files and silently
stops, where this verb pages until GitHub reports no further page.

### `/pr-list --head <branch> [--state <state>]`

Lists the PRs opened from one head branch as a JSON array, one object
per PR carrying `number`, `title`, `state`, `headRefName`,
`baseRefName`, `mergedAt`, `closedAt` and `url`. `--state` is `open`,
the default, `closed`, `merged` or `all`. An empty array means no PR
matched, which is a normal answer and not an error.

The match is by branch **name**, not by commit. A branch deleted and
recreated under the same name matches the PRs of both lives, so "this
branch has a merged PR" does not show that the branch's current commits
were merged; compare the commits before deleting a branch on that
evidence.

### `/pr-review-submit <PR> --verdict <verdict> <body>`

Posts a **single** review carrying both a verdict and a body, so one
review raises one notification. The body is given in exactly one form,
inline as the last argument or as `--body-file <path>`; both forms work
with every verdict, and GitHub caps a review body at 64 KB.

The verdict is one of GitHub's own review actions. It decides the
action, the first line of the posted body, and the review state:

| `--verdict` | Body's first line | Review state |
| --- | --- | --- |
| `approve` | `APPROVED` | `approved` |
| `request_changes` | `CHANGES_REQUESTED` | `changes_requested` |
| `comment` | `COMMENTED` | `commented` |

The posted body is that verdict line, a blank line, then your text.

**Reviewing your own PR.** GitHub refuses both `approve` and
`request_changes` from a PR's author. When GitHub answers with that
refusal, the verb posts the same body as a comment review instead of
failing. The body still opens with the verdict you asked for, but the
review's state is `commented`, so GitHub counts no approval and no
blocking review whatever the body says. The verb learns this from
GitHub's refusal rather than by comparing logins, and any other failure
of the post stays a failure.

Stdout is one line naming the PR, the verdict requested, the review
state actually created, and which body form carried it. Read the state
there rather than assuming it from the verdict.

- **Exit 2** — the usage errors include a missing, repeated or unknown
  `--verdict`, and both body forms or neither. Stderr names which, and
  nothing is posted.
- **Exit 3** — the review did not land as posted: no new review
  appeared, or the newest one carries another state or another body.
  The check reads the newest review on the PR whoever left it, so a
  review someone else posts in the same moment fails it too.

### `/pr-comment <PR> --body-file <path>`

Posts one comment whose text is the file's, then reads that comment
back by the id GitHub returned and compares its text with the file,
trailing newlines aside. Stdout is the comment's URL.

- **Exit 2** — the usage errors include a path that is not a readable
  file.
- **Exit 3** — GitHub named no comment, or the comment it named carries
  different text. Stderr says which.

### `/pr-update <PR> --body-file <path>`

Replaces the PR's **whole** body with the file's contents, then reads
the body back and compares it with the file, trailing newlines aside.
Nothing of the old body survives, closing lines included, so start from
the current body, which `/pr-view <PR> --json body --jq .body` prints.
Stdout is one line naming the PR and the file.

- **Exit 2** — the usage errors include a path that is not a readable
  file.
- **Exit 3** — the body GitHub holds differs from the file.

### `/pr-ready <PR>`

Marks a draft PR ready for review, then reads it back. GitHub does not
merge a draft, so this is the point at which the PR becomes mergeable.
A PR that is already ready is left as it is, so the verb is safe to run
more than once. Stdout is `PR <PR> is ready for review`.

- **Exit 3** — the PR still reads as a draft.

### `/pr-draft <PR>`

Converts a ready PR back to a draft, then reads it back. Use it when a
PR that looked ready turns out to need more work and must not merge
meanwhile. A PR that is already a draft is left as it is. Stdout is
`PR <PR> is now a draft`.

- **Exit 3** — the PR still reads as ready.

### `/pr-ready-to-merge <PR>`

Reports whether an open PR can be merged, and changes nothing. "Ready
for review" is only the draft flag: it says nothing about whether the
branch is current with its base, merges cleanly, or passes its required
checks. This verb reads the fields that do:

```text
PR <PR>: mergeable <MERGEABLE|CONFLICTING>, mergeStateStatus <STATE> — <meaning>
reviewDecision: <REVIEW_REQUIRED|APPROVED|CHANGES_REQUESTED|(none)>
checks running: <none, or one indented line per entry>
checks not green: <none, or one indented line per entry>
```

| `mergeStateStatus` | Meaning |
| --- | --- |
| `CLEAN` | mergeable |
| `UNSTABLE` | mergeable; non-required checks failing |
| `HAS_HOOKS` | mergeable; a pre-receive hook is pending |
| `BEHIND` | the branch is behind its base |
| `DIRTY` | the branch has merge conflicts with its base |
| `BLOCKED` | required checks or reviews are not satisfied |
| `DRAFT` | the PR is a draft |
| `UNKNOWN` | still computing after every retry |

A state the table does not name is printed verbatim with no meaning
attached.

`BLOCKED` names no cause: a missing required review, a failing required
check and a required check still running all report it. The review
decision and the two check lists are there to tell those apart.
`reviewDecision` is `(none)` when the base requires no review. A check
is **running** when it has not reported yet, which is neither a pass
nor a failure; it is **green** when it completed as `SUCCESS`,
`SKIPPED` or `NEUTRAL`, and green checks are not listed; every other
check is **not green**. GitHub does not say which checks are required,
so each list holds every check in its class, required or not.

`mergeable: UNKNOWN` on an open PR means GitHub is still computing the
merge. The verb reads again after 10 s and once more after a further
30 s, announcing each wait on stdout first, so a wait is
distinguishable from a hang:

```text
PR <PR>: merge state still computing, attempt 2 of 3 — waiting 10 s.
```

- **Exit 3** — either the PR is not open, and stderr names the state it
  is in, or the last read still returned `UNKNOWN`, and stdout is the
  block above reporting `UNKNOWN`. A closed or merged PR is refused
  without a retry because GitHub stops computing merge state once a PR
  closes, so it would report `UNKNOWN` forever.

### `/pr-merge-conflicts <PR>`

Lists the files and hunks in which a PR conflicts with its base, which
GitHub's `DIRTY` does not say. Run it from inside a git checkout; it
need not be a checkout of the PR's repository.

The verb adds a detached throwaway worktree at the PR's head under
`.claude/worktrees/`, merges the base there without committing,
collects the conflicts, then aborts the merge and removes the worktree
on every exit, a failed run included. It resolves, commits and pushes
nothing, and your working tree and index read the same before and
after.

What it does change in your clone is fetched refs. For a PR of the
checkout's own repository it fetches from `origin`, so the `origin/*`
refs of the head and base move. For a PR of another repository it
fetches from that repository's `https://` URL, authenticating as `git`
does for that URL, into refs under `refs/pr-merge-conflicts/` that it
deletes on every exit, so no `origin/*` ref changes.

The first line of the report names the PR, its head and its base. Then
comes either a line saying the trial merge is clean, or the conflicting
files, one per line, followed by a `=== <file>` section per file
holding that file's conflicting hunks verbatim.

**A rebase inverts the side labels.** The hunks carry a merge's labels:
`<<<<<<< HEAD` is the PR's head, and the lower side is the base. If you
fix the conflict by rebasing the branch, the same conflict shows up the
other way round, because during a rebase `HEAD` is the base and the
lower side is the branch commit being replayed. Resolve each rebase
stop by reading the content, never by the label this report showed:
keeping "the HEAD side" in a rebase drops the branch's change.

### `/pr-link-issue <PR> <issue>…`

Makes the PR body close every issue given, appending only what is
missing. Issues are given as `N` or `#N`, space-separated. "One PR, one
issue set" above says which of them get a line.

Issues the body already closes are left alone. For the rest, the verb
keeps the existing body verbatim, appends one `Closes #<issue>` line
per issue after a blank line, writes the body and reads it back. When
the body already closes every issue it writes nothing and prints
`PR <PR> already closes <issues>`, so running it twice adds nothing.
Stdout names the issues already closed and the lines appended.

- **Exit 3** — the body GitHub holds is not the body written.

### `/pr-closing-issues <PR>`

Prints, on one line, the issues the PR body closes, in ascending order:

```text
PR #224 closes issues 196, 201, 206
```

A body with no closing line is a normal answer:

```text
PR #224 closes no issues
```

"One PR, one issue set" above says what counts as a closing line. The
verb reports what the body says and does not check it against the
branch's issue set.
