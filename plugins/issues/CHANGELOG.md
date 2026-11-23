# issues changelog

## 0.19.1 — 2026-11-22

An issue body that contains a literal `\u00XX` escape, such as the six
characters `\u0001`, is now read as stored. `gh` rewrites such an escape
into caret notation on every read, `\u0001` reading back as `\^A`, and
the verbs read bodies through it:

- `/issue-update --body-file` no longer reports a landed body holding
  such an escape as `body requested but not set`.
- `/issue-update --append` and `--prepend` no longer rewrite such
  escapes in the existing body when they write it back.
- `/issue-view` prints such escapes as the issue stores them.

The GitHub backend now needs `curl` on `PATH`, beside `gh` and `jq`: it
reads an issue body from GitHub's REST API with `curl`, using the token
`gh auth token` prints for the issue's host. A body read that answers
with anything other than a JSON object aborts the verb.

## 0.19.0 — 2026-11-22

`/issue-view` prints the pull requests that close the issue, in a
`closed-by:` row directly under `Parent:`. Until now nothing in the
block said whether a PR for the issue was already open or had already
merged.

```text
Parent:     #12 Parent title
closed-by: #60 (MERGED), #61 (OPEN)
```

- Each pull request whose closing reference names the issue is listed
  as its reference and its state, `OPEN`, `CLOSED` or `MERGED`,
  comma-separated. Closed and merged ones are listed too, and one in
  another repository prints with that repository in its reference.
- The row reads `closed-by: none` when no pull request closes the
  issue.
- Under the Jira backend it reads `closed-by: unsupported`, since Jira
  carries no pull request that closes a work item.

A script that reads the block by position should expect the new row
between `Parent:` and the blank line above `Sub-issues:`.

## 0.18.0 — 2026-11-21

`/issue-list` can list a project board across repositories. Until now
it listed one repository's slice of the board that repository's
repo-config names, so a view holding issues from several repositories
could not be listed whole, and a board could be listed only from a
repository configured for it. `--project` and a project or view URL
name the board directly instead.

```text
/issue-list [<owner> | <owner>/<repo>] [--project <number|url>]
            --status <name> [--view <name|number|url>]
            [--assignee <login>]... [--unassigned] [--limit <n>]
```

- `<owner> --project <number>` lists that board of an organization or
  a user across every repository on it. The board and the view alone
  decide which repositories appear.
- `<owner>/<repo> --project <number>` lists that board in one
  repository, which needs no repo-config.
- `--project` also takes a board's URL,
  `https://<host>/orgs/<owner>/projects/<n>` or the `users/` form,
  which supplies the owner and makes the positional optional.
- `--view` also takes a view's URL, `.../projects/<n>/views/<v>`, which
  supplies owner, board and view, so a listing runs from any directory,
  inside a checkout or not.
- With `--project`, a single-word positional is an owner, never a
  repository. A repository under the current owner is then written
  `<owner>/<repo>`.

When `--project` or a URL names the board:

- `--status` names one option of the board's own single-select field
  called `Status`, and the status column prints the issue's value in
  that field. A board with no such field cannot be listed this way.
- No repo-config decides whether the run proceeds. A checkout with no
  repo-config, a Jira-tracked one or an invalid one lists the board all
  the same; its `issue-link-prefix` still spells the references to the
  current repository's issues.
- Each line's priority and size come from the slots of the issue's own
  repository's repo-config, read from that repository's default branch.
  When that repository has no usable repo-config, they come from the
  board field named `Priority` or `Size`, and print `-` when the board
  has none.

The run stops, printing no line, when `--project <number>` has no
owner to look under, when a URL's owner or board disagrees with the
positional or with `--project`, when `--view <url>` and `--project`
name different boards, when the owner has no board of that number, and
when the board has no single-select `Status` field. Outside a checkout,
a single-word positional with nothing naming a board stops too: there
it can only be an owner, and an owner can hold many boards.

Without `--project` or a URL, a listing is what it was.

## 0.17.0 — 2026-11-19

`/issue-list` lists the project board's open issues in one repository
at one status, in the order they should be worked. It is the one verb
that takes no issue reference, for a caller that has none until the
board gives it one.

```text
/issue-list [<owner>/<repo>] --status <name> [--view <name-or-number>]
            [--assignee <login>]... [--unassigned] [--limit <n>]
```

- `--status` is required and names one option of the configured
  `status` slot, matched case-insensitively. The slot must be a
  single-select board field. The filter is keyed on that field's own
  name on the board, so a status field called something other than
  `Status` works.
