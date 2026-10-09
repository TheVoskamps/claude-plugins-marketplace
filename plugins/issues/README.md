# issues

Issue-tracker verbs — create, view, update, link, and set fields on an
issue, and report what a field accepts — over a GitHub or Jira
backend, dispatched on the `issues:` value in the repo's config. The
skills under `skills/` are the roster. On GitHub each verb runs a
bundled script of the same name under `bin/`; `skills/lib/` holds what
the verbs share that is not code — the repo-config schema and the Jira
path.

## Why you would want it

An issue's interesting metadata is not reachable from a single `gh`
flag. Its type, its status/priority/size fields, its parent, its
sub-issues and its blocked-by edges are Projects V2 GraphQL mutations
addressed by node ID, and the IDs are per-repo. A session that files
or updates an issue without these verbs looks those IDs up again every
time and has to get each mutation's input shape right first try.

These verbs move that lookup to setup time and record the answers in
the repo's config. Afterwards `/issue-create` files a fully configured
issue in one invocation, `/issue-view` prints one issue's body, fields
and relationships without a follow-up command, and the relationship
verbs set and clear edges by issue reference from whichever end you
are thinking from. The flags do not change when the tracker does: the same
verbs serve a Jira backend, and only the calls underneath differ.

Recording the IDs was not enough on its own. A verb whose procedure is
prose is carried out by a model, and a model handed a `gh api graphql`
recipe paraphrases it: it skips the shared library it was told to
open, writes the mutation from training with ad-hoc IDs, and bypasses
the config, the canonical error wording and the post-write check. Even
a faithful reading assembles each call by hand from a template. So on
GitHub the procedure is a script the skill runs, and the prose says
only when to run it.

## What it needs first

- **A git working tree.** Every verb resolves the repo root itself and
  reads the config from there.
- **`.issues/repo-config.md`, written by `/issues:repo-config`.** This
  is the one prerequisite with a setup step: the interview asks which
  VCS and tracker the repo uses, discovers the project board's field
  and option IDs, and writes them down. A verb acting on an issue here
  reads the file and aborts pointing back at `/repo-config` when it is
  missing, when its `schema-version` is older than the reader requires,
  or when a slot's `default:` is a value the slot itself would refuse —
  an option name not among its `options:`, or for `kind: number` a
  bound or default that is not an integer with `min` at most `max`.
  That last abort comes whichever slot the verb wanted, because the
  file is invalid as a whole. A verb whose every operand names another
  repository reads that repository's config instead and never opens
  the local file, so a checkout with none, or one tracked in Jira, does
  not stop work on another repo's issues. The config verbs write config
  rather than requiring it. It is team-shared and committed, so one
  person runs the interview per repo.
- **An authenticated CLI for the backend.** `gh` and `jq` for the
  GitHub backend — the scripts run under the bash 3.2 that macOS ships
  and call nothing else; `acli` for Jira, plus the `issues-jira`
  plugin, which is where the Jira command templates live.

A project board is **optional**, and the two ways of reaching project
metadata degrade differently without a `github-project:` block:
`/issue-create`'s `--type`, `--priority`, `--size` and `--status` warn
and skip the flag, so the issue is still filed, while the dedicated
`/issue-set-type`, `/issue-set-priority`, `/issue-set-size` and
`/issue-set-status` abort instead, pointing at `/repo-config`, because
setting the field is the whole run there and skipping it would leave
nothing to do. A slot the config declares `kind: skip`, or leaves out
of `fields:`, is one the repo does not track: a verb that would set it
exits zero with a warning, and `/issue-field-options` reports it as
unconfigured. Everything that touches only the issue itself — bodies,
comments, labels, assignees, parents and blocked-by edges — works
unchanged.

Personal defaults — `default-assignee`, for one — are optional too,
and live in a user-config file written by `/issues:user-config` (this
repo) or `/issues:global-user-config` (this machine). Neither file
has to exist, and a key set to an empty value in one scope falls
through to the other. The one personal value a verb insists on is the
branch prefix: a repo whose config sets `issue-branch-naming-prefix`
to `initials` or `name` needs `branch-prefix-initials` or
`branch-prefix-name` in one of the two scopes before
`/issues:issue-branch-prefix` can print a prefix.

## Getting started

Run the interview once, then use the verbs:

```text
/issues:repo-config
```

Commit the `.issues/repo-config.md` it writes. A typical run after
that files an issue, links it under its parent, and reads it back:

