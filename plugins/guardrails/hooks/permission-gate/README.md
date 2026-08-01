# permission-gate

A compiled (Go) PreToolUse hook that adjudicates the tool calls Claude
Code is about to make: **allow**, **deny**, **ask**, or **defer**. It is
the deterministic enforcement layer the OS sandbox structurally cannot
provide (issue #247). It replaces the shell hooks
`auto-approve-compound-commands.sh` and `worktree-file-guard.sh`.

## What it does

The gate's engines feed the allow/deny/ask (plus defer) decision,
ask-defaulting (uncertainty escalates to a human, never to allow):

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
  or a non-plain expansion (`${P:-x}`, `${#P}`, …) stays inexact and
  keeps escalating (fail-closed); a `VAR=x cmd` prefix sets env for
  that one command only and does not persist to later commands. A name
  absent from that in-script static-assignment map falls through to a
  **closed allowlist of process-environment-derived variables**
  (#156) — `$HOME`, `$USER`, `$TMPDIR`, `$PWD`, `$OLDPWD` — each
  resolved from its own authoritative source rather than the gate's
  ambient process environment: `$HOME`/`$USER`/`$TMPDIR` from
  `os.UserHomeDir`/`os.LookupEnv` (injectable for tests), and
  `$PWD`/`$OLDPWD` from the **same tracked running-cwd state** the `cd`
  handling below already maintains — never from the hook's own process
  env, which holds the event's cwd and would be wrong after an
  in-script `cd`. An in-script static assignment always takes
  precedence over that allowlist when both apply (`HOME=/tmp cat
  "$HOME/x"` resolves to `/tmp`). Any other env var (`$FOO`, `$PATH`,
  …) stays unresolvable — the gate does not resolve arbitrary
  environment state whose relationship to the command's actual
  environment is unverified. Static-variable resolution is
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
  the static-variable scope discipline above. Each `cd` also records the
  **prior** running cwd as `$OLDPWD`'s tracked source (#156, mirroring
  real bash), so a command that follows a `cd` and uses `$OLDPWD` (e.g.
  `cd <subdir>; cat "$OLDPWD/x"`) resolves against the directory the
  `cd` left, not the event's cwd; before any `cd` in scope, `$OLDPWD` is
  untracked and fails closed. A sibling mechanism, the **command-substitution
  anchor allowlist** (#132), recognizes an assignment RHS that is EXACTLY one
  of the anchor command substitutions — `$(git rev-parse --show-toplevel)` (this
  worktree's root), `$(git rev-parse --git-common-dir)` (the shared git dir,
  which a later use still runs through the `.git/` deny), and `$(pwd)` /
  `` `pwd` `` (the cd-tracked running cwd, #129, not the event's raw cwd) —
  and records its resolved value into the static-assignment map instead of
  dropping the variable as unresolvable. Matching is exact: extra flags, extra
  arguments, or the substitution combined with other word parts is not an
  anchor and falls through to the existing fail-closed drop. Anchor
  resolution never bypasses containment or the `.git/` deny — it only lets a
  known-safe location resolve statically instead of failing closed on a
  dynamic RHS. This is a distinct mechanism from the five-variable
  `$HOME`/`$USER`/`$TMPDIR`/`$PWD`/`$OLDPWD` allowlist above: that allowlist
  resolves bare *variable* references from authoritative sources, while the
  anchor allowlist resolves specific *command-substitution* forms. A `for x
  in <words>; do
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
  `ls`, `grep`, `printf`, `echo`, `basename`, `dirname`, `true`,
  `false`, `seq`, `yes`, plus the conditionally-read-only `sed`, `awk`,
  `jq`, `find`, and `tee` — **ALLOWs** the provably non-mutating form
  instead of deferring (a defer then matches no `settings.json` allow
  entry and prompts the user, the single largest prompt source). The
  ALLOW is
  withheld — the line **defers** — when a real-file redirect (other
  than one whose every destination is a session-shaped harness
  scratchpad, #193) or a
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
  `git rev-parse` fork of their own. Pagers / binary dumpers (`less`,
  `more`, `od`,
  `xxd`, `hexdump`) are deliberately out of this ALLOW set: they keep
  the prior path-reader posture (contained → defer, escape →
  deny/ask). A redirect target built from a process substitution or
  unresolved expansion (`wc < <(grep x f)`, `cmd > "$DYNAMIC"`) marks
  the command unprovable so it cannot ride the allow track.
  `ls` joined the set in #193: it was in neither bash read track, so it
  deferred for every path while `find` and `grep` — both strictly more
  capable — allowed, and the scratchpad carve-out's own worked example
  (an `ls` of the bundled-skills hash directory) was false. It is
  path-bearing like the rest, so an `ls` of a path outside the repo now
  earns the ordinary #148 read deny rather than a defer. Its
  fail-safe predicate models only flags that are bools in **both** GNU
  and BSD `ls`; the short flags whose arity diverges (`-I`, `-T`,
  `-w`) are left unmodelled and defer, because modelling them as value
  flags would let the BSD spelling `ls -I <path>` swallow its only path
  operand and skip containment entirely.
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
  unresolved expansion **asks** (#1); a real-file redirect **defers**
  unless every destination is a session-shaped harness scratchpad
  (#193), the same graded veto the read track carries.
  `rm` is deliberately **excluded** (the conservative #32 posture): the
  highest-blast-radius mutating program stays on the ask/defer track so a
  human sees each one. `sed` and `tee` are dual-mode — their read-only
  forms (`sed -n`, `tee /dev/null`) stay on the read-only-utility track;
  only the mutating form routes here.
- **Dangerous git / gh / aws classifier** (`classify_command.go`,
  `rules.go`, #64, #163): the deny/ask half of the command classifier
  for the tools whose remote operations can damage or expose a
  remote GitHub repo (`git`/`gh`) or exfil credentials/data or mutate
  remote cloud state (`aws`). The classifiers **never defer** — every
  path resolves to allow/ask/deny. The tiering rests on the **#163 "two
  boundaries, split by visibility"** role (which replaces the earlier
  "the hook is a filter; containment lives in the microVM" premise):
  the microVM's egress proxy is the **network boundary** — it filters
  on the CONNECT target host and, inside an allowed TLS session, sees
  only ciphertext (method, path, and body are invisible to it). The
  gate is the **semantic boundary for exactly that blind spot** — what
  the guest's credential may do at an already-allowed host. So a
  classifier miss on a **guest-local** effect costs nothing (the box is
  disposable), but a miss on a **credential-carrying remote** operation
  has no proxy backstop at all, and the two are tiered accordingly:
  - For **`git`**, the ALLOW default covers only the guest-local
    subcommands (commit, add, checkout, rebase, …), which the
    disposable microVM contains and which git's content-addressed
    objects make recoverable (#64 principle 4) — neither justification
    involves the proxy. The remote-touching shapes (push refspecs,
    `remote add`/`set-url` re-aim) are individually classified in the
    deny/ask tiers, because a credential-carrying push to an allowed
    host is the proxy's blind spot.
  - For **`gh`**, ALLOW is **no longer a floor** (#163): it is a
    property of an **enumerated verb** — recognized reads
    (`isGhReadOnly`) and an enumerated recoverable-own-repo-write set
    (`isGhRecoverableWrite`: `pr create`/`comment`/`merge`/`close`,
    `issue create`/`comment`/`close`/`edit`, `label`, …). An
    **unrecognized `gh` noun/verb ASKs** (fail-closed, #64 principle 2)
    rather than the pre-#163 silent ALLOW. An enumerated write whose
    explicit target (`-R`/`--repo`, or a `gh api` `repos/{owner}/{repo}`
    segment) differs from the session's `origin` **ASKs** — an
    exfil-by-write to a foreign repo (`gh issue comment -R attacker/repo
    …`) rides inside the same allowed-host TLS the proxy cannot inspect;
    reads stay unscoped. The companion `git remote add`/`set-url` ASK
    closes the git version of that channel.
  - For **`aws`** the default is **ASK** (#124): an aws mutation is not
    a guest-local operation — it carries the guest's credentials to a
    control plane outside the microVM and mutates real cloud state the
    VM cannot roll back, and the egress proxy gates only host:port/SNI,
    not the operation inside the TLS. Only the read-only ops keep an
    ALLOW default; see below.
  Across all three, **host redirection** (`--hostname`, inline
  `GH_HOST=`/`GIT_SSH_COMMAND=`/`AWS_ENDPOINT_URL=`, `-c
  core.sshCommand`) keeps its **DENY**: it is the one surface the proxy
  genuinely owns (it changes the CONNECT target the proxy filters on),
  so the gate DENYs it to keep that single real control intact.
  Bypass gates fire BEFORE per-command logic, since each reaches a
  dangerous outcome without the flag a naive policy keys on:
  (1) a **non-static argv** (command substitution, unresolved variable,
  glob) on any of those tools **denies** — the dynamic token can
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
  an ordinary fast-forward push **allow**; and **`git remote add`/
  `set-url`** (which re-aim where a later ALLOWed push sends its
  refspec) **ask** (#163) — the git version of the gh foreign-target
  exfil channel. For `gh`: `gh api` is routed
  through a method/body/endpoint gate (#64, extended by #113 and #162).
  A REST write — a non-GET method, an implicit-POST-flipping body flag
  on a REST endpoint, or an `x-http-method-override` header — **asks**
  (#162): a `gh api` REST write is a credential-carrying mutation of
  remote repo state the microVM cannot roll back, the same
  not-backstopped-by-containment class as an `aws` mutation (#124) and a
  `git push` refspec, so it gets a one-click human ask rather than a
  no-escape-hatch deny. `--hostname` (which aims the signed request at a
  non-default host — the gh analog of `--endpoint-url`) keeps its own
  **deny**: it is the one shape the egress proxy's host-allowlist can
  see and control, not a write/read question. On the `graphql` endpoint
  the gate now **classifies the query document** instead of blanket-denying (#113):
  a document supplied literally via `-f query=…` / `--raw-field
  query=…` is scanned (string literals and `#` comments stripped) and,
  if every top-level construct is provably a `query`, the anonymous
  `{…}` shorthand, or a `fragment`, it **allows**; a **fragment-free**
  mutation document whose **every** top-level mutation field is on the
  curated issue-metadata allowlist (#195 — `setIssueFieldValue`,
  `updateProjectV2ItemFieldValue`, `addProjectV2ItemById`,
  `updateIssueIssueType`, `addSubIssue`, `removeSubIssue`,
  `addBlockedBy`, `removeBlockedBy`, `closeIssue`, `reopenIssue`; the
  GraphQL spelling of the recoverable-write verbs `gh` already allows,
  plus the issues plugin's metadata verbs) also **allows**, with
  aliases resolved to the real field name first; any other
  mutation-bearing document **asks** with the mutation field names in
  the reason (so the human sees `addSubIssue` vs `deleteIssue`), and a
  document bundling an allow-listed field with anything else — an
  off-list field or a subscription — asks too, because a
  multi-operation document is judged by its broadest operation. The
  fragment-free requirement is what keeps that judgement honest: the
  scanner names the identifier that follows a `...` and never expands
  the fragment's own body, so without it a spread named after an
  allow-listed field would launder an arbitrary mutation past the
  allowlist (`mutation { ...addSubIssue } fragment addSubIssue on
  Mutation { deleteIssue(…) }` — GitHub's mutation root type is
  literally `Mutation`, so that type condition executes). Any `...`
  spread or `fragment` definition therefore withholds the #195 allow
  and the document keeps its mutation **ask**, even when the fragment
  is benign; the query-only allow above is unaffected, since a query
  operation's fragments cannot reach a mutation field. Those
  allow-listed mutations address opaque node IDs, so (unlike the #163
  `-R` check) the gate cannot see which repo the target belongs to;
  accepted because the writes are recoverable, land on human-visible
  surfaces, and need only write access the credential already holds. A
  subscription, unbalanced/garbage document, or a query supplied
  non-literally (`-F query=…`, which does `@file` expansion /
  coercion, or `--input`) **denies** as unclassifiable. On a REST
  endpoint the gate runs a path-prefix GET-gate (#113): a
  known-flag-only GET whose endpoint is on the read allowlist (exact
  `rate_limit`/`meta`/`user`;
  segment-bounded `repos/`, `orgs/`, `users/`, `search/`, with a
  leading `/` and any `?query` suffix stripped first) **allows**; a
  `://`- or `..`-bearing endpoint **denies**; an unknown flag or a
  non-allowlisted endpoint **asks** (the two owner-decision deviations
  from the appendix GET-gate — a false ask costs one click, whereas a
  hard deny would recreate the no-escape-hatch wall this gate exists to
  remove). The egress proxy backstops a GET only against a
  **disallowed** host; against an already-allowed host it sees
  ciphertext and cannot distinguish a read from an exfil, so the GET
  allowlist (not "no-egress") is the gate's own control here (#163).
  Irreparable verbs
  (`repo`/`release`/`issue`/`gist delete`, `secret`/`variable`
  writes, `repo rename`/`transfer`, `ruleset delete`) **deny**;
  `repo edit --visibility`, `release create`, and `gist create --public`
  **ask**. Beyond those carve-outs, a recognized gh command ALLOWs only
  when it is an enumerated read or an enumerated recoverable-own-repo
  write (#163); an **unrecognized noun/verb asks** (fail-closed), and an
  enumerated write whose explicit `-R`/`--repo` target differs from the
  session `origin` **asks** (foreign-target exfil-by-write scoping —
  reads stay unscoped). The leading global-flag screen is parsed before
  the noun/verb so a value-taking global (`-R owner/repo`) has its value
  token consumed (otherwise `gh -R owner/repo issue delete` would read
  the slug as the noun and slip the delete past the deny tier) — and
  that same parsed `-R`/`--repo` value feeds the foreign-target scoping;
  an unrecognized leading global fails closed (**deny**) rather than
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
  substring-matched) **allow**. **The credential-read decision is
  whitelist-anchored, not a blacklist (#97).** Under #64/#124 the
  credential-read tier was an exact-pair blacklist (`sts
  get-session-token`, `ecr get-login-password`, …) with an ALLOW floor
  underneath it — a `get-*` op the blacklist did not name reached ALLOW
  via the `get-` prefix, and on this surface a miss costs a **leaked
  secret**, not a prompt. The credential surface cannot be exhaustively
  enumerated (`eks get-token`, `redshift get-cluster-credentials`, `sso
  get-role-credentials`, `lightsail get-instance-access-details`, plus
  whatever AWS ships next), so the exact-pair blacklist is always one
  release behind. To make the **allow side** default-deny-shaped by
  construction, any `get-*` operation whose NAME carries a
  credential-material token (`credential`/`credentials`/`token`/
  `password`/`secret`/`details`, matched as whole hyphen segments) is
  pulled to the credential-read **ask** tier regardless of service —
  a `get-*` is allowed only if it does NOT look credential-shaped. The
  failure asymmetry is the guide (the #163 role, applied to the floor
  itself): a benign `get-*` that happens to carry such a segment costs
  one spurious prompt (cheap, the accepted cost on the allow side),
  whereas a missed credential read costs a leak (unacceptable). The
  signal is scoped to the `get-` prefix on purpose — `get-*` fetches one
  named resource, so a credential-material segment means the resource IS
  credential material, whereas the convention-allowed `list-*`/
  `describe-*` reads return collections/metadata (e.g. `iam
  list-access-keys`, `codecatalyst list-access-tokens` return
  identifiers, never the secret) and stay ALLOW. The gh analog is `gh
  auth token` (prints the active token) — noun `auth` is not in
  `isGhReadOnly`'s known nouns, so it falls to the #163 fail-closed
  **ask**. **Every other aws op — including
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
  unaffected. If you need a repo-scoped scratch file, write it under
  `<repo-root>/.claude/tmp/` (gitignored). The containment-escape denies
  (#127, #148) are **prescriptive** (#30): a write/edit escape names
  `<repo-root>/.claude/tmp/` as the scratch destination and warns
  against `.git/`, so an open-ended denial does not induce the model to
  improvise a bad landing spot. As of #193 they name a **second**
  destination alongside it — the harness scratchpad,
  `<system-tmp>/claude-<uid>/` — for a file that must outlive this repo
  or this session, and the read-side denies name that handoff location
  too; prescribing only the in-repo path left a genuine cross-repo
  handoff with no legal landing spot, which is the same open-ended
  denial in a different disguise. The in-repo destination is emitted as
  the **resolved** root the gate is already holding (`rc.topLevel`, the
  same value the cross-repo deny prints as `repo root %s`), not as the
  literal `<repo-root>` placeholder written here and not as a
  `$(git rev-parse --show-toplevel)` incantation for the model to run —
  a placeholder resolves to the primary clone as easily as to the
  agent's own worktree. `scratchDestinations` is the single helper every
  deny that names it calls, and
  `TestScratchDestinationsNameResolvedRoot_193` guards the property
  across its call sites (the read-side denies name only the handoff
  location, via `handoffHint`). See
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
  `canonicalizeFromResolver` in `engine_b_containment.go`). (5) a
  target whose canonical path lands under the harness's per-uid
  scratchpad root, `<system-tmp>/claude-<uid>/`, is carved out of the
  `/tmp` deny (#193). The harness provisions that tree and actively
  directs the model to put temporary files there, so treating it as an
  ordinary `/tmp` escape made the gate fight the harness: a hook deny
  beats a `settings.json` allow, leaving the scratchpad unusable from
  every repo session and leaving cross-repo / cross-session handoff
  with no sanctioned home at all. The verdict is **graded on where
  inside the prefix the target lands**, not a blanket defer:

  | canonicalized target | verdict |
  | --- | --- |
  | under the prefix, remainder matches the session shape | `allow` |
  | under the prefix, remainder matches the bundled-skills shape, call is **read-class** | `allow` |
  | under the prefix, remainder matches the bundled-skills shape, call is **write-class** | `defer` |
  | under the prefix, remainder matches neither shape | `defer` |
  | the `claude-<uid>` root is not a plain, this-uid-owned directory | `ask` |
  | anything else under `/tmp` | `deny`, as before |

  `allow` rather than `defer` for the session shape is deliberate:
  writing to the scratchpad is precisely what we want to permit, and a
  defer would leave the feature dead until every `/tmp` entry is
  removed from `settings.json` — a hook allow outranks that list, a
  defer does not. See `decision.go` for the restated bar `BucketAllow`
  now holds.

  The **session shape** is matched against the remainder left after
  stripping the canonical root, never the full path, so the pattern is
  platform-independent by construction and contains neither `/tmp` nor
  `/private/tmp`:
  `(-+[A-Za-z0-9]+)+/<uuid>/(scratchpad|tasks)(/|$)`. `<uuid>` is the
  loose `8-4-4-4-12` hex shape with the version nibble deliberately
  unpinned, so a generator change cannot break the match. A shape miss
  costs a `defer`, not a denial, which is what makes a pattern this
  tight affordable. The carve-out still covers the whole **per-uid
  prefix** rather than the current session's own subdirectory, because
  reading back what another session wrote is the point.

  The `-+` in the project-slug part is load-bearing. The slug is the
  session's absolute cwd with **every** non-alphanumeric character
  rewritten to a dash, so any hidden directory in the path produces a
  run of consecutive dashes — `/Users/<u>/.claude` slugs to
  `-Users-<u>--claude`, and `/Users/<u>/.config/macos-setup` to
  `-Users-<u>--config-macos-setup`, both ordinary session directories
  with the standard `scratchpad`/`tasks` layout. The first
  implementation round shipped a single-dash-only
  `(-[A-Za-z0-9]+)+`, faithfully implementing an earlier revision of
  #193's spec, and thereby excluded every such session — silently
  reintroducing this issue's own symptom for them. The widening stops
  at the quantifier: the character class stays `[A-Za-z0-9]`, which is
  exactly the alphabet the harness emits.
  `TestHarnessShapesMatchLiveLayout_193` walks the machine's real
  prefix and asserts every existing session directory matches, so the
  next such claim is checked against the filesystem rather than
  against the issue body.

  The **bundled-skills shape** covers the harness-managed, non-session
  sibling living under the same prefix,
  `bundled-skills/<version>/<32-lowercase-hex>/<skill-name>/...`. It is
  the one carve-out whose verdict is **read/write-graded**: a read is
  `allow` (reading a bundled skill is what the tree is for), a write is
  `defer` (the content is harness-installed, so the gate has no
  positive grounds to bless a rewrite — but neither is it an escape to
  deny; the classifier decides). The grading uses the read/write
  predicate each track already has — `isMutatingFileTool` on the
  file-tool track, operand position (`containPathOperands` vs.
  `containWriteOperands`) on the bash track — and every track asks the
  single `scratchAllowEligible` helper for the verdict rather than
  restating it in its own switch, so they cannot drift. The redirect
  grading below asks the same helper, passing `readClass=false`,
  because a redirect destination is a write. The match ends at `(/|$)`
  right after the 32-hex segment, so an `ls` of the hash directory
  itself is covered, not only files beneath it — an example that is
  true only because `ls` is on the read-only-utility ALLOW track; it
  was not until #193's third round, and the claim was false until then.

  The version component is **shape**-checked (`major.minor.patch`) and
  deliberately not pinned to the running Claude Code version: the hook
  event carries no version field, so the only source would be
  `CLAUDE_CODE_EXECPATH` in the environment — the same defect that
  rules out `os.TempDir()`/`$TMPDIR` below. Shape-checking also
  survives an upgrade, where the previous version's directory lingers
  beside the new one. The evidence base here is narrower than for the
  session shape (one version directory, one hash directory, one
  machine), so a channel-tagged version such as `2.1.220-beta.1` is a
  known miss — costing a read a `defer`, never a denial.

  `<uid>` comes from `os.Getuid()` at runtime — never hardcoded, never
  a `claude-*` glob, which would match another user's prefix
  (`claude-501` and `claude-503` do coexist on real machines). The
  system temp directory is the literal `/tmp` and NOT `os.TempDir()`:
  `os.TempDir()` honours `$TMPDIR` (a `/var/folders/...` path on macOS
  that the harness does not use), and deriving a security carve-out
  from an environment variable would let whatever set that variable
  relocate it to an arbitrary directory.

  **Both `/tmp` and `/private/tmp` spellings** are handled by
  canonicalizing *both sides*, with no literal enumeration of either.
  Enumerating the two literals would be actively wrong on Linux, where
  there is no `/tmp` symlink and `/private/tmp` is a genuinely
  different directory a literal allow-list would wrongly match.

  **Symlinks.** The threat is Claude Code writing to a wrong path,
  accidentally or otherwise — not a hostile local user contesting the
  region. Only the `claude-<uid>` root gets its own check
  (`os.Lstat` on the final component after `EvalSymlinks` on the
  parent; `Lstat`-ing the whole path would break macOS outright, where
  `/tmp` is itself a symlink), and a defective root yields the `ask`
  above with a reason naming the defect, so the failure is not mistaken
  for this bug reappearing. Nothing **below** the root needs a check:
  canonicalization already resolves those components and produces a
  better verdict than an `Lstat` refusal would — a symlinked
  `scratchpad` -> `~/.ssh` resolves out of the region and earns the
  ordinary deny. The root is the unique hole for a structural reason:
  the root is canonicalized too, so a symlink *there* moves the
  comparison root together with the target and `pathUnder` still
  matches, whereas every other component moves only the target and the
  mismatch surfaces on its own. A symlink pointing *within* the region
  is cross-session handoff working as intended, and is allowed.

  **Reaching the carve-out from bash.** A carve-out the bash track
  cannot reach is not a carve-out, and two gates sat in front of this
  one until #193's third round. The first was the read-only-utility
  table's missing `ls`, described above. The second was the redirect
  veto: `allowEligible()` returns false whenever `hasRedirectToFile` is
  set, so `echo x > <scratchpad>/f` could never reach an ALLOW however
  well-contained it was — while `tee <scratchpad>/f` and
  `cp <src> <scratchpad>/f` write the same bytes to the same region
  under an ALLOW, via `containWriteOperands`. The veto's stated
  rationale is exfiltration / clobber risk, which is exactly what this
  region is designated safe against by construction, and two spellings
  of one write cannot carry two verdicts. So `redirectVetoesAllow`
  grades the destination instead of vetoing on the bare bool, and lifts
  **only** for the session shape: an in-repo destination, the
  bundled-skills tree, the unshaped remainder of the prefix, and `/tmp`
  at large all keep the veto, as do a destination the gate cannot
  resolve statically (#1), an unresolvable running cwd (#129), and a
  command whose *other* redirect escapes the region. The lift reaches
  exactly the two allow tracks that call `redirectVetoesAllow` — the
  read-only-utility classifier and the in-repo-write classifier. The
  credentialed-tool classifiers are untouched: `git`/`gh`/`aws` keep
  their unconditional redirect-to-file **ask**, and `acli` keeps
  gating its read-only allow on the ungraded `allowEligible()`, so a
  redirect there still **defers**. Those guard credentialed command
  output, a different concern from where a scratch file lands.

  Every other `/tmp` path — including another uid's
  `/tmp/claude-<other-uid>/` — still earns the ordinary `#148` deny.
  Neither the carve-out nor the root `ask` short-circuits the operand
  walk, so `cp <scratchpad-file> <sibling-repo-path>` still denies on
  its destination.

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
