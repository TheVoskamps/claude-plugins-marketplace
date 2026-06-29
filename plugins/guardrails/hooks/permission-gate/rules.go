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

// classifyGh classifies a `gh` invocation. Per the #64 resolved design
// decisions this classifier NEVER defers: the catch-all for a recognized gh
// command is ALLOW (containment lives in the microVM), with the deny/ask tiers
// below carving out the dangerous shapes:
//
//   - DENY: identity switches (#117); irreparable destructive verbs (repo/
//     release/issue/gist delete, secret/variable writes, repo rename/transfer,
//     ruleset delete, release/gist publish); the #64 precondition (non-static
//     argv, inline env-assignment); the gh api method/body/graphql gate.
//   - ASK:  gh repo edit --visibility; gh api (any non-trivially-safe form);
//     gh auth login --hostname.
//   - ALLOW: read-only verbs and ordinary mutations (pr create, issue comment,
//     pr merge, …) the spec does not name as dangerous.
func classifyGh(args []string, sc simpleCommand, ev *Event) Decision {
	// #64 precondition: static argv + no inline env-assignment, gated FIRST.
	if d, hit := preconditionDeny("gh", sc); hit {
		return d
	}

	// Strip gh's own global flags to find the command path.
	cmd := stripLeadingFlags(args)
	if len(cmd) == 0 {
		// Bare `gh` (no subcommand) — nothing to run; ALLOW. (The App-repo
		// naked-gh deny below still fires when relevant.)
		if isAppManagedRepo(ev.CWD) {
			return denyGhNakedAppRepo()
		}
		return allow("gh with no subcommand")
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
		return denyGhNakedAppRepo()
	}

	// #117: gh auth switch (and identity-switch variants).
	if cmd[0] == "auth" && len(cmd) >= 2 {
		switch cmd[1] {
		case "switch":
			return deny("gh auth switch (#117)",
				"Blocked: 'gh auth switch' changes the active GitHub identity and is forbidden — "+
					"it silently re-attributes every subsequent gh action to a different account. "+
					"Do not switch identities. If the wrong identity is active, surface it to the human; "+
					"App-managed repos should call the gh_wrapper which mints the correct token per call.")
		case "login":
			// login can also re-target identity; treat as ASK (the normal
			// pipeline allow-lists 'gh auth login', but a switch via re-login
			// is the multi-identity-switch form #117 warns about).
			if containsToken(cmd[2:], "--hostname") || containsToken(cmd[2:], "-h") {
				return ask("gh auth login --hostname (#117)",
					"'gh auth login' targeting a specific host can switch the active identity. "+
						"Confirm this is intended and not an unprompted identity switch.")
			}
		}
	}

	// #64 bypass gate 1: `gh api` defeats subcommand-shape classification.
	// Route it through the api gate (method/body/graphql → DENY; else ASK).
	if cmd[0] == "api" {
		return classifyGhAPI(args)
	}

	// #64 DENY tier: irreparable / boundary-weakening gh operations.
	if d, hit := ghIrreparableDeny(cmd); hit {
		return d
	}

	// #64 ASK tier: gh repo edit --visibility (sanctioned-skill territory).
	if cmd[0] == "repo" && len(cmd) >= 2 && cmd[1] == "edit" {
		if containsToken(args, "--visibility") || hasFlagPrefix(args, "--visibility=") {
			return ask("gh repo edit --visibility (#64)",
				"'gh repo edit --visibility' flips repo visibility — an accidental public flip leaks scrubbed "+
					"identifiers. Confirm this is intended; visibility changes should go through the sanctioned skill.")
		}
	}

	// #64 ASK tier: release / public-gist publish (exposure, irreversible). The
	// spec DENYs publish "unless via sanctioned visibility skill"; the gate has
	// no signal for that wrapper, and a hard DENY would leave no escape hatch
	// for legitimate release creation, so it routes to ASK (one human click)
	// rather than DENY. A public gist (`gh gist create --public`) is the
	// exposure form; a default (secret) gist is not.
	if cmd[0] == "release" && len(cmd) >= 2 && cmd[1] == "create" {
		return ask("gh release create (#64 publish)",
			"'gh release create' publishes a release — exposure that is effectively irreversible. "+
				"Confirm this is intended; publishing should go through the sanctioned visibility skill.")
	}
	if cmd[0] == "gist" && len(cmd) >= 2 && cmd[1] == "create" {
		if containsToken(args, "--public") || hasFlagPrefix(args, "--public=") {
			return ask("gh gist create --public (#64 publish)",
				"'gh gist create --public' publishes a public gist — exposure that is effectively irreversible. "+
					"Confirm this is intended.")
		}
	}

	// Read-only gh subcommand — ALLOW (explicit, for the evolution-log label).
	if isGhReadOnly(cmd) {
		if sc.hasRedirectToFile {
			return ask("gh redirect-to-file",
				"'gh' with stdout/stderr redirected to a real file can exfiltrate. Confirm the target is intended.")
		}
		return allow(fmt.Sprintf("gh %s is a read-only subcommand", strings.Join(cmd, " ")))
	}

	// #64 ALLOW default: every recognized gh command not carved out above —
	// ordinary mutations (pr create, issue comment, pr merge, release create,
	// …) — ALLOWs; containment lives in the microVM. A real-file redirect is
	// the residual exfil concern that ASKs (cannot defer per #64 decision 2).
	if sc.hasRedirectToFile {
		return ask("gh redirect-to-file",
			"'gh' with stdout/stderr redirected to a real file can exfiltrate. Confirm the target is intended.")
	}
	return allow(fmt.Sprintf("gh %s is not a guarded dangerous operation", strings.Join(cmd, " ")))
}

