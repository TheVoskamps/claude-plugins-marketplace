# guardrails changelog

## 0.19.0 — 2026-11-01

The Bash file-work redirect is now on by default in linked worktrees and
also covers `awk`. Agents in a worktree are sent to Read, Edit and Write,
which load a path's `CLAUDE.md` and `paths:` rules where Bash does not.
Main-checkout sessions are unaffected unless set to `always`.

- `redirect-bash-file-work` defaults to `worktree`. No config file, an
  absent key, an empty value, a file stamped below the current schema
  and an unrecognized value all resolve to it, so a typo no longer
  disables the redirect. Only an explicit `off` turns it off, and an
  unrecognized value still logs a warning.
- gawk's in-place forms (`-i inplace` and its spellings) are denied as
  edits, alongside `sed -i` and `perl -i`.
- An `awk` that only selects lines from a named file (an `NR`
  comparison, a bare `/re/`, or a range of those) is denied and sent to
  Read. Field printing, `printf`, `BEGIN`/`END` and any option leave it
  alone, and so does piping it into a command outside the reader set.
- Interpreter one-liners (`python -c`, `perl -e`, `ruby -e`, `node -e`)
  are not covered.

## 0.18.1 — 2026-10-28

Internal lint cleanup of the gate, with no verdict changes. A newly
created evolution log is now `0600` in a `0750` directory; existing log
files and directories keep their modes. A `..` after a symlink in
`PERMISSION_GATE_LOG` still opens the file the kernel resolves.

## 0.18.0 — 2026-10-16

Adds an optional redirect that denies a Bash command doing file work
the Read, Edit or Write tool does, and names that tool in the reason.
It is off by default.

- Set `redirect-bash-file-work` in `~/.config/guardrails/config.yml`, in
  a file stamped `schema-version: 2`, to `worktree` to apply it in linked
  worktrees, or `always` for every session. Any other value counts as
  `off` and writes a warning to the evolution log.
- Reads: `cat`, `head`, `tail`, `sed -n`, `nl` and `less` naming a file,
  unless the output is piped into a command outside that set or captured
  by a substitution.
- Edits: `sed -i` and `perl -i`.
- Writes: `echo` or `printf` redirected to a file, `cat` of a
  here-document redirected to a file, and a here-document fed to
  `tee <file>`. Another program's output (`make > build.log`) is not
  covered.
- `grep`, `find` and `ls` are never covered, and a deny from another
  rule keeps its own reason.

Other behavior changes in this version:

- **Action needed if your config is broken:** a config file that exists
  but cannot be read or parsed now denies every gated call as
  `config:unusable`, until you fix it by hand.
- `sed` is read under both its GNU and BSD grammars, and every file
  either reading touches is held to containment, including script
  `r`/`R`/`w`/`W` targets and backup names.
- A `sed` script using `e` or `s///e`, or read from a script file, now
  defers, as does a symlink under `--follow-symlinks` that cannot be
  read. A `sed` too ambiguous to parse within the limit denies as
  `bash:sed-parse-limit`, and a bare `-i` has its own deny.
- A linked worktree's primary clone is now derived correctly for
  submodules and `--separate-git-dir` layouts, except a separate git
  directory itself named `.git`, which is unsupported.

The committed binaries now carry shell parser `mvdan.cc/sh/v3` 3.14.1.

## 0.17.5 — 2026-09-22

Documentation only: removes a note about agent memory from the gate's
README.

## 0.17.4 — 2026-09-20

Adds a user-facing README for the plugin. No behavior change.

## 0.17.3 — 2026-09-14

Two fixes on the Bash track.

- A nested `for` whose inner header uses braces, such as
  `for a in 1 2; do for b in x{1,2}; do cat $b; done; done`, no longer
  panics into a blocked call.
- A file redirect no longer skips the cross-repo read deny:
  `cat <cross-repo> > .claude/tmp/x` now denies, as the same read
  without the redirect does. An unrecognized flag beside an escaping
  read now denies too, while the same flag on an in-repo read defers.

The gate's Go module now requires `mvdan.cc/sh/v3` 3.14.1.

## 0.17.2 — 2026-09-13

A path listed in `~/.config/guardrails/config.yml` is now reachable from
Bash as well as from the file tools. Before, the same path was allowed
as a `Read`, `Write` or `Edit` operand and denied as a Bash operand.