```text
/issue-create --title "Cache resolved field IDs" --body-file body.md
              --type Bug --priority High --status Ready
/issue-set-parent 412 380
/issue-view 412
```

Values for a select-style slot are human-readable names — `High`,
`Bug`, `In progress` — matched case-insensitively against the options
the config records. A name that matches nothing is an error, never a
guess. A slot the config declares as `kind: number` takes an integer
within its bounds instead; `skills/lib/issue.md` carries the per-kind
rules.

When a caller has to **choose** a value rather than set one it already
holds — a grooming skill deciding which status means "ready", say —
`/issue-field-options` reports each slot's kind and option names in
the config's own order, so nothing outside this plugin parses
`.issues/repo-config.md` to learn what a slot accepts:

```text
/issue-field-options status
```

It reads only the config and writes nothing, so it runs the same under
either backend, without a project board, and without `acli`. Each
slot's line carries its `default:` when it declares one, so a caller
that lets a value default can say which value that will be.

## Every GitHub verb is a script

Each GitHub-backed skill runs an executable of the same name under
`bin/`, on the agent's `PATH` once the plugin is enabled, and its
SKILL.md says only when to run the verb, which arguments to pass, and
what the output means. No SKILL.md carries a `gh` command or a GraphQL
document — the interviews included, whose live lookups run through
`issues-discover` — and a caller elsewhere in the marketplace reaches
an issue through the skill rather than spelling a `gh issue` call of
its own.

The scripts share one sourced helper, `bin/lib/issues-common.sh`, and
it is the only statement of the GitHub calls: the repo-config read and
its checks, operand parsing, node-ID and field/option ID resolution,
the GraphQL documents, the write path for each slot kind, the
relationship edges, and the error catalogue. A script reports a failure
by calling a catalogue entry and never spells a message of its own. A
usage error exits 2 before anything is sent; every other failure exits
non-zero with one catalogue line on stderr.

A verb that changes an issue **re-reads what it set** and exits
non-zero when the re-read does not show it, so a skill never has to
tell its caller to verify. For `/issue-update` and `/issue-create` that
covers a label or assignee GitHub accepted and silently dropped: the
report still prints, and the exit status says the write did not land.
When a create step fails after the issue exists, stderr names the
issue, its URL and the steps that completed; nothing is rolled back.
The select-style setters skip a write whose value is already set;
`/issue-set-status` writes without that pre-check.

A script that reaches GitHub serves the GitHub backend only. Under
`issues: Jira` it exits non-zero with one fixed message before any
`gh` call, and the verb is carried out from the prose Jira path in
`skills/lib/issue.md`, which for that reason keeps the resolution rules
and error wording the scripts otherwise own. The surface is the same
either way; only the calls underneath differ. The refusal is keyed on
the tracker, not on whether a `gh` call is made: `issue-field-options`
reads only the config and still refuses Jira, because a slot's shape
there is the `jira:` block's. The branch prefix is the one value with
no tracker in it at all, so `issue-branch-prefix` reads a Jira-tracked
repo exactly as a GitHub one; refusing would have left such a repo
with no way to resolve it.

Every verb acts in the repository its operand names: `/issue-create`
and `/issue-field-options` take a leading positional `<repo>`, and
every other verb's issue operand carries its repository in the
reference itself. The repo-config that governs the run is the
operand's repository's own: for another repo the script reads that
repo's `.issues/repo-config.md` from its default branch through the
read-only contents API and reads nothing from the current repo's,
since the target's alone governs which tracker it is on and what a
slot accepts there. A target whose config is present and supported is
used exactly as a local one; one tracked in Jira stops the verb with
the fixed Jira message, and one at an unsupported schema version
aborts with the canonical schema-version wording, in each case before
an issue is read or written. A target with none degrades by verb:
`/issue-create` files a plain issue — title, body, labels, assignees —
with a `note:` line saying project fields were skipped,
`/issue-field-options` reports every slot there as unconfigured,
`/issue-view` prints the issue with no slot rows, a setter aborts
naming the repository, and everything that touches only the issue
itself proceeds. A cross-repo default assignee comes from the
user-global user-config only, because the repo-level one belongs to
the current repo.

`/issues:repo-config` writes the file through `repo-config-write`, the
one writer of `.issues/repo-config.md`. It runs the same validity
checks the verbs apply on read — less their refusal of a Jira config,
and over a `jira:` block as well as a `github-project:` one — and
refuses a draft that fails one, leaving any existing file untouched. A
config the verbs would reject is otherwise discovered on the first verb
run, by whoever runs it.