// denyGhNakedAppRepo is the shared #App-repo naked-gh deny (kept as a helper so
// the no-subcommand and subcommand paths emit the same message).
func denyGhNakedAppRepo() Decision {
	return deny("gh naked (App repo)",
		"Blocked: a bare 'gh' in an App-configured repo uses your personal credentials and silently "+
			"mis-attributes the action. Call the wrapper by absolute path instead — "+
			"'~/.claude/.global-claude-config/bin/gh_wrapper' — which mints a fresh App installation token "+
			"per call. See rules/prefer-gh-wrapper-in-app-repos.md.")
}

// ghIrreparableDeny denies the #64 DENY-tier gh operations: deletes of things
// that are NOT git objects (repo/release/issue/gist), write-only secret/variable
// values, repo rename/transfer, branch-protection/ruleset weakening, and
// release/gist publish (irreversible exposure). cmd is the flag-stripped command
// path (noun verb …). Default-deny within the gate: an unrecognized
// secret/variable/ruleset subcommand denies (fail closed).
func ghIrreparableDeny(cmd []string) (Decision, bool) {
	if len(cmd) < 2 {
		return Decision{}, false
	}
	noun, verb := cmd[0], cmd[1]
	d := func(op, msg string) (Decision, bool) { return deny(op, msg), true }

	switch noun {
	case "repo":
		switch verb {
		case "delete":
			return d("gh repo delete (#64)",
				"Blocked: 'gh repo delete' is irreparable — a repository is not a recoverable git object. Denied.")
		case "rename":
			return d("gh repo rename (#64)",
				"Blocked: 'gh repo rename' changes the repository's identity and breaks every existing reference. "+
					"Denied; rename deliberately via the GitHub UI if genuinely intended.")
		case "transfer":
			return d("gh repo transfer (#64)",
				"Blocked: 'gh repo transfer' moves the repository to another owner — irreparable from here. Denied.")
		}
	case "release":
		switch verb {
		case "delete":
			return d("gh release delete (#64)",
				"Blocked: 'gh release delete' destroys release assets, which are NOT git objects and not "+
					"recoverable. Denied.")
		}
	case "issue":
		if verb == "delete" {
			return d("gh issue delete (#64)",
				"Blocked: 'gh issue delete' is a HARD delete (contrast 'gh issue close', which is reversible). "+
					"Denied; close the issue instead if that is the intent.")
		}
	case "gist":
		if verb == "delete" {
			return d("gh gist delete (#64)",
				"Blocked: 'gh gist delete' destroys the gist irreparably. Denied.")
		}
	case "secret", "variable":
		// Any secret/variable write (set/delete/remove) is a write-only mutation
		// of values the gate cannot recover. Default-deny the whole noun's
		// mutating verbs; the read verbs (list) are handled by isGhReadOnly above
		// before this point only for known nouns — secret/variable are NOT in the
		// read-only known-noun set, so a `gh secret list` reaches here. Allow the
		// list/get read forms; deny everything else (fail closed).
		switch verb {
		case "list", "get":
			return Decision{}, false // a read; fall through to ALLOW default.
		default:
			return d("gh "+noun+" write (#64)",
				"Blocked: 'gh "+noun+" "+verb+"' writes or deletes a "+noun+" value the gate cannot recover. "+
					"Denied; manage "+noun+"s deliberately, not as part of automated work.")
		}
	case "ruleset":
		if verb == "delete" {
			return d("gh ruleset delete (#64)",
				"Blocked: 'gh ruleset delete' weakens branch-protection guardrails — it disarms the guardrail the "+
					"rest of this policy relies on. Denied.")
		}
	}
	return Decision{}, false
}