- A Bash operand rides the listing only when spelled literally: plain
  letters, digits, `.`, `_` and `-` per segment, no `..`, and nothing
  glued to a redirect. A bare `*` is withheld wherever it could expand
  to `.git`. Anything else keeps its verdict from without the listing.
- Nothing under a `.git` segment is handed out on any track, matched
  case-insensitively, and allow reasons name the listing only when a
  target actually rode it.

## 0.17.1 — 2026-09-11

Documentation only: the gate's README no longer depends on repository
documents that do not ship with the plugin. No behavior change.

## 0.17.0 — 2026-09-11

The gate now treats an unusable home directory the same way everywhere.
A home is usable only if it resolves, is non-empty and is absolute.

- A Bash word referencing an unusable home (`~`, `$HOME`, or a
  persistent in-script `HOME=`), or a file-tool `~` operand, denies as
  `home:unusable`. So does a bare `cd`, and spellings that reach home the
  same way, such as `cd -P` or `cd $UNSET`. `HOME=relhome; cat ~/x` moves
  from allow to deny. A parse error or forbidden form denies first, with
  its own reason.
- With an unusable home, no carve-out config loads, no `~/.claude` root
  resolves and no home-derived log path is used. An absolute
  `PERMISSION_GATE_LOG` still writes.
- A call that references no home path keeps its verdict.

## 0.16.1 — 2026-09-10

An unquoted `~`, `$HOME`, `$USER` or `$TMPDIR` inside a command
substitution holding a single plain command no longer panics into a
blocked call. Such a substitution now earns its inner command's verdict,
so `echo $(cat ~/x)` denies as `cat ~/x` does, with a real reason.

## 0.16.0 — 2026-09-10

The carve-out in `~/.config/guardrails/config.yml` now covers three
roots, `config-home`, `state-home` and `home`, each with its own `read`
and `write` glob lists, at `schema-version: 2`. State files can now be
carved out, and a relocated `$XDG_CONFIG_HOME` can be honored.

- **Action needed:** a file still using `allow-read` and `allow-write`
  yields no entries until it is rewritten to the new schema.
- `config-home` and `state-home` follow their XDG variables only with
  `resolve-xdg-environment-variables: yes` and the variable set and
  non-empty. Otherwise they use the file's `config-home-default` and
  `state-home-default`. A root spelled nowhere does not exist.
- Whatever the file says, nothing under a `.git/` directory is handed
  out, and the config file itself cannot be written through the
  carve-out.
- The config file itself stays at `~/.config/guardrails/config.yml`
  whatever the XDG variables say.
- A relative file-tool path now resolves against the event's working
  directory, closing an escape through an in-repo symlink, and a
  non-absolute event directory fails closed.

## 0.15.3 — 2026-09-08

Deny messages no longer point at rule files that may not exist on the
reader's machine, and no longer make claims about Claude Code's own
behavior. Each keeps its inline instructions.

The gate's Go module now requires `mvdan.cc/sh/v3` 3.14.0.

## 0.15.2 — 2026-09-02

Documentation only: a small wording correction in the gate's README.

## 0.15.1 — 2026-09-01

Removes the scratch-file-location rule document, which nothing loaded.
The gate's deny messages already give the scratch destination with
resolved paths, so behavior is unchanged.

## 0.15.0 — 2026-08-31

Adds an operator-written carve-out, `~/.config/guardrails/config.yml`,
for machines where `~/.config` is a symlink into a dotfiles repo. There,
every per-user plugin config resolved into another repo and was denied,
and a `permissions.allow` entry could not override that.

- `allow-read` and `allow-write` hold globs relative to `~/.config`, and
  write implies read. No defaults ship.
- Matching is lexical with no symlink resolution, so a symlink under a
  listed path that points into a sibling repo is allowed.
- It applies to the file tools only. The `.git/` deny still wins, and
  every target of a call must be covered for the call to be allowed.
- A listed path under `.git/` does not become readable.
- A missing, unreadable or malformed file, or one with a missing or old
  `schema-version`, changes nothing.

## 0.14.1 — 2026-08-27

Documentation only: the gate's README gains its guidance for changing a
verdict or the shape of the committed binaries.

## 0.14.0 — 2026-08-20

Reading a primary clone's working files from a linked worktree is now
denied, whoever is driving. Those reads succeeded and returned the wrong
tree's content with no error.