The interviews' live lookups are `issues-discover`, one script with a
subcommand per lookup, each printing JSON: `projects` and
`project <number>` for the owner's boards, `fields <number>` for one
board's fields, `issue-fields` and `issue-types` for the repository's
native issue fields and enabled issue types, and `viewer` for the
authenticated user alongside the repository's host, owner and name.
It reads no repo-config, because `/repo-config` runs it before one
exists. Each list is already filtered to what a slot can be backed by
— number and single-select board fields, single-select native fields,
enabled types — so the skill reads the result rather than filtering
it, and every paged connection is read to its end. `issue-fields`
prints an empty array with a note on stderr when the repository has no
single-select native fields or the host's schema has no `issueFields`
at all, since either means only that there is no `issue-field` option
to offer; a token lacking the scope a lookup needs is reported with
the scope and the host, because `gh`'s own wording does not always
name the scope. Board lookups go through `repositoryOwner`, so one
query serves an organization and a user.

`test/issues-bin-test.sh` runs every script under `/bin/bash` against
`test/fake-gh.py`, an in-memory GitHub on `PATH` as `gh` that logs
every call — which is how a test asserts that the Jira refusal made
none. Its write-dropping mode is the negative control: every write
reports success and changes nothing, and every write path must exit
non-zero on it. The fake gives each repository a host and resolves a
repository, node or comment only on its own host, so a call that drops
the host fails the verb rather than only the call-log check. The
discovery lookups have their own state: an owner's boards live under
`owners`, each owner on its own host; `hostUsers` gives each host its
own authenticated login, so a `viewer` test can tell which host was
asked; a host listed in `scopeless` has a token without `read:project`
and fails every board query as GitHub does; a repository's
`issueFields` or `issueTypes` set to `"absent"` stands for a schema
without that field, and `null` for a null connection; and a repository
named in `nullRepos` resolves to null without an error. A pull request
is an entry in a repository's issues carrying `pullRequest: true`,
since the two share one number sequence on GitHub, which is how a test
asserts that a verb refuses one. No test reaches GitHub.

`test/issues-reference-test.sh` is the parser's own suite: it runs
`iss_parse_operand` alone under `/bin/bash`, with the current
repository held as already resolved and any `gh` call fatal, over
every accepted reference form, a round trip of each form a verb
prints, a pull-request URL and each malformed shape. The forms it
accepts are the ones `github-prs`' PR-reference parser accepts, so a
reference copied between the two plugins' verbs parses to the same
host, owner, repository and number.

## Every call names its host

A repository is a host, an owner and a name, and the scripts treat the
host as part of the repository's identity rather than as a property of
the machine. `gh` resolves a host-less `owner/repo` on its own default
host — github.com, unless `GH_HOST` says otherwise — even inside a
checkout whose `origin` is on a GitHub Enterprise host, so a verb that
named repositories as `owner/repo` queried the wrong host there and
failed. Each script resolves the current repository once, from the
URL `gh repo view` reports for the checkout, and every `gh api` call
goes through one of two wrappers in `issues-common.sh` — `iss_gql` for
GraphQL, `iss_rest` for REST — that take the target host as their first
argument and pass it as `--hostname`; every `gh issue` call carries the
host in `--repo`. The host travels per call and is never exported as
`GH_HOST`, because one session works across several organizations and
hosts and an environment variable would pick one for all of them.

The interviews reach the host the same way, and could not otherwise.
`/repo-config` and `/user-config` once had the model run `gh project`
and `gh api` commands of their own, host-less, so a GitHub Enterprise
checkout was queried on github.com — a board lookup failed there for
want of `read:project`, and the ownership check silently compared the
owner against the github.com login. The two ways
a model could add a host to such a command, a `GH_HOST=` prefix and
`gh api --hostname`, are each a credential-redirect that guardrails'
permission gate denies; the gate classifies the command the model
runs, not the calls inside a plugin script. So the lookups moved into
`issues-discover`, which resolves the host from the checkout as every
verb does.

That is also why a repository argument has a grammar rather than a
single `owner/repo` shape: `repo` alone, `owner/repo`, `host/owner/repo`
and the repository's `https://` URL each resolve against the current
repository, so a caller supplies only the part that differs from where
it stands. Every printed issue reference uses the shortest of those
forms that resolves back to the same issue — `#N` here, `repo#N` under
the same owner, `owner/repo#N` on the same host, `host/owner/repo#N`
elsewhere — and every verb's issue operand, `/issue-create --parent`
included, accepts each form back, and the issue's `https://` URL
besides, so a reference copied out of one verb's output, or out of a
browser, is an operand for the next. `skills/lib/issue.md` owns the
grammar and the resolution rules. Outside a git checkout there is no
current repository to resolve against: a bare `repo` is a usage error,
and `owner/repo` goes to `gh`'s default host.