// hasFlagPrefix reports whether any arg starts with the given prefix (used for
// `--flag=value` forms).
func hasFlagPrefix(args []string, prefix string) bool {
	for _, a := range args {
		if strings.HasPrefix(a, prefix) {
			return true
		}
	}
	return false
}

// classifyGhAPI gates `gh api` (#64 bypass gate 1). Default: ASK. DENY when the
// request is unambiguously a write or unclassifiable: a non-GET method
// (explicit -X/--method, or the implicit POST flip when any
// -f/-F/--field/--raw-field/--input is present), a request body, the graphql
// endpoint (mutating-ness lives in the query string), or an
// x-http-method-override header. args is the full gh argv (after the program),
// i.e. it still contains the leading `api` token and gh's globals.
func classifyghAPIDeny(reason string) Decision {
	return deny("gh api write/unclassifiable (#64)", reason)
}

func classifyGhAPI(args []string) Decision {
	// Walk the tokens after `api`. Track method, body-bearing flags, graphql,
	// hostname redirection, and the method-override header.
	var method string
	bodyBearing := false
	graphql := false
	seenAPI := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !seenAPI {
			if a == "api" {
				seenAPI = true
			}
			continue
		}
		switch {
		case a == "-X" || a == "--method":
			if i+1 < len(args) {
				method = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "-X"):
			method = strings.TrimPrefix(a, "-X")
		case strings.HasPrefix(a, "--method="):
			method = strings.TrimPrefix(a, "--method=")
		case a == "-f" || a == "-F" || a == "--field" || a == "--raw-field" || a == "--input":
			bodyBearing = true
			if i+1 < len(args) {
				i++ // consume the value
			}
		case strings.HasPrefix(a, "-f") && len(a) > 2,
			strings.HasPrefix(a, "-F") && len(a) > 2,
			strings.HasPrefix(a, "--field="),
			strings.HasPrefix(a, "--raw-field="),
			strings.HasPrefix(a, "--input="):
			bodyBearing = true
		case a == "-H" || a == "--header":
			if i+1 < len(args) {
				if headerIsMethodOverride(args[i+1]) {
					return classifyghAPIDeny(
						"Blocked: 'gh api' with an X-HTTP-Method-Override header can perform a write disguised as a GET. Denied.")
				}
				i++
			}
		case strings.HasPrefix(a, "-H") && len(a) > 2:
			if headerIsMethodOverride(strings.TrimPrefix(a, "-H")) {
				return classifyghAPIDeny(
					"Blocked: 'gh api' with an X-HTTP-Method-Override header can perform a write disguised as a GET. Denied.")
			}
		case strings.HasPrefix(a, "--header="):
			if headerIsMethodOverride(strings.TrimPrefix(a, "--header=")) {
				return classifyghAPIDeny(
					"Blocked: 'gh api' with an X-HTTP-Method-Override header can perform a write disguised as a GET. Denied.")
			}
		case !strings.HasPrefix(a, "-"):
			// A positional: the endpoint path. `graphql` is unclassifiable.
			if a == "graphql" {
				graphql = true
			}
		}
	}

	if graphql {
		return classifyghAPIDeny(
			"Blocked: 'gh api graphql' is a POST whose mutating-ness lives in the query string and is " +
				"unclassifiable from argv. Denied.")
	}
	// Implicit method flip: any body-bearing flag turns the default GET into a
	// POST. An explicit non-GET method is also a write.
	if method != "" && !strings.EqualFold(method, "GET") {
		return classifyghAPIDeny(
			"Blocked: 'gh api' with a non-GET method (-X/--method " + method + ") performs a write. Denied.")
	}
	if bodyBearing && (method == "" || !strings.EqualFold(method, "GET")) {
		// Body-bearing with no explicit method flips to POST; body-bearing with
		// an explicit non-GET is a write. (-XGET -f … is a GET with params and is
		// the one body-bearing form that stays a read — it falls to ASK below.)
		return classifyghAPIDeny(
			"Blocked: 'gh api' with a request-body flag (-f/-F/--field/--raw-field/--input) and no explicit " +
				"GET method implicitly flips to POST and performs a write. Denied.")
	}

	// Default: ASK. A GET (explicit or implicit) reaches here. The microVM has
	// no open egress, so a GET cannot exfiltrate; ASK is the #64-specified
	// default for gh api.
	return ask("gh api (#64)",
		"'gh api' can perform reads and writes against the GitHub API. This form parses as a read (GET); "+
			"confirm it is intended.")
}