The message names the resolved path and sends you to this worktree's
copy, or to `git show HEAD:<path>` where this worktree holds no such
file. Reads from the primary clone itself are unchanged.

Paths the gate does not grade can still reach the primary clone:
`git show main:<path>`, `git diff --no-index`, paths it cannot resolve
statically, and programs with no read table, such as `python3 -c`.

Deny, ask and defer reasons now name rules without tracker numbers.

## 0.13.1 — 2026-08-16

Fixes agent runs dying a few requests in on Claude Code 2.1.232 and
later. The gate emitted `"permissionDecision": "defer"`, which Claude
Code now treats as pausing the call, and inside a subagent the call
never resumed. A defer now omits that field. Allow, deny and ask output
is unchanged.

## 0.13.0 — 2026-08-13

Verdicts are rebuilt around what the gate does better than a tuned auto
mode evaluator, so far fewer calls prompt you. Without a tuned auto mode
configuration, the moved calls fall to your allow-list and prompt
settings.

- **Deny** remains for known-bad calls with a complete redirect, whose
  reason teaches the agent what to do instead.
- **Allow** is unchanged and needs positive grounds.
- **Ask** shrinks to a short list: publish verbs, history-destroying
  pushes, credential and secret reads, and credential mints such as
  `gh auth token`, `sts assume-role` and `iam create-access-key`.
- **Defer** takes the judgment middle, including paths the gate cannot
  pin down, unknown flags, unrecognized `gh`, generic remote mutations,
  and context-dependent operations such as `git remote add`. Its
  reasoning goes only to the log, not to the evaluator.
- The `updateIssue` GraphQL mutation now denies with the allowed
  alternatives, except beside another mutation it cannot redirect. A
  credentialed redirect that escapes the worktree or targets `.git/`
  also denies.
- The evolution log now records ask and defer with the gate's analysis,
  as a tuning feed.

That an ask outranks an allow in `settings.json` or auto mode is design
intent and has not been verified against a live harness.

## 0.12.0 — 2026-08-11

The `updateIssueFieldValue` GraphQL mutation is now allowed without a
prompt. `updateIssue` keeps its prompt because it can dispatch a coding
agent at another repository; to change an issue's type, use
`updateIssueIssueType`, which is already allowed.

## 0.11.0 — 2026-08-07

The gate now grades the local files a `gh` command publishes. Before,
`gh pr comment <N> -F /etc/passwd` was allowed outright and sent the
file to GitHub.

- Body-file, notes-file, `pr create` template, recover and asset
  operands, in every flag spelling including `-F=FILE`, are checked like
  any other read. An escaping file is denied rather than offered as a
  click-through, and a contained one does not bless the publish.
- Reading stdin counts: `gh pr comment <N> -F - < /etc/passwd`,
  `gh gist create < /etc/passwd` and `gh gist edit <id> - < /etc/passwd`
  all deny.
- A published path the gate cannot resolve asks. A dynamic body-text
  value beside a static path does not, so `--title "$TITLE"` still
  allows.
- An unrecognized flag on a publishing verb asks, so a future `gh` flag
  that reads a file costs a click rather than a silent publish.
- Every `gh gist create` and `gh gist edit` asks, whatever the flags,
  because a secret gist is unlisted rather than private and content
  pushed to an existing gist is readable at once. `gh gist delete` still
  denies.
- `gh`'s own command aliases resolve before any rule runs, so an alias
  earns its canonical verdict in either direction: `gh gist new` asks,
  `gh pr new` allows, `gh secret ls` no longer denies, and
  `gh rs delete` denies.

Still ungraded: `gh api -X GET -F q=@<file>` allows, without checking
the file.

## 0.10.0 — 2026-08-03

Stops prompting on commands the gate already had the information to
decide, and closes a gap where substituted commands went ungraded.

- A redirect from `gh`, `git` or `aws` is graded by its destination, so
  `gh pr diff <N> > .claude/tmp/x` no longer asks. It still asks on an
  escape, a `.git/` target or a path it cannot pin down.
- Path anchors such as `$(git rev-parse --show-toplevel)` are recognized
  when quoted, inline in a larger word, or as a `cd` target.
- `gh auth status` allows when no flag can print a credential.
  `--show-token` and unknown flags ask.
- `git push origin HEAD:branch` allows. A `+` forced refspec asks.
- `<(cmd)` counts as a pipe rather than a path, so `diff <(a) <(b)` can
  allow. `>(cmd)` stays conservative.
