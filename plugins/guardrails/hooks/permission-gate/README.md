# permission-gate

A compiled (Go) PreToolUse hook that adjudicates the tool calls Claude
Code is about to make: **allow**, **deny**, **ask**, or **defer**. It is
the deterministic enforcement layer the OS sandbox structurally cannot
provide (issue #247). It replaces the shell hooks
`auto-approve-compound-commands.sh` and `worktree-file-guard.sh`.

## What it does

Two engines feed the allow/deny/ask (plus defer) decision, ask-defaulting
(uncertainty escalates to a human, never to allow):

- **Engine A — command classifier** (`engine_a_bash.go`,
  `classify_command.go`, `rules.go`, `readonly_util.go`,
  `forbidden_forms.go`, `engine_a_mcp.go`): parses the Bash command to an AST
  (`mvdan.cc/sh/v3`) and classifies each simple command; branches on
  MCP tool names. Constructs whose inner command is not statically
  resolvable — process substitution `<(…)` / `>(…)`, command
  substitution `$(…)` — are classified conservatively (the word is
  marked inexact, so the line never rides the allow track) rather than
  crashing; an earlier nil `ProcSubst` expander panicked on `<(…)`
  (#5). A parameter expansion (`$P` / `${P}`) whose variable was
  assigned a **static literal** earlier in the same parsed program is
  resolved to that literal and run through normal containment, instead
  of failing closed on `hasUnknownExpansion` (#60): e.g.
  `P=/abs/dir; cat "$P/file"` is contained, not escalated. A variable
  assigned from a command substitution / another unresolved expansion,
  an undefined / environment variable, or a non-plain expansion
  (`${P:-x}`, `${#P}`, …) stays inexact and keeps escalating
  (fail-closed); a `VAR=x cmd` prefix sets env for that one command only
  and does not persist to later commands. Static-variable resolution is
  also **scope-aware**: an assignment made inside a `( … )` subshell, a
  function body, or a backgrounded group/subshell (`{ … ; } &`,
  `( … ) &`) runs in a child shell and does NOT leak into the
  program-global scope, so it cannot resolve a later top-level `$VAR`
  (matching real bash). The inherit-IN direction still holds: a
  top-level static assignment IS visible to a use nested inside such a
  scope. Engine A also tracks the **running working directory across an
  in-command `cd`** (#129): a relative path operand on a command that
  follows a `cd` in the same parsed program — `cd <subdir> && cat
  ../x`, `cd <subdir>; touch y` — resolves against the `cd` target, not
  the event's `cwd`, matching what bash actually runs. A
  statically-resolvable `cd` (an absolute path, a `~`-prefixed path, a
  relative path, or bare `cd` to `$HOME`) updates the running cwd for
  every later command in the walk; a `cd` whose target cannot be
  resolved statically (a command substitution, an unresolved variable,
  or `cd -`) invalidates it, and every later command with a relative
  path operand in that scope **asks** rather than guessing (fail-closed
  — a later re-anchoring `cd` can clear the invalid state, since bash
  itself would). A `cd` inside a `( … )` subshell, a function body, or a
  backgrounded group does not persist to the enclosing scope, mirroring
  the static-variable scope discipline above. A `for x in <words>; do
  …; done` whose header is a fully static item list (#131, broadened by
  a follow-up) fans out: the body is walked once per resolved item with
  the loop variable bound to that item, so a body use of `"$x"`
  resolves and is run through normal containment instead of failing
  closed, capped at 64 items to bound the work. Every
  statically-knowable item form is expanded and fanned out to its cross
  product: a bare literal; brace expansion (`{a,b}.md`, including
  combined with a known variable — `{a,b}$X.md`); a bare unquoted
  known-variable word (`$LIST`, split on the default IFS the way bash
  word-splits an unquoted expansion — a quoted `"$LIST"` is NOT split,
  matching bash); and a glob (`*.md`, `src/*.go`, `../*.md`) resolved to
  its containment-relevant directory prefix against the tracked running
  cwd, by path arithmetic alone (no filesystem read) — every possible
  match of the glob is a child of that prefix, so the prefix's
  containment verdict applies to the whole pattern. Every expanded item
  is checked (worst-wins), so an escaping item anywhere in the list is
  still reported even when earlier items were safe. A brace element
  containing `..` (`{a,../../../etc/passwd}`) is where the upstream
  parser's own `SplitBraces` declines to split — its guard against
  ambiguity with the `{x..y}` sequence form — and can even silently
  drop a member from a 3+-element list rather than merely leaving
  residual `{`/`}` text; a fallback splitter (matching real bash's
  actual comma-list semantics, verified live) detects both the decline
  and the silent-drop shape and performs the split itself, so every
  member — including the escaping one — still flows through normal
  containment (worst-wins) instead of the whole list falling back to
  an unnecessary ASK. The fallback only understands the single,
  unnested `{a,b,c}` comma-list grammar; a brace form it does not
  handle (nested braces combined with `..`, a bare range form like
  `{1..9}` — ranges without a top-level comma resolve via the upstream
  path directly and never reach the fallback) keeps the loop variable
  unbound and the body fails closed on that variable, matching
  pre-#131 behavior. A `for x; do …` with no `in` clause
  (iterates `"$@"`) is likewise never reduced. The binding is saved and
  restored around the loop so it does not clobber an outer variable of
  the same name, per the static-variable scope discipline above. Engine
  A also carries a
  **read-only-utility classifier**
  (`readonly_util.go`, #31): a curated set of high-frequency text/data
  utilities — `cat`, `head`, `tail`, `wc`, `sort`, `uniq`, `cut`, `tr`,
  `comm`, `paste`, `nl`, `fold`, `fmt`, `column`, `rev`, `realpath`,
  `grep`, `printf`, `echo`, `basename`, `dirname`, `true`, `false`,
  `seq`, `yes`, plus the conditionally-read-only `sed`, `awk`, `jq`,
  `find`, and `tee` — **ALLOWs** the provably non-mutating form instead
  of deferring (a defer then matches no `settings.json` allow entry and
  prompts the user, the single largest prompt source). The ALLOW is
  withheld — the line **defers** — when a real-file redirect or a
  command substitution / unresolved expansion is present (#1); when a
  utility is invoked in a **file-writing form** — a write-capable flag
  (`sed -i`, gawk `-i inplace`/`-p`/`-o`/`-d`, `sort -o`/`--output`,
  `jq -i`) or a write-destination operand (`uniq INPUT OUTPUT`,
  `find -delete`/`-exec`, `tee` to a real file); **or when it carries
  any unrecognized flag** — so a future or unmodeled mutating mode fails
  safe. This fail-safe and write-form inspection covers the
  **always-read-only path-bearing utilities too** (not just the
  conditional `sed`/`awk`/`jq`/`find`/`tee` set): each path-bearing
  utility enumerates its read-only flag grammar, and anything outside it
  defers. The read still **denies/asks** when a path operand escapes
  containment (#148 cross-repo, #127 worktree). Pure-
  output utilities (`printf`, `echo`, `seq`, `true`/`false`, `yes`,
  `basename`, `dirname`) take no path operand and so ALLOW without a
  `git rev-parse` fork. Pagers / binary dumpers (`less`, `more`, `od`,
  `xxd`, `hexdump`) are deliberately out of this ALLOW set: they keep
  the prior path-reader posture (contained → defer, escape →
  deny/ask). A redirect target built from a process substitution or
  unresolved expansion (`wc < <(grep x f)`, `cmd > "$DYNAMIC"`) marks
  the command unprovable so it cannot ride the allow track.
- **In-repo-write classifier** (`classify_inrepo_write.go`, #32): the
  write-side counterpart to the read-only-utility classifier. The agent
  can already mutate any in-repo file via the Write/Edit tools (Engine B
  lets those through when contained), so an equivalent in-repo write via
  a shell utility should not prompt every time. A curated set of
  file-mutating programs — `cp`, `mv`, `mkdir`, `touch`, `sed -i`, and
  `tee FILE` — **ALLOWs** when every path operand it writes is provably
  contained in the current worktree via Engine B containment. Each
  program's operands are parsed against its own flag grammar so a flag
  value or a `sed` script (`s/a/b/`) is never tested as a path. An
  operand that escapes the repo (#148) or the worktree into the primary
  clone (#127) **denies** with the worktree-anchored remediation; a
  target under `.git/` **denies** (#125); an operand built from an
  unresolved expansion **asks** (#1); a real-file redirect **defers**.
  `rm` is deliberately **excluded** (the conservative #32 posture): the
  highest-blast-radius mutating program stays on the ask/defer track so a
  human sees each one. `sed` and `tee` are dual-mode — their read-only
  forms (`sed -n`, `tee /dev/null`) stay on the read-only-utility track;
  only the mutating form routes here.
- **Dangerous git / gh / aws classifier** (`classify_command.go`,
  `rules.go`, #64): the deny/ask half of the command classifier for the
  three tools whose remote operations can damage or expose a remote
  GitHub repo (`git`/`gh`) or exfil credentials/data or mutate remote
  cloud state (`aws`). The classifiers **never defer** — every path
  resolves to allow/ask/deny. For `git`/`gh` the **default for a
  recognized tool is ALLOW** (containment lives in the microVM), with
  deny/ask tiers carving out the dangerous shapes. For `aws` the
  default is **ASK** (#124): an aws mutation is not a guest-local
  operation — it carries the guest's credentials to a control plane
  outside the microVM and mutates real cloud state the VM cannot roll
  back, so containment-lives-in-the-microVM does not backstop it. Only
  the read-only ops keep an ALLOW default; see below.
  Bypass gates fire BEFORE per-command logic, since each reaches a
  dangerous outcome without the flag a naive policy keys on:
  (1) a **non-static argv** (command substitution, unresolved variable,
  glob) on any of the three tools **denies** — the dynamic token can
  hide a dangerous op; (2) an **inline environment-assignment prefix**
  (`AWS_ENDPOINT_URL=…`, `GIT_SSH_COMMAND=…`, `GH_HOST=…`, `AWS_PAGER=…`,
  in both the bare `VAR=x cmd` and `env VAR=x cmd` forms) **denies** —
  it can redirect egress, swap identity, or inject a pager without
  touching argv; (3) **`git -c <key>=<value>` / `--config-env` /
  `--exec-path=<dir>`** config-injection RCE (`core.pager`,
  `core.sshCommand`, `diff.external`, `alias.*`, `*.textconv`, …)
  **denies** — these execute arbitrary commands and defeat any read
  classification (an inert display knob like `-c color.ui=always` still
  allows); (4) **`git push` is classified on its refspec**, not just its
  flags — a `source:dest` refspec **asks** (it overwrites a remote ref
  without `--force`), `--mirror`/`--prune` **deny** (bulk remote
  delete), plain `--force`/`-f` **ask**, while `--force-with-lease`, a
  clean named-branch delete (`--delete <branch>`, `origin :branch`), and
  an ordinary fast-forward push **allow**. For `gh`: `gh api` is routed
  through a method/body/endpoint gate (#64, extended by #113). The
  write DENY tiers are unchanged: a non-GET method, an
  implicit-POST-flipping body flag on a REST endpoint, an
  `x-http-method-override` header, or `--hostname` (which aims the
  signed request at a non-default host — the gh analog of
  `--endpoint-url`) **deny**. On the `graphql` endpoint the gate now
  **classifies the query document** instead of blanket-denying (#113):
  a document supplied literally via `-f query=…` / `--raw-field
  query=…` is scanned (string literals and `#` comments stripped) and,
  if every top-level construct is provably a `query`, the anonymous
  `{…}` shorthand, or a `fragment`, it **allows**; a mutation-bearing
  document **asks** with the mutation field names in the reason (so the
  human sees `addSubIssue` vs `deleteIssue`); a subscription,
  unbalanced/garbage document, or a query supplied non-literally
  (`-F query=…`, which does `@file` expansion / coercion, or `--input`)
  **denies** as unclassifiable. On a REST endpoint the gate runs a
  path-prefix GET-gate (#113): a known-flag-only GET whose endpoint is
  on the read allowlist (exact `rate_limit`/`meta`/`user`;
  segment-bounded `repos/`, `orgs/`, `users/`, `search/`, with a
  leading `/` and any `?query` suffix stripped first) **allows**; a
  `://`- or `..`-bearing endpoint **denies**; an unknown flag or a
  non-allowlisted endpoint **asks** (the two owner-decision deviations
  from the appendix GET-gate — a false ask costs one click, whereas a
  hard deny would recreate the no-escape-hatch wall this gate exists to
  remove). The microVM's no-egress posture remains the real exfil
  control for any GET. Irreparable verbs
  (`repo`/`release`/`issue`/`gist delete`, `secret`/`variable`
  writes, `repo rename`/`transfer`, `ruleset delete`) **deny**;
  `repo edit --visibility`, `release create`, and `gist create --public`
  **ask**. The leading global-flag screen is parsed before the
  noun/verb so a value-taking global (`-R owner/repo`) has its value
  token consumed (otherwise `gh -R owner/repo issue delete` would read
  the slug as the noun and slip the delete past the deny tier), and an
  unrecognized leading global fails closed (**deny**) rather than
  desyncing detection. For `aws`: `--endpoint-url` **denies** (redirects the signed
  request, with credentials, to an arbitrary host); credential/secret
  reads (`sts get-session-token`, `ecr get-login-password`,
  `secretsmanager get-secret-value`, `ssm get-parameter
  --with-decryption`, `configure get aws_secret_access_key` and the
  other local-credential-store secret keys, …) **ask**; read-only ops
  (`describe-`/`list-`/`get-` **hyphen-anchored** — the hyphen is
  load-bearing, so a bare verb like `configure get` is NOT read-anchored
  by this rule; instead a non-secret `configure get <key>` (`region`,
  `output`, `aws_access_key_id`, `cli_pager`) is separately allowed as a
  local-config-only read, while a secret-key `configure get` lands in
  the credential-read ask tier above — token-matched not
  substring-matched) **allow**. **Every other aws op — including
  ordinary writes the spec does not name (`s3 rm`, `s3 cp`,
  `cloudformation delete-stack`, `lambda invoke`, …) — asks (#124)**:
  the gate cannot prove the op read-only, and an aws mutation carries
  the guest's credentials to a control plane outside the microVM and
  mutates real cloud state the VM cannot roll back. To find the
  service/operation split the classifier
  parses aws's **complete, closed set of global flags** the way aws
  itself does — including **unambiguous prefix abbreviations** (`--reg`
  for `--region`, `--endp` for `--endpoint-url`) and both spaced and
  `=`-joined values — so benign commands carrying a global flag (in the
  leading OR the wedged-between-service-and-op position, e.g. `--reg
  us-east-1 ec2 describe-instances`) recover their true operation and
  **allow** without interrupting the human. Resolving abbreviations is
  load-bearing on both sides: it keeps `--endp http://evil` inside the
  `--endpoint-url` **deny** (an exact-only check would let the
  signed-request redirect through), and it keeps `--reg us-east-1 sts
  get-session-token` in the credential-read **ask** tier rather than
  desyncing the operation. Only a **genuinely unrecognized** flag of
  unknown arity, appearing before both the service and operation tokens
  are captured, **fails closed to ask** (a value-taking unknown would
  otherwise leave its value as a stray positional and shift the
  operation token) — a rare last resort, since the global set is
  complete; an unknown flag after both tokens are captured is a harmless
  operation flag. The existing
  identity rules (#117 `gh auth switch`, #125 `git config user.*`, #120
  subagent `git reset --hard`, the App-repo naked-`gh` deny) are
  preserved and fire alongside these tiers.
- **Engine B — path containment** (`engine_b_containment.go`,
  `classify_files.go`): resolves repo/worktree context with
  `git rev-parse` against the event's `cwd`, canonicalizes symlinks on
  both the git-derived root and the target, and blocks worktree escapes
  (#127) and cross-repo access (#148). Fail-closed on any git
  subprocess failure or timeout. Refinements (#247): (1) a target
  whose canonical path lands under the real `~/.claude` is **deferred**,
  not denied as a cross-repo escape, so the `settings.json` allow-list
  governs the agent's required startup reads of its own global config;
  the carve-out is canonicalized on both sides so it cannot be
  symlink-escaped, and genuine sibling repos are still denied. (2) a
  file-mutating tool (Write/Edit/MultiEdit/NotebookEdit) whose
  canonical target is anywhere under a `.git/` directory is denied (the
  Engine B half of the #125 identity-write rule, broadened from
  `.git/config` to the whole `.git/` tree in #35 — a hand-edit of
  `.git/hooks/*`, `.git/info/exclude`, or a nested/submodule `.git/`
  can inject hooks or corrupt repo state just as a `.git/config` write
  rewrites identity). Reads of `.git/` files are not writes and are
  unaffected. If you need a scratch file, write it under
  `<repo-root>/.claude/tmp/` (gitignored). The containment-escape denies
  (#127, #148) are **prescriptive** (#30): a write/edit escape names
  `<repo-root>/.claude/tmp/` as the scratch destination and warns
  against `.git/`, so an open-ended denial does not induce the model to
  improvise a bad landing spot. See
  [`rules/scratch-file-location.md`](../../rules/scratch-file-location.md)
  for the convention. (3) **reading** a non-`.git/` file that resolves
  into the primary clone / shared git dir is **contained/defer** (ALLOW
  on the read-only-utility track), not an ASK (#130): a linked worktree
  shares tracked content with the primary clone, so reading a file like
  `plugin.json` there discloses nothing the worktree's own history
  doesn't already have. This applies to the `Read` tool and to
  bash-read commands (`cat`, the read-only-utility set, `less`/`more`/
  pagers via `classifyPathReader`) alike. The `.git/`-tree deny is
  checked BEFORE this relaxation and survives independently for reads
  too — `cat <primary-clone>/.git/config` still denies. The **write**
  side is unaffected: Write/Edit/MultiEdit/NotebookEdit and the
  in-repo-write shell classifier still DENY a target that resolves to
  the primary clone (#127), and #148 cross-repo reads/writes are
  unaffected by this carve-out (it only relaxes the primary-clone /
  common-dir case, not a genuine sibling repo). (4) a leading `~` or
  `~/...` in any operand is expanded against the real home directory
  BEFORE the relative-join/canonicalize step (#131 follow-up review),
  mirroring the tilde handling Engine A's `applyCd` already does for
  `cd ~`. Without this, `~/.ssh/id_rsa` is not `filepath.IsAbs` and
  would silently fall through to the relative-join branch, resolving
  as `<base>/~/.ssh/id_rsa` — a literal, in-repo-looking child path
  that masked an escape to the user's real home directory as
  `contained`. This was a genuine fail-open (found via a for-loop
  brace-list escaping member, `{a.md,~/.ssh/id_rsa}`, but pre-existing
  and reachable through any single-operand path too, e.g. plain
  `cat ~/.ssh/id_rsa`) — now it earns the escape verdict its real
  location deserves. If the home directory cannot be resolved (`HOME`
  unset/empty — real in cron jobs, minimal containers, stripped
  environments), the containment layer (`testContainmentFrom`) treats
  the operand as an unconditional `escapeRepo` — denied, never
  `contained` — genuinely mirroring `applyCd`'s fail-safe posture
  (invalidate rather than guess) rather than merely claiming to. An
  earlier version of this fix (PR #139 round 3) left `~` as a literal
  relative segment in this branch instead, which actually resolved as
  `<base>/~/...` and read as `contained` — a live fail-open, caught by
  round-3 review and closed by threading the resolver's
  home-unresolvable signal through `testContainmentFrom` directly (see
  `canonicalizeFromResolver` in `engine_b_containment.go`).

The decision is emitted as JSON on stdout with exit 0
(`permissionDecision: allow|deny|ask|defer`). Exit 2 + stderr is the
fail-closed backstop for crash / parse-error / panic / malformed-event
paths.

Every ASK and DENY is appended to an evolution log
(`~/.claude/logs/permission-gate.jsonl`, overridable via
`PERMISSION_GATE_LOG`) for promoting recurring ASKs into explicit
rules.

## Rules are compiled in

Policy lives in the binary, not on disk — a security gate's rule set
must not be runtime-editable. **Changing policy means editing the Go
source, re-running the test suite, rebuilding both binaries, and
recommitting them.**

## Build / test / cross-compile

```sh
# From the repo root (the hook lives under plugins/guardrails/):
go -C plugins/guardrails/hooks/permission-gate test ./...   # run the test suite
go -C plugins/guardrails/hooks/permission-gate vet ./...    # static checks

# Rebuild the committed binaries (pure Go, CGo disabled):
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
  go -C plugins/guardrails/hooks/permission-gate build -trimpath -o ../bin/darwin-arm64/permission-gate .
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
  go -C plugins/guardrails/hooks/permission-gate build -trimpath -o ../bin/linux-amd64/permission-gate .
```

### Binary reproducibility (don't expect a byte-identical rebuild)

Go automatically stamps VCS info into every binary — `vcs.revision`
(the git commit) and `vcs.modified` — embedded in the build metadata,
and the build-ID's content-hash segment incorporates it too. So a fresh
`-trimpath` rebuild of the **same source** at a **different** git HEAD
(or with uncommitted changes) is **not** byte-identical to the committed
binary, even though the compiled code is identical. The committed binary
was stamped with whatever revision was HEAD when it was built (often a
parent of a later comment-only commit); a rebuild stamps a different
revision. The differing bytes cluster only in the buildinfo / build-ID
regions — typically a few hundred bytes — never in code. This is benign
and expected, **not** a source/binary mismatch.

To correctly verify that a committed binary matches its source:

1. Compare against the **immutable git object**
   (`git show <commit>:<path>`), never the mutable working-tree file —
   a concurrent session can rewrite the working-tree blob mid-check.
2. Inspect build metadata with `go version -m <binary>`: confirm the Go
   version, module path, dependency hashes (e.g. the `mvdan.cc/sh/v3`
   version and its `h1:` hash), and build flags (`-trimpath=true`,
   `CGO_ENABLED=0`) all match. Expect **only** `vcs.revision` /
   `vcs.modified` to differ.
3. Confirm the compiled code is identical despite the byte delta: the
   build-ID content-hash segment matches, and `go tool nm` symbol tables
   are byte-identical. A raw `cmp` / `shasum` byte-diff against a rebuild
   is **not** a valid mismatch signal on its own, because of the VCS
   stamp.

Committed binaries live under `plugins/guardrails/hooks/bin/<goos>-<goarch>/`
(`darwin-arm64` for this machine, `linux-amd64` for WSL2). The
`settings.json` registration selects the correct one per platform via
`uname`.

## Registration

`settings.json` wires the gate as a single PreToolUse hook matching
`Bash|Read|Write|Edit|MultiEdit|NotebookEdit|mcp__.*`, deployed to
`~/.claude/settings.json`.

## Deferred

The per-`(session, cwd)` `git rev-parse` cache (§8 of the design)
remains deferred. Worktree roots do not move mid-session, so it is a
pure optimization for the worktree-parallel case; build it only if
profiling shows the per-call fork bites.
