package main

import (
	"fmt"
	"strings"
)

// classifySimpleCommand applies the compiled rule set to one reduced command.
// Order of precedence:
//
//  1. A synthetic redirect-only command (no program at all, just redirects the
//     shell performs) → graded on the paths those redirects open.
//  2. A command we cannot statically pin (no program token) → DEFER (with the
//     analysis; it never reaches the allow track).
//  3. A command with a redirect to a real file → DEFER (the normal pipeline's
//     allow-list will not match it; we do not auto-allow exfiltration) — unless
//     every destination is a session-shaped harness scratchpad, the one
//     region designated safe by construction. See redirectVetoesAllow.
//  4. Program-specific DENY / hard-ASK / DEFER rules (git, gh, aws identity,
//     etc.).
//  5. Program-specific ALLOW rules (read-only git/gh/aws/acli).
//  6. Path-bearing read/write programs → Engine B containment.
//  7. Otherwise DEFER to the normal pipeline, labelled bash:no-specific-rule
//     (deferResidualOp) so the §7 log records which program went unrecognized.
func classifySimpleCommand(sc simpleCommand, ev *Event) Decision {
	// Redirects the shell performs for a construct that runs no program
	// (`[[ -f x ]] > f`, `(( i++ )) > f`, `export A=1 > f`, `case q in esac > f`).
	// Graded BEFORE any program dispatch: args[0] holds a display name, not a
	// program, so it must never be matched against a rule table.
	if sc.redirectOnly {
		return classifyRedirectOnly(sc, ev)
	}

	if len(sc.args) == 0 {
		return deferJudgment("bash:no-program",
			"could not determine the program for a command part, so there is nothing to classify.")
	}

	prog := basename(sc.args[0])
	args := sc.args[1:]

	// A command with a command substitution or unresolved expansion in ANY
	// argument cannot be statically proven safe. It must never ride the
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
		return classifyAws(args, sc, ev)
	case "acli":
		return classifyAcli(args, sc)
	case "less", "more", "od", "xxd", "hexdump":
		// Read-class pagers / binary dumpers whose path arguments must stay
		// inside the repo (do not read a sibling repo's node_modules to
		// verify APIs). Contained reads DEFER; only an escape denies. These
		// are deliberately NOT in the read-only-utility ALLOW set — they
		// are interactive / binary-dump tools, out of that track's scope.
		return classifyPathReader(prog, args, sc, ev)
	}

	// Curated in-repo-write ALLOW track (cp/mv/mkdir/touch/sed -i/tee FILE).
	// A file-mutating program ALLOWs when every path operand it writes is
	// contained in the current worktree; an escaping operand denies.
	// Dual-mode programs (sed/tee) are ALSO in readOnlyUtilities: route to this
	// classifier only for the genuinely-mutating form (mutatesFn), and let the
	// read-only form fall through to the read-only-utility classifier below.
	// Pure writers (cp/mv/mkdir/touch — no mutatesFn) always route here.
	if spec, ok := inRepoWriters[prog]; ok {
		if spec.mutatesFn == nil || spec.mutatesFn(args, sc) {
			return classifyInRepoWrite(prog, args, sc, ev)
		}
	}

	// Curated read-only-utility ALLOW track (cat/head/sed -n/awk/printf/…).
	// The proven read-only form of these high-frequency text/data utilities
	// ALLOWs (no real-file redirect, no unknown expansion, no mutating flag,
	// path operands contained); everything else defers. cat/head/tail used to
	// route to classifyPathReader above (DEFER on contained); they now ALLOW the
	// read-only form here.
	if _, ok := readOnlyUtilities[prog]; ok {
		return classifyReadOnlyUtility(prog, args, sc, ev)
	}

	// No specific rule. The gate has no opinion on the program itself; hand the
	// call back to the pipeline.
	//
	// It defers WITH an account rather than bare, even though the account is
	// thin. This is the residual an unrecognized program reaches —
	// `npm test`, `python3 x.py`, `make`, every tool the gate has no table for —
	// so it is by volume the largest single source of DEFER records, and a blank
	// `{"operation":"","analysis":""}` row makes exactly that traffic invisible
	// to the automode re-tune the §7 log feeds. The program name plus "no rule
	// matched" is the whole of what the gate established, and it is enough to
	// bucket the log by program.
	return deferJudgment(deferResidualOp, fmt.Sprintf(
		"no permission-gate rule matches the program '%s': it is on none of the classifier tables "+
			"(git/gh/aws/acli), none of the in-repo-write or read-only-utility sets, and none of the "+
			"path-reader set, so the gate established nothing about it either way.", prog))
}