- A dynamic value no longer denies a `gh` command when it is a field or
  output flag's value and the key is static, so GraphQL chains can pass
  node IDs through variables. `-F "$K"=v` still denies.
- `sed`, `awk` and `grep` scripts and patterns are no longer read as
  paths, so a `sed` address starting with `/` stops denying. `diff`
  joins the read-only utilities.
- **A parse error now denies** instead of asking, since a click cannot
  repair a command bash would refuse. The reason gives the position and
  the likely cause.

Three changes make the gate stricter:

- A flag value naming a file is contained in every spelling, including
  `grep -f`, `sed -f`, `awk -f`, `diff -X` and `wc --files0-from`.
- Commands inside `$(…)` and `<(…)` are now graded in every position,
  including `for` lists, `case` words, inline prefixes, array elements
  and `[[ … ]]`. Several of these were allowed before while bash ran the
  inner command, and now earn its own verdict. A recognized path anchor
  is the exception. `<(cmd)` inside a parameter expansion's word is
  still ungraded.
- Assignments and `cd` inside a substitution no longer leak out of it.

## 0.9.17 — 2026-08-02

A gate that cannot run now blocks instead of letting every tool call
through unchecked. A missing or non-executable binary, a binary that
will not run, a silent exit and a crash all deny, with a message naming
the resolved path. Adds a `linux-arm64` binary for claude-vm guests.

## 0.9.16 — 2026-08-02

Clearing an issue-metadata value no longer prompts:
`deleteIssueFieldValue` and `clearProjectV2ItemFieldValue` are allowed.

## 0.9.15 — 2026-08-02

The Claude Code session scratchpad is now usable. It was denied like any
other `/tmp` path, and a `settings.json` allow could not override that.

- Session paths allow for reads and writes, including redirects.
  Bundled-skill paths allow reads and defer writes. Other paths under
  `claude-<uid>` allow for curated read utilities and otherwise defer.
- Any other `/tmp` path is still denied. A `claude-<uid>` directory that
  is a symlink or is not owned by this user asks.
- `ls` joins the read-only utilities.

Also closes holes where redirects went ungraded. `cat < /etc/passwd`,
the same read on a compound command, and `{ echo x; } > <outside path>`
were allowed. Input sources now get the same containment as operands, so
those reads deny, and the write defers. A redirect with no command, such
as a bare `> f`, is graded the same way. Deny messages now name the
resolved repo root.

## 0.9.14 — 2026-07-30

The issue-metadata GraphQL mutations no longer prompt, so issue creation
and triage stop costing several clicks. A document is allowed only when
every top-level mutation is on the list: `setIssueFieldValue`,
`updateProjectV2ItemFieldValue`, `addProjectV2ItemById`,
`updateIssueIssueType`, `addSubIssue`, `removeSubIssue`, `addBlockedBy`,
`removeBlockedBy`, `closeIssue` and `reopenIssue`.

## 0.9.13 — 2026-07-20

Closes a leak in the `aws` read allowance. A credential-returning
`get-*` that a fixed list missed, such as `aws eks get-token` or
`aws sso get-role-credentials`, was allowed. A `get-*` whose name
carries a credential word now asks, at the cost of an occasional
spurious prompt. `list-*`, `describe-*` and `sts get-caller-identity`
still allow.

## 0.9.12 — 2026-07-19

`gh` writes are now allowed only for named, recoverable verbs.

- An unrecognized `gh` noun or verb asks instead of allowing.
- A write aimed with `-R` or `--repo` at a repository other than
  `origin` asks, as do `git remote add` and `git remote set-url`. If
  `origin` cannot be determined, the write stays allowed. Reads are not
  scoped.
- Each remaining irreparable-verb deny names a reversible alternative.

## 0.9.11 — 2026-07-17

`gh api` REST writes now ask instead of deny, which unblocks skills that
configure repositories through it. `--hostname` still denies.

## 0.9.10 — 2026-07-16

A variable assigned exactly `$(git rev-parse --show-toplevel)`,
`$(git rev-parse --git-common-dir)` or `$(pwd)` now resolves to its
path instead of prompting. The resolved path still goes through
containment, so a read under the common directory denies as a `.git/`
path.

## 0.9.9 — 2026-07-16

