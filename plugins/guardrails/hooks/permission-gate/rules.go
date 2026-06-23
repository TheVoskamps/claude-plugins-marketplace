package main

import (
	"fmt"
	"strings"
)

// gitReadOnlySubcommands is the high-confidence read-only / non-mutating git
// subcommand allow set (§4). Deliberately conservative: anything not listed
// here defers to the normal pipeline. `config` is intentionally absent — its
// read forms are common but its write forms mutate, and parsing the two apart
// for an allow is not worth the risk; it defers.
var gitReadOnlySubcommands = map[string]bool{
	"status":        true,
	"log":           true,
	"diff":          true,
	"show":          true,
	"rev-parse":     true,
	"rev-list":      true,
	"describe":      true,
	"blame":         true,
	"shortlog":      true,
	"ls-files":      true,
	"ls-tree":       true,
	"ls-remote":     true,
	"cat-file":      true,
	"show-ref":      true,
	"symbolic-ref":  true,
	"for-each-ref":  true,
	"reflog":        true, // `reflog` alone lists; `reflog expire` mutates (handled below)
	"name-rev":      true,
	"merge-base":    true,
	"whatchanged":   true,
	"grep":          true,
	"count-objects": true,
	"var":           true,
	"help":          true,
	"version":       true,
}

// classifyGh classifies a `gh` invocation. Two concerns:
//   - DENY identity switches (#117): `gh auth switch` and multi-identity
//     switch forms.
//   - ALLOW read-only subcommands (view/list/status-class).
//
// Everything else defers to the normal pipeline (which has explicit ask
// entries for mutating gh verbs like pr merge, release create, etc.).
func classifyGh(args []string, sc simpleCommand, ev *Event) Decision {
	// Strip gh's own global flags to find the command path.
	cmd := stripLeadingFlags(args)
	if len(cmd) == 0 {
		return deferToPipeline()
	}

	// Naked `gh` in an App-configured repo (ported from the replaced
	// auto-approve-compound-commands.sh; see rules/prefer-gh-wrapper-in-app-repos.md).
	// When the event repo's LOCAL user.email is the App bot address
	// (*[bot]@users.noreply.github.com), a bare `gh` would silently use the
	// human's personal credentials and mis-attribute the action. Deny and
	// point at the wrapper. Fires only in App repos; elsewhere the local
	// email is not a bot address and this is a no-op. A git lookup failure is
	// treated as "not an App repo" (the gate does not block normal gh usage
	// just because git can't answer).
	if isAppManagedRepo(ev.CWD) {
		return deny("gh naked (App repo)",
			"Blocked: a bare 'gh' in an App-configured repo uses your personal credentials and silently "+
				"mis-attributes the action. Call the wrapper by absolute path instead — "+
				"'~/.claude/.global-claude-config/bin/gh_wrapper' — which mints a fresh App installation token "+
				"per call. See rules/prefer-gh-wrapper-in-app-repos.md.")
	}

	// #117: gh auth switch (and identity-switch variants).
	if cmd[0] == "auth" && len(cmd) >= 2 {
		switch cmd[1] {
		case "switch":
			return deny("gh auth switch (#117)",
				"Blocked: 'gh auth switch' changes the active GitHub identity and is forbidden — "+
					"it silently re-attributes every subsequent gh action to a different account (#117). "+
					"Do not switch identities. If the wrong identity is active, surface it to the human; "+
					"App-managed repos should call the gh_wrapper which mints the correct token per call.")
		case "login":
			// login can also re-target identity; treat as ASK (the normal
			// pipeline allow-lists 'gh auth login', but a switch via re-login
			// is the multi-identity-switch form #117 warns about).
			if containsToken(cmd[2:], "--hostname") || containsToken(cmd[2:], "-h") {
				return ask("gh auth login --hostname (#117)",
					"'gh auth login' targeting a specific host can switch the active identity (#117). "+
						"Confirm this is intended and not an unprompted identity switch.")
			}
		}
	}

	// Read-only gh subcommand allow track.
	if isGhReadOnly(cmd) {
		if !sc.allowEligible() {
			return deferToPipeline()
		}
		return allow(fmt.Sprintf("gh %s is a read-only subcommand", strings.Join(cmd, " ")))
	}

	return deferToPipeline()
}