// deferResidualOp is the §7 operation label for the no-specific-rule residual
// above. It is named rather than inlined because the aggregator in
// engine_a_bash.go ranks it BELOW every other defer analysis: for a line like
// `npm test && git reset --hard`, the account worth logging is the one from the
// arm that recognized something, not the residual that fired first.
const deferResidualOp = "bash:no-specific-rule"

// classifyRedirectOnly grades a synthetic redirect-only command: a statement
// whose redirects the shell performs even though there is no program attached to
// them (a bare `> f`, `[[ -f x ]] < /etc/passwd`, `(( i++ )) > <out-of-repo>`,
// `export A=1 > f`, `case q in esac > f`, a bare `A=1 > f`). Before this branch
// existed those redirects were graded nowhere: the construct emitted no command,
// so `[[ -f x ]] > <out-of-repo> && echo hi` reduced to the lone allow-eligible
// `echo hi` and ALLOWed while the shell created the out-of-repo file.
//
// The grading deliberately mirrors classifyReadOnlyUtility for a utility with no
// path operands of its own, in the same order — redirect veto, then read
// containment, then the unknown-expansion fallback — because that is exactly what
// this is: no argv to inspect, only the paths the redirects open. Reusing the
// shape (and the same two helpers) is what keeps a redirect from carrying one
// verdict when attached to `echo` and a different one when attached to a
// construct, which is the inconsistency the redirect work exists to remove.
//
// So a destination outside the carve-out defers exactly as `echo x > <dest>`
// does, a session-scratchpad destination allows exactly as `echo x >
// <scratchpad>/f` does, and an out-of-repo input source denies exactly as
// `cat < <src>` does.
func classifyRedirectOnly(sc simpleCommand, ev *Event) Decision {
	prog := sc.args[0]

	// A real-file destination the carve-out does not cover keeps the veto, so the
	// write lands back in the normal pipeline rather than on the allow track.
	if redirectVetoesAllow(sc, ev) {
		return deferToPipeline()
	}

	if len(sc.inputRedirectTargets) > 0 {
		// A source built from an expansion the gate cannot resolve, or a relative
		// one after a dynamic `cd`, cannot be contained — DEFER, the same posture
		// the read tracks hold for an unresolvable operand.
		if sc.hasUnknownExpansion {
			return deferJudgment("bash-read:dynamic-path", fmt.Sprintf(
				"'%s' opens a path built from an expansion the gate cannot resolve statically, so containment "+
					"cannot be run on it.", prog))
		}
		if d, hit := cdInvalidDefer(prog, sc); hit {
			return d
		}
		// containPathOperands is called directly rather than through
		// containInputRedirects: this is not a write command borrowing the read
		// grading, so its terminal ALLOW for an all-scratchpad source must be
		// delivered rather than discarded.
		if d, ok := containPathOperands(prog, sc.inputRedirectTargets, sc, ev); !ok {
			return d
		}
	} else if sc.hasUnknownExpansion {
		// No path to contain, but a redirect the gate could not pin statically
		// (`>& $FD`, a heredoc delimiter built from an expansion) still may not
		// ride the allow track.
		return deferToPipeline()
	}

	return allow("every path this shell redirect opens is contained, or lands in a region designated " +
		"safe by construction")
}