- `--view` names a view of the board by name or number, and adds the
  view's filter to the list's.
- `--assignee`, repeatable, keeps issues assigned to any of the named
  logins, and `--unassigned` keeps issues assigned to no one. With
  both, an issue matching either is listed.
- `--limit` prints at most that many lines, counted after ordering.
- Every filter runs on GitHub; the verb drops nothing GitHub returns.
- Lines follow the board's position order. With a `--view` that sorts,
  they follow the view's sort fields in order and direction: ties keep
  position order, a single-select field sorts by its options' order,
  and an issue with no value in a field sorts last. A view sorting by
  a field other than a number, single-select, text, title, date or
  iteration field is refused, naming the field.
- Each line is tab-separated: reference, status, priority, size, count
  of open blockers, assignees, title.
- A leading `<owner>/<repo>` lists another repository's issues under
  that repository's own repo-config and board. An issue of the current
  repository still prints with the current repository's
  `issue-link-prefix`, and any other in the shortest form that names
  its repository.
- The verb does not support `issues: Jira`: it stops with the fixed
  Jira message, and there is no Jira procedure to follow instead.
- The run stops, printing no line, when the repo-config has no
  `github-project:` block or no single-select `status` slot, when
  `--status` names no option of the slot, when `--view` matches no
  view — the message lists the board's views — and when the board or
  the status field no longer resolves.

Every verb now prints a same-owner repository whose name is spelled
exactly as the current repository's `issue-link-prefix` as
`owner/repo#N`. Its `repo#N` read back as an issue of the current
repository. `/issue-create <repo>` reads the local `issue-link-prefix`
for this, and for nothing else.

The abort for a repo-config with no `github-project:` block now names
`/issues:repo-config`.

## 0.16.0 — 2026-11-17

`/issue-close --reason` sets the reason an issue is closed with, so a
duplicate or a won't-do is no longer recorded as completed.

- `--reason completed` and `--reason not-planned` close the issue with
  that reason. `--reason duplicate-of <issue>` closes it as a duplicate
  and records which issue it duplicates; the two need not share a repo.
- Without the flag nothing changes: the issue closes with GitHub's
  default reason.
- An issue already closed another way is reopened and closed again with
  the requested reason, since a close changes nothing on a closed
  issue. One already closed as requested is left alone.
- The report gains a `reason:` line read back from GitHub, and the verb
  exits non-zero when the reason or the duplicate target did not land.
- An unknown reason, a missing `duplicate-of` target, and a target that
  is not an issue or is the issue being closed are all refused before
  the comment is posted.

A malformed issue reference is now a usage error before any `gh` call,
in every verb that takes one, `/issue-create --parent` included. A
checkout whose repository `gh` cannot resolve used to report that
failure instead.

- One case waits for a read: `/issue-create <repo> --parent` with a
  reference that has no `#` and ends in a digit. Only the target
  repository's `issue-link-prefix` can make that one valid, so it is
  judged once that prefix is read, and still exits 2.
- An `issue-link-prefix` must now be `#`, empty, or a valid repository
  name: ASCII letters, digits, `.`, `_` and `-`, at most 100
  characters. Any other is a config error in every verb that reads the
  repo-config, the local one or another repository's, and
  `/repo-config` refuses to write it.
- A non-ASCII letter in an `issue-link-prefix`, or in the repository
  name, owner or host of a reference, is now refused under every
  locale. A UTF-8 locale could let one through before.

## 0.15.0 — 2026-11-17

`/issue-create --no-assignee` files an issue with no assignee, in one
write.

- Without the flag nothing changes: an absent or empty `--assignee`
  still resolves the default assignee, so until now an unassigned issue
  took a second write to remove it.
- With the flag no default is resolved and no user-config is read for
  one, so a user-config that would abort the lookup does not stop the
  create.
- The summary's assignee line reads `none (--no-assignee)`.
- Passing it with `--assignee` is a usage error, raised before anything
  is created.

## 0.14.1 — 2026-10-25

Filing or updating an issue no longer fails on a board with an auto-add
workflow.

- When the workflow adds the issue first and GitHub answers `Content
  already exists in this project`, the verb re-reads the issue, up to 5
  times with a 5-second wait before each read, and sets its slots on
  the board's own item.
- `/issue-create` and the slot setters get the same handling.
- If the item never appears, the verb aborts with GitHub's error and
  says so. Any other refusal of the add aborts at once, as before.

## 0.14.0 — 2026-10-19

The size `/issue-create` estimates now reads the acceptance sections.

- It counts the bullets of `## Code and instruction Markdown acceptance`
  and `## Documentation acceptance` together, and falls back to numbered
  task lists when a body has neither.