// isGhReadOnly reports whether a gh command path is a read-only verb. Matches
// on the LAST token of the leading command path being a read verb, scoped to
// known noun groups.
func isGhReadOnly(cmd []string) bool {
	if len(cmd) < 2 {
		return false
	}
	noun := cmd[0]
	verb := cmd[1]
	readVerbs := map[string]bool{
		"view": true, "list": true, "status": true, "diff": true,
		"checks": true, "get": true,
	}
	knownNouns := map[string]bool{
		"pr": true, "issue": true, "repo": true, "run": true, "release": true,
		"project": true, "label": true, "workflow": true, "gist": true,
		"cache": true, "browse": true, "search": true, "ruleset": true,
	}
	// `gh api` GET is read-ish but can POST; do not auto-allow it here (the
	// normal pipeline allow-lists `gh api:*` deliberately). Defer.
	if noun == "api" {
		return false
	}
	if !knownNouns[noun] {
		return false
	}
	return readVerbs[verb]
}

// classifyAws classifies an `aws <service> <operation>` invocation. Read-only
// operations (the operation token starts with list/describe/get, plus a few
// explicit read verbs) ALLOW; everything else defers. Classification is on
// the parsed operation TOKEN, never a substring match (§4).
func classifyAws(args []string, sc simpleCommand) Decision {
	svc, op := awsServiceAndOp(args)
	if svc == "" || op == "" {
		return deferToPipeline()
	}
	if awsReadOnlyOp(op) {
		if !sc.allowEligible() {
			return deferToPipeline()
		}
		return allow(fmt.Sprintf("aws %s %s is a read-only operation", svc, op))
	}
	return deferToPipeline()
}

// awsServiceAndOp extracts the service and operation tokens, skipping aws's
// global options (--region, --profile, --output, etc.).
func awsServiceAndOp(args []string) (svc, op string) {
	var positionals []string
	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--region" || a == "--profile" || a == "--output" ||
			a == "--endpoint-url" || a == "--color" || a == "--ca-bundle" ||
			a == "--cli-read-timeout" || a == "--cli-connect-timeout" || a == "--query":
			i += 2
		case strings.HasPrefix(a, "--") && strings.Contains(a, "="):
			i++
		case a == "--debug" || a == "--no-sign-request" || a == "--no-paginate" || a == "--no-cli-pager":
			i++
		case strings.HasPrefix(a, "-"):
			i++
		default:
			positionals = append(positionals, a)
			i++
		}
	}
	if len(positionals) >= 2 {
		return positionals[0], positionals[1]
	}
	return "", ""
}

// awsReadOnlyOp reports whether an aws operation token is read-only. The token
// is matched as a whole hyphen-segmented verb prefix (list-*, describe-*,
// get-*) plus a small explicit set, NOT a substring (so "delete-list-xyz"
// would not match list).
func awsReadOnlyOp(op string) bool {
	op = strings.ToLower(op)
	for _, prefix := range []string{"list", "describe", "get"} {
		if op == prefix || strings.HasPrefix(op, prefix+"-") {
			return true
		}
	}
	switch op {
	case "ls", "head-object", "head-bucket", "wait", "test-dns-answer",
		"batch-get-builds", "batch-get-projects", "filter-log-events",
		"lookup-events", "search":
		return true
	}
	return false
}

// classifyAcli classifies Atlassian CLI (`acli`) read-only subcommands. Mirror
// of the gh logic: view/list/status/get verbs ALLOW, the rest defer.
func classifyAcli(args []string, sc simpleCommand) Decision {
	cmd := stripLeadingFlags(args)
	if len(cmd) < 2 {
		return deferToPipeline()
	}
	// acli command paths look like `<product> <noun> <verb> [operands]`
	// (e.g. `jira issue view ABC-1`). The read verb is one of the command-path
	// tokens, not necessarily the last (the last is often an operand). Match a
	// read verb anywhere among the tokens.
	readVerbs := map[string]bool{"view": true, "list": true, "status": true, "get": true, "search": true}
	for _, tok := range cmd {
		if readVerbs[tok] {
			if !sc.allowEligible() {
				return deferToPipeline()
			}
			return allow(fmt.Sprintf("acli %s is a read-only subcommand", strings.Join(cmd, " ")))
		}
	}
	return deferToPipeline()
}

// stripLeadingFlags drops leading -/-- flags so the command-path tokens are at
// the front. A flag that takes a value is not specially handled here (we only
// need the first non-flag command tokens); this is fine because subcommand
// paths come before value-bearing flags in gh/acli usage.
func stripLeadingFlags(args []string) []string {
	out := make([]string, 0, len(args))
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			continue
		}
		out = append(out, a)
	}
	return out
}