// headerIsMethodOverride reports whether a -H header value names the
// X-HTTP-Method-Override header (case-insensitive on the header name).
func headerIsMethodOverride(h string) bool {
	name := h
	if colon := strings.IndexByte(h, ':'); colon >= 0 {
		name = h[:colon]
	}
	return strings.EqualFold(strings.TrimSpace(name), "x-http-method-override")
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

// classifyAws classifies an `aws <service> <operation>` invocation. Per the #64
// resolved design decisions this classifier NEVER defers:
//
//   - DENY:  the #64 precondition (non-static argv, inline env-assignment);
//     --endpoint-url (redirects the SIGNED request to an attacker host —
//     credential/data exfil + SSRF).
//   - ASK:   reads that return credentials/secrets (sts get-session-token,
//     ecr get-login-password, secretsmanager get-secret-value, ssm
//     get-parameter --with-decryption, …).
//   - ALLOW: read-only ops (describe-/list-/get- hyphen anchor + explicit set),
//     and — per #64 decision 1 — ordinary writes the spec does not name
//     (containment lives in the microVM).
//
// Classification is on the parsed operation TOKEN, never a substring match (§4).
func classifyAws(args []string, sc simpleCommand) Decision {
	// #64 precondition: static argv + no inline env-assignment, gated FIRST.
	if d, hit := preconditionDeny("aws", sc); hit {
		return d
	}

	// #64 DENY: --endpoint-url redirects the signed request (with credentials)
	// to an arbitrary host. Gate this BEFORE op classification so even a
	// read-shaped op cannot exfiltrate via a redirected endpoint.
	if awsHasEndpointURL(args) {
		return deny("aws --endpoint-url (#64)",
			"Blocked: 'aws --endpoint-url <url>' redirects the SIGNED request — carrying your credentials — to an "+
				"arbitrary host (credential/data exfil and SSRF). Denied. Remove --endpoint-url; the default "+
				"AWS endpoints are the only sanctioned targets.")
	}

	svc, op := awsServiceAndOp(args)
	if svc == "" || op == "" {
		// Not a recognizable `aws <service> <operation>` shape; nothing to
		// classify and nothing dangerous detected — ALLOW (#64 decision 1).
		return allow("aws (no classifiable service/operation)")
	}

	// #64 ASK: credential/secret reads.
	if awsCredentialRead(svc, op, args) {
		return ask("aws credential-read (#64)",
			fmt.Sprintf("'aws %s %s' returns credentials or secrets. Confirm this is intended; do not pipe the "+
				"output anywhere it could be captured.", svc, op))
	}

	// A real-file redirect is the residual exfil concern that ASKs (cannot
	// defer per #64 decision 2).
	if sc.hasRedirectToFile {
		return ask("aws redirect-to-file",
			"'aws' with stdout redirected to a real file can exfiltrate. Confirm the target is intended.")
	}

	if awsReadOnlyOp(op) {
		return allow(fmt.Sprintf("aws %s %s is a read-only operation", svc, op))
	}
	// #64 ALLOW default: an ordinary aws write the spec does not name as
	// dangerous (containment lives in the microVM).
	return allow(fmt.Sprintf("aws %s %s is not a guarded dangerous operation", svc, op))
}

// awsHasEndpointURL reports whether the args carry an --endpoint-url flag in
// either the spaced (`--endpoint-url <url>`) or glued (`--endpoint-url=<url>`)
// form.
func awsHasEndpointURL(args []string) bool {
	for _, a := range args {
		if a == "--endpoint-url" || strings.HasPrefix(a, "--endpoint-url=") {
			return true
		}
	}
	return false
}

// awsCredentialRead reports whether an `aws <svc> <op>` is one of the reads that
// returns credentials or secrets (#64 ASK tier). The ssm get-parameter family
// is a credential read only with --with-decryption.
func awsCredentialRead(svc, op string, args []string) bool {
	op = strings.ToLower(op)
	svc = strings.ToLower(svc)
	switch svc {
	case "sts":
		return op == "get-session-token" || op == "get-federation-token"
	case "ecr", "ecr-public":
		return op == "get-login-password" || op == "get-authorization-token"
	case "secretsmanager":
		return op == "get-secret-value"
	case "iam":
		return op == "get-credential-report"
	case "cognito-identity":
		return op == "get-credentials-for-identity" || strings.HasPrefix(op, "get-open-id-token")
	case "ssm":
		switch op {
		case "get-parameter", "get-parameters", "get-parameters-by-path":
			return containsToken(args, "--with-decryption")
		}
	}
	return false
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