The grammar is the one `github-prs` parses for a PR, with `issues` in
the URL where a PR has `pull`, so a reference carried between the two
plugins' verbs means the same repository in each. Plugins cannot share
a file, so each carries its own parser, and a change to the grammar
edits both — the repository part of each is validated per part, by
what GitHub allows an owner and a repository name and DNS allows a
host, rather than by one character class over the whole path, so a
repository name may start with `-` while an owner may not. A single
leading `-` on an argument is therefore not an unknown flag to these
verbs, whose flags are all `--long`; it reaches the parser as an
operand. The verbs take issues only: a `pull` URL is a usage error
before any call, and a number that turns out to be a pull request
aborts once read, naming it as one, because GitHub's issue endpoints
accept a pull request's number and a verb must not act on one by
accident.

## Skills

Every verb addresses **one** issue — an issue reference on GitHub, a
key on Jira. Per-verb detail — flags, defaults, echo formats — lives in
each skill's own `SKILL.md`.

| Skill | What it does |
| ------- | -------------- |
| `/issue-create [<repo>] [--parent <issue>]` | File a new issue with title, body, type, fields, parent, assignees and labels in one invocation, here or in another repo |
| `/issue-view <issue>` | Print one issue's body, project fields and every relationship in one shot |
| `/issue-view-tree <issue>` | Walk an issue tree downward through sub-issues, depth-capped at 5 |
| `/issue-sub-list <parent-issue>` | List a parent's direct sub-issues |
| `/issue-update <issue>` | Change a title, body, labels or assignees |
| `/issue-comment <issue> --body-file PATH` | Add a comment, body read from a file |
| `/issue-close <issue>` | Close an issue, optionally commenting first |
| `/issue-set-status <issue> <status>` | Set the status field on the issue's project item |
| `/issue-set-priority <issue> <value>` | Set the priority slot |
| `/issue-set-size <issue> <value>` | Set the size slot |
| `/issue-set-type <issue> <type>` | Set the issue type |
| `/issue-field-options [[<repo>] <slot>]`, `/issue-field-options [<repo>] --all` | Report a slot's configured kind, default and options, or every slot's with `--all` or with nothing named, here or for another repo |
| `/issue-set-parent <child-issue> <parent-issue>` | Make one issue a sub-issue of another |
| `/issue-set-child <parent-issue> <child-issue>` | The same edge, named from the parent's end |
| `/issue-unset-parent <child-issue>` | Detach an issue from its parent |
| `/issue-unset-child <parent-issue> <child-issue>` | The same removal, named from the parent's end |
| `/issue-set-blocked-by <issue> <blocker-issue>` | Record that an issue is blocked |
| `/issue-set-blocks <issue> <blocked-issue>` | The same edge, named from the blocker's end |
| `/issue-unset-blocked-by <issue> <blocker-issue>` | Clear a blocked-by edge |
| `/issue-unset-blocks <issue> <blocked-issue>` | The same removal, named from the blocker's end |
| `/issues:repo-config` | Interview the repo's team-shared config into existence, or rewrite it whole |
| `/issues:user-config` | Merge-update this user's private per-repo settings, and keep the file ignored |
| `/issues:global-user-config` | Merge-update this user's machine-wide settings |
| `/issues:issue-branch-prefix` | Print the issue-branch prefix mode the repo config names and the literal prefix it resolves to for this user |
| `/issue-add` | Deprecated alias for `/issue-create` |
| `/issue-set-importance` | Deprecated alias for `/issue-set-priority` |

The two-verb pairs above are two views of **one** edge each, not two
edges: users think about a link from either end, so the namespace lets
them say it either way.

Every `<…issue>` operand, and `--parent`'s value, is an issue
reference: `N` or `#N` for an issue here, `<repository>#N` with the
repository in any form the grammar above takes, or the issue's
`https://` URL. So a verb acts on an issue filed in another GitHub
repo, on this host or another, and a relationship verb's two operands
need not share a repo: a blocked-by or sub-issue edge can join an
issue here to one elsewhere — the case a grooming pass hits when the
work an issue depends on belongs elsewhere. Nothing new is needed on
the GitHub side for this: each mutation takes node IDs, which are
global, so an edge between repos is the same edge as one within a
repo, and each verb resolves each operand in the repo it names, under
that repo's own repo-config. The form is GitHub-only, because a Jira
key is already globally unique and needs no repo qualifier; an operand
whose repository is tracked in Jira aborts with the fixed Jira message
before the issue is read, whatever tracker the checkout itself is on.