`$HOME`, `$USER`, `$TMPDIR`, `$PWD` and `$OLDPWD` now resolve in paths,
so `cat $HOME/.ssh/id_rsa` denies just as `cat ~/.ssh/id_rsa` does.
An in-script assignment wins, and `~` now honors an in-script `HOME=`
too. Other environment variables stay unresolved.

## 0.9.8 — 2026-07-15

`for` loops over a static list now resolve the loop variable, so
`for f in a.md b.md; do cat "$f"; done` is judged on each item rather
than prompting. Lists over 64 items, dynamic lists and globs stay
conservative.

## 0.9.3 — 2026-07-12

Reading a primary clone's files from a linked worktree no longer
prompts. Reads under `.git/` still deny, and so do writes that leave the
worktree.

## 0.9.2 — 2026-07-12

Relative Bash paths now resolve against any earlier `cd` in the same
command, which ends false escape verdicts. A `cd` the gate cannot
resolve makes later relative paths fail closed.

## 0.9.1 — 2026-07-12

`aws` operations the gate cannot prove read-only, such as `aws s3 rm` or
`aws ec2 terminate-instances`, now ask instead of allow. Read-only
operations still allow, and `aws configure get` of a non-secret key such
as `region` is allowed explicitly.

## 0.8.0 — 2026-07-11

`gh api` is classified instead of blocked wholesale, which unblocks the
`issues` plugin.

- GraphQL queries given as a literal `-f query=…` allow, mutations ask
  and name their fields, and a document the gate cannot classify denies.
- REST GETs to known path prefixes allow. Other endpoints and unknown
  flags ask, and an endpoint with `://` or `..` denies. REST writes and
  `--hostname` still deny.

## 0.7.0 — 2026-07-09

Adds deny and ask rules for dangerous `git`, `gh` and `aws` operations.
Other recognized commands from these tools allow.

- Commands with non-static arguments, an inline environment prefix such
  as `GIT_SSH_COMMAND=`, or `git -c` config injection deny.
- `git push --mirror` and `--prune` deny, `--force` and `source:dest`
  refspecs ask, and `--force-with-lease` and fast-forwards allow.
- Irreparable `gh` verbs and secret writes deny. Repository visibility
  edits, `release create` and public gists ask. `gh api` writes and
  GraphQL deny, and a plain GET asks.
- `aws --endpoint-url` denies, and credential reads ask.

## 0.6.0 — 2026-06-28

`cp`, `mv`, `mkdir`, `touch`, `sed -i` and `tee FILE` now allow without a
prompt when every path stays inside the current worktree. An escaping
path or a `.git/` target denies. `rm` is deliberately left out, so you
still see each one.

## 0.5.3 — 2026-06-28

Common read-only utilities such as `cat`, `grep`, `sed -n`, `awk`, `jq`
and `find` now allow without a prompt when their paths are contained.
Mutating forms and unrecognized flags do not ride this allow, and
cross-repo reads still deny. Pagers and binary dumpers such as `less`
and `xxd` keep their defer.

## 0.3.4 — 2026-06-25

A path built from a variable assigned a static literal earlier in the
command now resolves, so `P=/some/dir` then `cat "$P/README.md"` is
judged on its real path. Dynamic values stay fail-closed.

## 0.3.2 — 2026-06-25

Process substitution such as `diff <(a) <(b)` no longer crashes the gate
into a blocked call.

## 0.3.1 — 2026-06-24

Deny and ask messages now stand on their own, saying what was blocked,
why, and what to do instead, without tracker references.

## 0.3.0 — 2026-06-24

Containment denies now name where scratch files belong and warn against
writing under `.git/`, so agents stop improvising a destination.

## 0.2.0 — 2026-06-24

Fewer false denies, and a broader write block.

- Reading `git config user.*` is no longer denied, while writes are.
- `let`, `[[ … ]]`, `time`, `coproc`, `export`, `local` and `declare` no
  longer prompt wholesale.
- Write and Edit are denied anywhere under a `.git/` directory.

## 0.1.0 — 2026-06-22

A compiled `PreToolUse` hook that decides allow, deny, ask or defer for
Bash, file and MCP tool calls, escalating to you when uncertain.

- Classifies each simple command in a parsed Bash line, and MCP calls by
  tool name.
- Denies worktree escapes and cross-repo access, and fails closed on any
  crash, parse error or malformed event.
- Records every ask and deny in `~/.claude/logs/permission-gate.jsonl`.
- Policy is compiled in, with binaries for `darwin-arm64` and
  `linux-amd64`.