// preconditionDeny applies the precondition shared by the git/gh/aws
// classifiers BEFORE any per-command logic: no inline environment-assignment
// prefix, and no dynamic token in a CLASSIFICATION-BEARING argv position.
// Either shape can reach a dangerous outcome without the flags the policy keys
// on (`AWS_ENDPOINT_URL=… aws …` redirects egress; `git $OP` hides the
// subcommand), so a hit DENYs rather than allowing. Returns the deny Decision
// and true on a hit; the zero Decision and false otherwise.
//
// This precondition is one of the arms that keeps every path through the
// git/gh/aws classifiers ACCOUNTED FOR: callers convert a non-static command
// into a concrete DENY here rather than handing it back to the pipeline
// unlabelled. (Those classifiers do not "never defer": their residual and
// their context-dependent arms ride deferJudgment — but a defer they return
// carries an operation label and an analysis, never silence.)
//
// The argv half used to fire on the whole-command hasUnknownExpansion bool, so
// ANY dynamic token anywhere denied. Its rationale — a dynamic token can hide a
// dangerous operation — holds only for a token that could occupy a position the
// classifiers read: the noun, the verb, the endpoint, or a value-taking global
// like `-R`. It does not hold for a token the parser has already established is
// the VALUE of a field/output flag, which can never become a subcommand. The
// practical cost of the un-scoped form was that the ordinary GraphQL chain
// (capture a node ID, feed it to the next mutation) could not be scripted at
// all, and there is no escape hatch from a deny — which pushed the issues
// plugin's skills into pasting opaque node IDs as literals, strictly harder for
// a human to review than the variable-carrying form.
func preconditionDeny(tool string, sc simpleCommand) (Decision, bool) {
	if sc.hasInlineAssignment {
		return deny(tool+" inline-env-assignment",
			"Blocked: an inline environment-assignment prefix on '"+tool+"' (e.g. "+
				"AWS_ENDPOINT_URL=…, GIT_SSH_COMMAND=…, GH_HOST=…, AWS_PAGER=…) can redirect egress, "+
				"swap identity, or inject a pager without touching the command's arguments. "+
				"Remove the inline assignment; if the variable is genuinely needed, surface it to the human."), true
	}
	if tok, hit := unshieldedDynamicArg(tool, sc); hit {
		where := "its arguments are not all static literals"
		if tok != "" {
			where = "the token '" + tok + "' is not a static literal"
		}
		return deny(tool+" non-static-argv",
			"Blocked: a '"+tool+"' command where "+where+" (a command substitution, unresolved variable, or "+
				"glob) in a position the gate classifies on — the subcommand, the endpoint, or a value-taking "+
				"global — cannot be statically classified, and could reach a dangerous operation through the "+
				"dynamic token. Spell that token literally so the gate can classify it. A dynamic value of a "+
				"field or output flag (e.g. 'gh api graphql -F itemId=$ID') is NOT blocked."), true
	}
	return Decision{}, false
}

// unshieldedDynamicArg returns the first argv token that is dynamic AND sits
// where it could still change how the command classifies. It returns
// ("", false) when every dynamic token is shielded, and ("", true) when the
// per-argument metadata is absent (a hand-built simpleCommand) but the command
// carries a dynamic token — the fail-closed fallback to the old whole-command
// behavior.
//
// A token is shielded only by being the established VALUE of a flag on the
// tool's shield table. Shielding is an ALLOWLIST, not a denylist: an
// unrecognized flag shields nothing, so a gate that has not modelled a flag
// keeps its old deny rather than waving a token through.
func unshieldedDynamicArg(tool string, sc simpleCommand) (string, bool) {
	if len(sc.argMeta) != len(sc.args) {
		return "", sc.hasUnknownExpansion
	}
	for i := 1; i < len(sc.args); i++ {
		a, m := sc.args[i], sc.argMeta[i]
		if m.exact {
			// A static flag can shield the separate value token after it.
			if i+1 < len(sc.args) && shieldsNextToken(tool, a) &&
				valueTokenShieldable(tool, a, sc.argMeta[i+1]) {
				i++
			}
			continue
		}
		// The glued spelling (`-FitemId=$ID`, `--field=itemId=$ID`, `--jq=$Q`)
		// carries flag and value in ONE token.
		if gluedValueShieldable(tool, a, m) {
			continue
		}
		return a, true
	}
	return "", false
}

// ghShieldingFlags are the gh flags whose VALUE cannot occupy a
// classification-bearing position: request fields (`-f`/`-F`), output shaping
// (`--jq`/`--template`), and free-text content (`--body`/`--title`). Every other
// gh flag — notably `-R`/`--repo` (the foreign-target write scoping reads it),
// `-X`/`--method` and `-H`/`--header` (the REST write tiers read them), and
// `--hostname` (an outright deny) — is deliberately absent, so a dynamic value
// there keeps denying.
//
// git and aws have no entry at all. Their argv is classification-bearing almost
// end to end (`git $OP`, `git -c $KV`, `aws $SVC $OP`), and neither showed a
// flag-value case worth modelling, so both keep the whole-argv posture.
var ghShieldingFlags = map[string]bool{
	"-f": true, "--raw-field": true,
	"-F": true, "--field": true,
	"-q": true, "--jq": true,
	"-t": true, "--template": true,
	"-b": true, "--body": true,
	"--title": true,
}