## What it deliberately does not do

- **No search or list-the-backlog verb.** Every verb takes an issue
  you already have a reference to; a caller holding several loops.
- **No branch, commit or PR handling.** Naming an issue's branch,
  opening its PR, and writing the closing keywords belong to
  `git-tools` and `github-prs`; the multi-issue orchestrator that
  drives an issue end-to-end is `sdlc`. What this plugin does own is
  the **value** a branch name is prefixed with: the repo config names
  a prefix mode, the user config holds the initials or name that mode
  puts in front of `/`, and `/issues:issue-branch-prefix` resolves the
  two into the literal prefix, so a caller that names a branch neither
  parses `.issues/` files for it nor asks the human.
- **No config written behind your back.** `/repo-config` is the only
  writer of the repo config, through `repo-config-write`, and it
  rewrites the whole file from an interview; no verb edits it mid-run
  to record what it discovered.

## GitHub calls live only in `bin/lib/issues-common.sh`

A GraphQL document, an ID resolution and an error's wording are each
written once, in `bin/lib/issues-common.sh`; a script calls the
function and names the roles its inputs play, and no SKILL.md or
`skills/lib/` document restates the call. `skills/lib/issue.md` keeps
what is not code — the `github-project:` schema and field kinds, and
the Jira path. A change to a call's shape, its re-read or its wording
is made in the helper, and the suite under `test/` is what re-checks
it.

## The config paths are literals every consumer spells itself

This plugin owns these paths:

- `.issues/repo-config.md` — team-shared, committed, written by
  `/issues:repo-config`.
- `.issues/user-config.md` — one user, one repo, gitignored, written
  by `/issues:user-config`.
- `$XDG_CONFIG_HOME/issues/user-config.md` — machine-wide per-user,
  written by `/issues:global-user-config`, outside every git clone.

None of them is a naming preference, and each replaced a
`.claude/rules/` path deliberately. Claude Code auto-loads every
un-scoped `.claude/rules/*.md` into every session and subagent on every
turn, so a config living there was carried by sessions that never
invoke an issue verb — and a config is reference data a reader fetches,
not an instruction the model holds. Do not move any of them back.

Nothing factors those literals out, because plugins are file-sandboxed:
a consumer in another plugin cannot follow `skills/lib/repo-config.md`
and writes the path out instead. `.issues/repo-config.md` crosses the
boundary two ways — consumers in `git-tools`, `github-prs` and `sdlc`
inline-parse only the front-matter each one needs, never the whole
contract, while other files merely mention it, and a prose mention goes
stale as loudly as a reader does. So a PR that moves or renames a
config path edits every plugin that **spells** it and bumps each of
their versions, in one PR. Sweep by grepping the literal —
`grep -rn '\.issues/' plugins/` and
`grep -rn 'XDG_CONFIG_HOME/issues' plugins/` — not by opening the
plugins the diff already touched.

These are deliberately *not* duplicated, and adding a copy is the
defect rather than a helpful expansion:

- **Who reads repo-config.** A reader contract states what a file
  provides, never who consumes it, so neither `skills/lib/repo-config.md`
  nor `skills/repo-config/SKILL.md` names a consumer, and a new reader
  in another plugin is no edit here. The one named exception is
  `/issues:issue-branch-prefix` under `issue-branch-naming-prefix`:
  the mode on its own is not a prefix, and a reader of the entry that
  was not told what resolves it would go back to asking the human for
  the value, which is the behaviour the verb exists to replace.
- **The `$XDG_CONFIG_HOME` fallback.** `skills/lib/user-config.md` →
  "Where `$XDG_CONFIG_HOME` resolves" is the single definition of what
  an unset or empty variable resolves to; a consumer needing the rule
  points at that heading.

Nothing migrates a repo or a machine off the old paths. The interview
skills look only at the new path, so an already-configured repo re-runs
from built-in defaults and the old file stays put; deleting it is the
operator's job. The one automated cleanup is `/issues:user-config`
removing a stale `.claude/rules/user-config.md` line from `.gitignore`.
A repo whose `.gitignore` is an allow-list — the marketplace repo
included — also needs a `!` line so the committed
`.issues/repo-config.md` is not ignored.
