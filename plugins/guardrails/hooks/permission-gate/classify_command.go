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
	case "cat", "head", "tail", "less", "more", "od", "xxd", "hexdump":
		// Read-class programs whose path arguments must stay inside the repo
		// (#148: do not read a sibling repo's node_modules to verify APIs).
		return classifyPathReader(prog, args, sc, ev)
	}
	// No specific rule. The gate has no opinion; hand back to the pipeline.
	return deferToPipeline()
}

// classifyGit parses git's option grammar from the AST tokens: global options
// (`--no-pager`/`-P`, `-c k=v`, `-C path`, `--git-dir`, etc.) precede the
// subcommand (#13). Positional guessing is obsolete — we consume globals
// explicitly, then dispatch on the real subcommand.
func classifyGit(args []string, sc simpleCommand, ev *Event) Decision {
	sub, rest, cdir := parseGitGlobals(args)
	if sub == "" {
		// `git` with only globals / no subcommand — defer.
		return deferToPipeline()
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

	// #120: subagent `git reset --hard`.
	if sub == "reset" && containsToken(rest, "--hard") {
		if ev.isSubagent() {
			return deny("git reset --hard (subagent)",
				"Blocked: 'git reset --hard' in a subagent discards committed and working-tree state and is forbidden. "+
					"Remediation: do NOT reset; instead release the branch and re-derive from the remote tip with a "+
					"detached checkout of origin — e.g. 'git fetch origin <branch>' then 'git checkout --detach origin/<branch>' — "+
					"or 'git switch -c <branch> origin/<branch>'. See issue #120.")
		}
		// Main session: still destructive — escalate to a human rather than
		// auto-allow. (settings.json also lists this in its ask set.)
		return ask("git reset --hard",
			"'git reset --hard' discards committed and working-tree state. Confirm this is intended. "+
				"A safer alternative is a detached checkout of the origin tip (see issue #120).")
	}

	// --- ALLOW rules: read-only / non-mutating git subcommands ---
	if gitReadOnlySubcommands[sub] {
		if !sc.allowEligible() {
			return deferToPipeline()
		}
		// `git config` with a write (key + value) is NOT read-only; only the
		// list/get forms are. gitReadOnlySubcommands excludes "config", so we
		// never land here for config.
		return allow(fmt.Sprintf("git %s is a read-only / non-mutating subcommand", sub))
	}

	// Everything else (push, rebase, merge, clean, ...) — defer to the
	// normal pipeline, which has explicit ask/deny entries for the
	// destructive ones.
	return deferToPipeline()
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
// (#125 write half). `git config user.name X`, `git config user.email X`,
// `git config --global user.*`, and writes routed through `--file <path>`
// setting a user.* key (e.g. `git config --file .git/config user.email X`)
// all match. Read forms (`--get`, `--list`, `-l`) do not.
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
	// Scan for a key token that targets user identity. Value-taking flags
	// (`--file <path>`, `-f <path>`, `--blob <ref>`) consume the following
	// token so a path/ref is not misread as the config key.
	for i := 0; i < len(rest); i++ {
		a := rest[i]
		if a == "--file" || a == "-f" || a == "--blob" {
			i++ // skip this flag's value
			continue
		}
		if strings.HasPrefix(a, "-") {
			continue // other flags (e.g. --global, --local, --file=<path>) carry no separate value token
		}
		key := strings.ToLower(a)
		if strings.HasPrefix(key, "user.") {
			return deny("git config user.* (identity write)",
				"Blocked: writing git identity (user.name / user.email / user.signingkey) is forbidden — "+
					"it silently changes commit attribution (the #125 write half). "+
					"The repo's committer identity is configured by the environment, not by ad-hoc 'git config' writes. "+
					"If you believe identity is genuinely misconfigured, surface it to the human rather than rewriting it."), true
		}
		// A non-flag token that is not a user.* key is the config key being
		// operated on (e.g. `core.editor`); a `user.*` key, if present, would
		// already have matched above. Keep scanning in case a value-taking flag
		// pushed the user.* key later, but a plain `git config core.x y` falls
		// through to "not an identity write".
	}
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