// ghFieldFlags are the gh flags whose value is a `key=value` request field. The
// KEY of such a value must be statically pinned and must not be `query`: for
// `gh api graphql` the `query` field IS the document the gate classifies, so a
// key the gate cannot pin could introduce a second one at run time.
var ghFieldFlags = map[string]bool{
	"-f": true, "--raw-field": true,
	"-F": true, "--field": true,
}

// shieldsNextToken reports whether flag token a consumes a FOLLOWING value
// token whose dynamism cannot affect classification.
func shieldsNextToken(tool, a string) bool {
	return tool == "gh" && ghShieldingFlags[a]
}

// valueTokenShieldable reports whether the value token following flag a may be
// left dynamic. For a `key=value` field flag the key must be statically pinned
// (its staticPrefix reaches past the `=`) and must not be `query`.
func valueTokenShieldable(tool, a string, value argMeta) bool {
	if tool != "gh" {
		return false
	}
	if !ghFieldFlags[a] {
		return true // an output/content flag: no key, nothing to pin
	}
	return fieldKeyPinned(value.staticPrefix)
}

// gluedValueShieldable reports whether a single dynamic token that carries both
// a gh flag and its value (`-FitemId=$ID`, `--field=itemId=$ID`, `--jq=$Q`) is
// shielded. The flag name must be present in the token's STATIC prefix, so a
// token whose leading part is itself dynamic is never shielded.
func gluedValueShieldable(tool, a string, m argMeta) bool {
	if tool != "gh" {
		return false
	}
	for _, long := range []string{"--raw-field=", "--field=", "--jq=", "--template=", "--body=", "--title="} {
		if !strings.HasPrefix(a, long) || !strings.HasPrefix(m.staticPrefix, long) {
			continue
		}
		if long == "--raw-field=" || long == "--field=" {
			return fieldKeyPinned(strings.TrimPrefix(m.staticPrefix, long))
		}
		return true
	}
	if len(a) <= 2 || a[0] != '-' || a[1] == '-' || len(m.staticPrefix) <= 2 {
		return false
	}
	short := a[:2]
	if short != m.staticPrefix[:2] || !ghShieldingFlags[short] {
		return false
	}
	if ghFieldFlags[short] {
		return fieldKeyPinned(m.staticPrefix[2:])
	}
	return true
}

// fieldKeyPinned reports whether a field value's static prefix pins the KEY: it
// must reach past the `=`, name a non-empty key, and that key must not be
// `query`.
func fieldKeyPinned(staticPrefix string) bool {
	eq := strings.IndexByte(staticPrefix, '=')
	if eq <= 0 {
		return false
	}
	return staticPrefix[:eq] != "query"
}