- An issue counts as documentation-only when its code section is absent
  or holds only a `[version-bumped]` bullet. Only a body with neither
  section is judged by its wording.

## 0.13.1 — 2026-10-11

Internal documentation change: the repo-config reference no longer
restates the branch-name shape. Behavior is unchanged.

## 0.13.0 — 2026-10-08

`/issues:issue-branch-prefix` prints the literal prefix for an issue
branch, so a caller no longer has to ask for it.

- It prints the repo's `issue-branch-naming-prefix` mode and the prefix
  that mode resolves to for this user.
- `initials` and `name` take their value from the new
  `branch-prefix-initials` and `branch-prefix-name` keys. The repo-level
  user-config wins over the user-global one, and an empty value falls
  through to the other scope.
- It aborts on an unknown mode, on a key unset in both scopes, and on a
  value containing `/` or whitespace.
- `/issues:user-config` and `/issues:global-user-config` offer both keys.
- It works in Jira-tracked repos too, since the prefix has nothing to do
  with the tracker.

## 0.12.0 — 2026-10-07

Every issue verb now acts on an issue in any repository, on any host.
Most verbs previously took only a number in the current repository.

- Each issue operand, and `/issue-create --parent`, accepts `N`, `#N`,
  `repo#N`, `owner/repo#N`, `host/owner/repo#N` or the issue's `https://`
  URL, so a reference copied from a verb's output or a browser works.
- Only the operand repository's own repo-config governs the verb. A
  checkout with no config, or one tracked in Jira, no longer stops work
  on another repository's issues.
- An operand in a Jira-tracked repository, or one at an unsupported
  schema version, aborts before the issue is read.
- Without a repo-config in the target, a setter aborts naming the
  repository and `/issue-view` prints no slot rows.
- A pull request is refused by name, whether given as a `pull` URL or as
  a number that turns out to be one.
- Repository references are validated per part, by what GitHub allows an
  owner and a name and DNS allows a host. A single-dash argument is now
  an operand rather than an unknown flag.
- `@default-assignee` on an issue in another repository resolves from
  the user-global user-config only.

## 0.11.0 — 2026-10-06

`/repo-config` and `/user-config` now work in a checkout on a GitHub
Enterprise host, where their lookups used to go to github.com.

- A new `issues-discover` script makes the interviews' board, field,
  issue-type and viewer lookups on the repository's own host.
- A token missing a required scope is reported with the scope and host.
- When `/user-config` cannot tell who owns the repo, it offers both a
  tracked `.gitignore` entry and `.git/info/exclude` without recommending
  either.

## 0.10.0 — 2026-10-04

The verbs now work in a checkout on a GitHub Enterprise host. Every
`gh` call goes to the host of the repository it acts on, where host-less
calls used to reach `gh`'s default host and fail.

- `/issue-create` and `/issue-field-options` name a target repository as
  a leading positional argument: `repo`, `owner/repo`, `host/owner/repo`
  or its `https://` URL. `--repo` on either is now a usage error.
- `/issue-field-options` also takes `--all`.
- Printed references use the shortest form that resolves back. A related
  issue under the same owner now prints as `repo#N`.
- The blocked-by verbs accept every printed reference form.

## 0.9.0 — 2026-09-28

Every GitHub-backed verb now runs a bundled script instead of having the
model assemble `gh` and GraphQL calls. The verbs need `gh` and `jq`, and
run under the bash 3.2 macOS ships. Jira-tracked repos stay on the prose
path.

- Every write is re-read, and the verb exits non-zero when the value did
  not land. That includes a label or assignee GitHub silently dropped
  from `/issue-update` or `/issue-create`: the report still prints.
- `/issue-create --repo <owner>/<repo>` reads the target's repo-config
  from its default branch. Without one it files a plain issue with a
  `note:` line. A cross-repo default assignee comes from the user-global
  user-config only.
- `/issue-field-options` gains `--repo` and reports each slot's default.
- Verbs now abort on a repo-config whose slot default the slot would
  refuse, or whose number bounds are not integers with `min` at most
  `max`. `/repo-config` writes through `repo-config-write`, which refuses
  such a draft and leaves any existing file untouched.
- Paged reads now run to the end of the list.

## 0.8.0 — 2026-09-26

`/issue-field-options` reports what a field slot accepts, so a caller
choosing a value no longer parses the repo-config. The status-option
read arrives here from `sdlc`'s `/sdlc:orchestrate-ready`.