// classifyGit parses git's option grammar from the AST tokens: global options
// (`--no-pager`/`-P`, `-c k=v`, `-C path`, `--git-dir`, etc.) precede the
// subcommand. Positional guessing is obsolete — we consume globals
// explicitly, then dispatch on the real subcommand.
//
// This classifier's CATCH-ALL is ALLOW, not defer: a recognized git
// subcommand with no dangerous shape falls through to ALLOW. Defer is reached
// only from the individually-classified arms below — `git remote
// add`/`set-url`/… and a main-session `git reset --hard` — plus
// an unpinnable credentialed redirect. For git that catch-all ALLOW rests
// on a boundary the egress proxy DOES own: guest-local git effects are
// contained by the disposable microVM ("two boundaries, split by
// visibility"), and git objects are content-addressed / recoverable
// (principle 4). The remote-touching git shapes (push refspecs, remote re-aim)
// are individually classified in the deny/ask/defer tiers below — they do NOT rest on
// containment, because a credential-carrying push to an allowed host is exactly
// the proxy's TLS-opaque blind spot.
func classifyGit(args []string, sc simpleCommand, ev *Event) Decision {
	// Precondition: static argv + no inline env-assignment, gated FIRST.
	if d, hit := preconditionDeny("git", sc); hit {
		return d
	}

	// Bypass gate 3: `git -c …` / config-injection RCE. Scan the global
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

	// Identity writes (the write half of the git-config rule).
	if sub == "config" {
		if d, hit := gitConfigIdentityRule(rest); hit {
			return d
		}
	}

	// Bypass gate 2 + push rules: classify `git push` on its refspec, not
	// just its flags. A `:`-bearing or empty-source refspec, --mirror/--prune,
	// and --force all reach delete/overwrite outcomes.
	if sub == "push" {
		return classifyGitPush(rest)
	}

	// `git remote add` / `git remote set-url` re-aim a later (ALLOWed)
	// push at a different remote. That is the git version of the gh
	// foreign-target write channel: an ordinary `git push` is ALLOWed on its
	// refspec without re-checking the remote's URL, so re-pointing `origin`
	// (or adding a new remote) at an allowed-host foreign repo turns a benign
	// push into an exfil-by-push the egress proxy — which sees only the allowed
	// host, not the repo path inside the TLS — cannot distinguish. Whether a
	// given remote change is that channel or a routine one is exactly the
	// context-dependent call the tuned evaluator reads the surrounding session
	// for, so it DEFERS with that analysis rather than spending a hard prompt
	// on it. A `git remote -v` / `get-url` read is not a mutation and is
	// not caught here.
	if sub == "remote" && len(rest) >= 1 {
		switch rest[0] {
		case "add", "set-url", "set-url-add", "set-branches", "set-head":
			return deferJudgment("git remote add/set-url",
				"'git remote "+rest[0]+"' changes where a later 'git push' sends its refspec. Re-aiming a remote "+
					"at a different repo turns an otherwise-allowed push into an exfil-by-push channel the egress proxy "+
					"cannot see (it filters on host, not repo path).")
		}
	}

	// Subagent `git reset --hard`.
	if sub == "reset" && containsToken(rest, "--hard") {
		if ev.isSubagent() {
			return deny("git reset --hard (subagent)",
				"Blocked: 'git reset --hard' in a subagent discards committed and working-tree state and is forbidden. "+
					"Remediation: do NOT reset; instead release the branch and re-derive from the remote tip with a "+
					"detached checkout of origin — e.g. 'git fetch origin <branch>' then 'git checkout --detach origin/<branch>' — "+
					"or 'git switch -c <branch> origin/<branch>'.")
		}
		// Main session: still destructive, but whether it is destructive HERE
		// depends on what the working tree holds and what the session was doing
		// — context the gate cannot read and the tuned evaluator can. DEFER with
		// the analysis rather than auto-allowing. (settings.json also lists this
		// in its ask set, which still applies downstream.) The subagent case
		// above stays a DENY: there the redirect is prescriptive, which is what
		// earns that tier.
		return deferJudgment("git reset --hard",
			"'git reset --hard' discards committed and working-tree state. A safer alternative is a detached "+
				"checkout of the origin tip — e.g. 'git fetch origin <branch>' then "+
				"'git checkout --detach origin/<branch>'.")
	}

	// --- ALLOW default: every recognized git subcommand that is not a
	// dangerous shape carved out above falls through to ALLOW. Read-only
	// subcommands and ordinary guest-local mutations (commit, add, checkout,
	// rebase, …) alike are allowed: these are contained by the disposable
	// microVM and recoverable from content-addressed git objects (the one
	// premise the egress proxy genuinely backstops, for guest-local effects). The
	// credential-carrying remote shapes (push, remote re-aim) do NOT reach here —
	// they are classified in the deny/ask/defer tiers above, because a push to an
	// allowed host is the proxy's TLS-opaque blind spot, not a contained effect.
	// A real-file redirect is GRADED, not vetoed: a destination inside this
	// worktree (or in a scratchpad region designated safe by construction) is the
	// same write `tee <path>` already performs under an ALLOW, while an escaping
	// destination DENIES and an unpinnable one DEFERS. See
	// credentialedRedirectVerdict.
	if d, hit := credentialedRedirectVerdict("git", sc, ev); hit {
		return d
	}
	return allow(fmt.Sprintf("git %s is not a guarded dangerous operation", sub))
}

// gitGlobalRCEDeny scans git's pre-subcommand global-options screen for the
// config-injection / arbitrary-command-execution forms (bypass gate 3):
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
// blocked call the agent respells from the reason below — a deny teaches, it
// does not prompt — while a false allow is arbitrary code execution
// (principle 3).
func gitGlobalRCEDeny(args []string) (Decision, bool) {
	rceDeny := func() (Decision, bool) {
		return deny("git -c config-injection RCE",
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

// classifyGitPush classifies `git push` arguments (bypass gate 2 + the push
// rules). rest is the args after the `push` subcommand token. The refspec — not
// just the flags — is classified, because a forced or deleting update reaches
// its outcome WITHOUT the `--force`/`--delete` flag a flags-only policy keys on:
// a `+` prefix on the refspec source is git's per-ref force marker.
//
// DENY:  --mirror, --prune (delete every remote ref absent from local).
// ASK:   plain --force / -f, and a `+src:dst` forced refspec.
// ALLOW: --force-with-lease (own-race protection), a clean named-branch delete
//
//	(--delete <branch> or origin :branch), tag deletion, an ordinary
//	fast-forward push, and a plain `src:dst` refspec.
//
// A plain `src:dst` (`origin HEAD:branch`) is exactly as safe as
// `git push origin branch`: receive-pack rejects a non-fast-forward update
// unless it is forced, so the push either fast-forwards or is refused by the
// remote. It is the standard idiom for pushing from a worktree whose local
// branch name differs from the remote's. Never defers.
func classifyGitPush(rest []string) Decision {
	// Collect flags and positional (non-flag) operands separately.
	var positionals []string
	hasForce := false
	hasForceWithLease := false
	for _, a := range rest {
		switch {
		case a == "--mirror":
			return deny("git push --mirror",
				"Blocked: 'git push --mirror' deletes every remote ref that is absent locally — "+
					"an irreparable bulk overwrite/delete of the remote. Push specific branches instead.")
		case a == "--prune":
			return deny("git push --prune",
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
	// containing ':' is a source:dest mapping; an empty source ('') is a delete;
	// a source with a leading '+' is a FORCED update.
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
		if hasForceWithLease {
			continue
		}
		// A leading '+' on the source IS the force: git's per-ref force marker,
		// exactly equivalent to --force for that refspec. Escalate it on its own
		// merits. Before, `+src:dst` reached the same ask only incidentally,
		// because it also contained a colon — the '+' was never inspected.
		if strings.HasPrefix(src, "+") {
			// HARD ASK tier: a history-destroying push is one of the enumerated
			// calls fleet policy reserves for an explicit human decision, so it
			// must not be waivable by a downstream judge however sensible the
			// context looks.
			return ask("git push forced-refspec",
				"'git push' with a '+' prefix on the refspec (e.g. 'origin +HEAD:branch') forces the update: "+
					"the '+' is git's per-ref equivalent of --force, so the remote accepts a non-fast-forward "+
					"and the overwritten commits are lost unless someone captured the prior SHA. Fleet policy "+
					"requires explicit human permission for a history-destroying push, so this is a human "+
					"decision by policy rather than an unclassifiable command. Drop the '+' for a plain "+
					"fast-forward push, or use --force-with-lease for race protection.")
		}
		// A plain 'src:dest' (`HEAD:branch`, `HEAD:refs/heads/branch`) is NOT an
		// overwrite. receive-pack rejects a non-fast-forward ref update unless
		// the update is forced — by --force/-f, or by the per-ref '+' handled
		// above — so this either fast-forwards or is refused by the remote,
		// exactly like `git push origin branch`. It is also the standard idiom
		// for pushing from a worktree whose local branch name differs from the
		// remote's, which is why it appears on essentially every push. The old
		// ask rested on the premise that it "overwrites a remote ref without the
		// --force flag the policy keys on", which is not what git does.
		//
		// It moves on to the next positional rather than returning an allow: the
		// refspec being safe does not make the COMMAND safe, and the post-loop
		// --force check is what still asks for `git push --force origin
		// HEAD:branch`.
		continue
	}

	if hasForce && !hasForceWithLease {
		// HARD ASK tier: same policy basis as the forced-refspec arm
		// above — fleet rules reserve a history-destroying push for an explicit
		// human decision. --force-with-lease and --force-if-includes are exempt
		// there and here (hasForceWithLease clears this arm).
		return ask("git push --force",
			"'git push --force' overwrites the remote ref and, if nobody captured the prior SHA, degrades to "+
				"irreparable. Fleet policy requires explicit human permission for a history-destroying push. "+
				"Prefer 'git push --force-with-lease' for race protection, which is allowed without a prompt.")
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
// (the write half) while leaving identity READS alone. `git config user.name X`,
// `git config user.email X`, `git config --global user.*`, writes routed through
// `--file <path>` setting a user.* key (e.g.
// `git config --file .git/config user.email X`), and explicit write verbs
// (`--add`/`--replace-all`/`--unset`/`--unset-all` on a user.* key) all DENY.
//
// The get form `git config user.email` — a `user.*` key with NO following value
// operand and no write verb — is a READ. It must defer (return false) so the
// normal pipeline's `git config:*` read allow governs it. This also resolves the
// `git -C <path> config --local user.email` false positive: parseGitGlobals
// already consumes the `-C <path>` global before this rule sees `rest`, so the
// get-form gap was the sole cause of that repro.
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