- It prints a slot's kind and option names in configured order, or
  `min:` and `max:` for a number slot, and every slot when none is named.
- A skipped or missing slot prints as unconfigured and exits zero.
- It reads only the config, so it runs on either backend with no board
  and no `acli`.
- Verbs on a Jira repo now name the `jira:` block in their aborts, not
  the `github-project:` one.
- `/issue-create` prints its warnings in a fixed order.

## 0.7.0 — 2026-09-23

The blocked-by edge verbs accept `owner/repo#N` as well as `N` and `#N`
for either operand, so an edge can join issues in different repositories.
Before, both operands resolved in the current repo, which failed or
landed on the same-numbered local issue. Output prints an issue in
another repo as `owner/repo#N`. On Jira the form aborts before any `acli`
call.

## 0.6.0 — 2026-09-17

When estimating size, `/issue-create` now counts the bullets of a body's
`## Files affected (floor)` section, matching that exact heading.

## 0.5.0 — 2026-09-09

`default-assignee` is now tracker-neutral: a GitHub login on GitHub, an
Atlassian account identifier on Jira.

- `/issue-update --add-assignees` and `--remove-assignees` accept the
  literal token `@default-assignee` and echo who it resolved to.
- When neither user-config sets the key, the fallback is the current
  identity on either backend: the authenticated GitHub user, or the
  account `acli jira auth status` reports.

## 0.4.0 — 2026-09-04

The README is now a user manual: what the verbs do, what they need
first, a first run, and what the plugin leaves to others. Runbook steps
also stop restating GraphQL argument names, which had led to mutations
that failed on input shape.

## 0.3.1 — 2026-08-27

Adds a README for people editing the plugin, explaining why the config
paths are literals. Behavior is unchanged.

## 0.3.0 — 2026-08-24

The config files moved out of `.claude/rules/`, where they were loaded
into every session and subagent on every turn.

- The new paths are `.issues/repo-config.md`, `.issues/user-config.md`
  and `$XDG_CONFIG_HOME/issues/user-config.md`.
- There is no fallback. A repo still on the old path gets the missing-file
  abort naming `/repo-config`, so move or regenerate its config when you
  install this version. Nothing deletes the old file.
- `/user-config` ignores the new path in the tracked `.gitignore` and
  removes a stale `.claude/rules/user-config.md` entry.

## 0.2.10 — 2026-08-21

Corrects the `/issue-create` steps that set a native issue field, whose
wording led to a mutation GitHub rejected for a missing `issueFields`
argument. Pointers between the plugin's documents now quote their target
headings verbatim.

## 0.2.9 — 2026-08-20

Internal documentation change: drops a stray reference from a note in
the shared library. Behavior is unchanged.

## 0.2.8 — 2026-08-17

Internal documentation change: the repo-config reference and interview
stop naming individual consumers. Behavior is unchanged.

## 0.2.7 — 2026-08-12

Skill examples use the placeholder `octocat` instead of a real handle
that was not an assignable login.

## 0.2.6 — 2026-08-11

Documentation change: the repo-config reference records that no skill
branches on `source-control` today, though the field stays required.
Behavior is unchanged.

## 0.2.5 — 2026-08-03

Documents that a `gh api graphql` field value may be a shell variable,
so a captured node ID need not be pasted back as a literal. The query
document and field names must stay literal.

## 0.2.4 — 2026-08-03

Documents that a branch carrying a batch of issues names them all in
`issue-branch-naming-prefix`'s branch shape. Behavior is unchanged.

## 0.2.3 — 2026-07-30

The file `/repo-config` generates now has only a heading and a line
saying to re-run `/repo-config` rather than hand-edit. Its front-matter
and tracker block are unchanged.

## 0.2.2 — 2026-07-30

Trims the prose body of the file `/repo-config` generates. Its
front-matter and `github-project:` block are unchanged.

## 0.2.1 — 2026-07-30

Wording change: the docs describe the multi-issue orchestrator instead
of naming a command outside this plugin. Behavior is unchanged.

## 0.2.0 — 2026-06-22

Issue-tracker verbs over a GitHub or Jira backend, dispatched on the
`issues:` value in the repo's config, which lived under `.claude/rules/`.

- `/issue-create`, `/issue-view`, `/issue-view-tree`, `/issue-sub-list`,
  `/issue-update`, `/issue-comment` and `/issue-close`.
- Setters for status, priority, size and type.
- Parent, child, blocked-by and blocks edges, set and unset from either
  end.
- `/repo-config`, `/user-config` and `/global-user-config` interviews.
- `/issue-add` and `/issue-set-importance` as deprecated aliases.
