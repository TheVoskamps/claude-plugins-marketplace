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

// classifyGh classifies a `gh` invocation. Per the resolved design
// decisions this classifier NEVER defers. Under the "two boundaries, split
// by visibility" role, ALLOW is NOT a floor — it is a property of an enumerated
// verb. The egress proxy is the network boundary (it owns only the CONNECT
// target host); the gate is the semantic boundary for the proxy's TLS-opaque
// blind spot — what the guest's credential may do at an already-allowed host.
// So a classifier miss on an unrecognized gh command is NOT "one un-prompted run
// in a trusted box" (the microVM does not backstop a credential-carrying write
// to an allowed host); it fails closed to ASK. The tiers:
//
//   - DENY: identity switches; irreparable destructive verbs (repo/
//     release/issue/gist delete, secret/variable writes, repo rename/transfer,
//     ruleset delete); the precondition (non-static argv, inline
//     env-assignment); gh api --hostname (signed-request redirect — the one
//     shape the egress proxy genuinely owns) and an unclassifiable graphql
//     document (approval cannot be informed) (see classifyGhAPI).
//   - ASK:  gh repo edit --visibility; gh auth login --hostname; a gh api
//     graphql mutation outside the curated allowlist — or one whose document
//     carries a fragment, whose names the scanner cannot trust; an
//     unknown gh api flag, a non-allowlisted gh api REST endpoint, or a
//     gh api REST write — non-GET method, implicit-POST body flag, or
//     method-override header; a foreign-target enumerated write;
//     and any UNRECOGNIZED gh noun/verb (the fail-closed floor).
//   - ALLOW: enumerated read-only verbs (isGhReadOnly) and enumerated
//     recoverable own-repo write verbs (isGhRecoverableWrite: pr create/comment/
//     merge/close, issue create/comment/close/edit, label, …); a provably
//     query-only gh api graphql document, a fragment-free gh api graphql
//     document whose every mutation field is on ghGraphQLMutationAllowlist
//     and an allow-listed gh api REST GET.
func classifyGh(args []string, sc simpleCommand, ev *Event) Decision {
	// Precondition: static argv + no inline env-assignment, gated FIRST.
	if d, hit := preconditionDeny("gh", sc); hit {
		return d
	}

	// Parse gh's leading global-flag screen to find the command path. Unlike a
	// naive strip, parseGhGlobals consumes the VALUE of space-separated
	// value-taking globals (e.g. `-R owner/repo`) so the value token is never
	// mistaken for the noun/verb — that desync is a deny-tier BYPASS (a missed
	// deny is a silent auto-allow). It also fails closed
	// (DENY) on an UNKNOWN leading global, since an unrecognized global can
	// desync detection the same way and the cost of a false deny is one human
	// click while a false allow is an irreparable operation.
	cmd, early, leadingRepo := parseGhGlobals(args)
	if early != nil {
		return *early
	}
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

	// gh auth switch (and identity-switch variants).
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
			// is the multi-identity-switch form the deny warns about).
			if containsToken(cmd[2:], "--hostname") || containsToken(cmd[2:], "-h") {
				return ask("gh auth login --hostname (#117)",
					"'gh auth login' targeting a specific host can switch the active identity. "+
						"Confirm this is intended and not an unprompted identity switch.")
			}
		}
	}

	// Bypass gate 1: `gh api` defeats subcommand-shape classification.
	// Route it through the api gate. Write signals (non-GET method, implicit-POST
	// body flag, method-override header, --hostname) still DENY; a graphql POST is
	// now classified from its query document (query-only → ALLOW, mutation → ASK,
	// unclassifiable → DENY) and a REST GET is run through the path-prefix
	// GET-gate. sc is threaded through so the redirect-to-file ASK carve-out the
	// other gh paths get also applies to an otherwise-allowed gh api form.
	if cmd[0] == "api" {
		return classifyGhAPI(args, sc)
	}

	// DENY tier: irreparable / boundary-weakening gh operations.
	if d, hit := ghIrreparableDeny(cmd); hit {
		return d
	}

	// ASK tier: gh repo edit --visibility (sanctioned-skill territory).
	if cmd[0] == "repo" && len(cmd) >= 2 && cmd[1] == "edit" {
		if containsToken(args, "--visibility") || hasFlagPrefix(args, "--visibility=") {
			return ask("gh repo edit --visibility (#64)",
				"'gh repo edit --visibility' flips repo visibility — an accidental public flip leaks scrubbed "+
					"identifiers. Confirm this is intended; visibility changes should go through the sanctioned skill.")
		}
	}

	// ASK tier: release / public-gist publish (exposure, irreversible). The
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
	// Reads are NOT foreign-target-scoped: a GET to a foreign repo is not
	// the exfil channel — that is consummated only by a WRITE to an
	// attacker-readable place, which the enumerated-write scoping below covers.
	if isGhReadOnly(cmd) {
		if sc.hasRedirectToFile {
			return ask("gh redirect-to-file",
				"'gh' with stdout/stderr redirected to a real file can exfiltrate. Confirm the target is intended.")
		}
		return allow(fmt.Sprintf("gh %s is a read-only subcommand", strings.Join(cmd, " ")))
	}

	// ALLOW-by-enumeration: the former ALLOW *floor* (every recognized gh
	// command that was not carved out above) is gone. ALLOW is now a property of
	// an ENUMERATED recoverable-own-repo write verb — the sanctioned hot-loop
	// mutations (pr create/comment/merge/close, issue create/comment/close/edit,
	// label, …). An UNRECOGNIZED gh noun/verb ASKs (fail-closed): principle 2
	// (unknown subcommands fail closed) applied where it is cheap — the hot loop
	// uses only enumerated verbs, so the prompt cost is ~zero, and a gh-version
	// -drift miss now costs one click instead of a silent auto-allow.
	if isGhRecoverableWrite(cmd) {
		if sc.hasRedirectToFile {
			return ask("gh redirect-to-file",
				"'gh' with stdout/stderr redirected to a real file can exfiltrate. Confirm the target is intended.")
		}
		// Foreign-target write scoping: an otherwise-ALLOWed gh write whose
		// explicit target (`-R`/`--repo`, in either the leading-global or the
		// post-noun position) differs from the session repo's origin is an
		// exfil-by-write channel (`gh issue comment -R attacker/repo …`) the
		// egress proxy — which sees only ciphertext to an allowed host — cannot
		// distinguish from an own-repo comment. ASK so a human owns the
		// cross-repo write. An own-repo target (or no explicit target) stays
		// ALLOW; an undeterminable origin fails open to the former ALLOW (the
		// verb already passed the recoverable-write allowlist).
		if target := ghExplicitRepoTarget(leadingRepo, cmd); target != "" {
			if origin := sessionOriginRepo(ev.CWD); origin != "" && target != origin {
				return ask("gh foreign-target write (#163)",
					"'gh "+strings.Join(cmd, " ")+"' writes to '"+target+"', which differs from this session's "+
						"origin repo ('"+origin+"'). A write to another repo is an exfil-by-write channel the egress "+
						"proxy cannot see (it sees only ciphertext to an allowed host). Confirm this cross-repo write "+
						"is intended.")
			}
		}
		return allow(fmt.Sprintf("gh %s is an enumerated recoverable write", strings.Join(cmd, " ")))
	}

	// Fail-closed floor: an unrecognized gh command (neither an enumerated
	// read nor an enumerated recoverable write) ASKs rather than taking the former
	// silent ALLOW. This is the restated role — the gate is the semantic boundary
	// for what the guest's credential may do at an allowed host, and an
	// unrecognized shape is precisely what the gate cannot vouch for.
	return ask("gh unrecognized command (#163)",
		"'gh "+strings.Join(cmd, " ")+"' is not a recognized read or an enumerated recoverable write. The "+
			"permission gate cannot classify it, so it escalates to a human (fail-closed) rather than "+
			"auto-allowing. Confirm this is intended; if it is a routine safe operation, it can be added to the "+
			"gate's enumerated verb set.")
}

// ghRecoverableWriteVerbs maps each gh noun to the set of write verbs that are
// the agent's sanctioned, individually-recoverable job: they land in
// human-reviewed surfaces (PRs, issue threads) and are reversible
// (close/reopen, comment edit, PR revert), so they ALLOW (subject to the
// foreign-target scoping). Irreparable verbs (delete/rename/transfer/publish)
// and identity/secret writes are NOT here — they are carved out to DENY/ASK by
// the tiers above BEFORE this map is consulted, so listing them here would be
// dead weight. An `api` write is likewise never here (classifyGhAPI decides it
// before isGhRecoverableWrite is reached).
var ghRecoverableWriteVerbs = map[string]map[string]bool{
	"pr": {
		"create": true, "comment": true, "merge": true, "close": true,
		"edit": true, "ready": true, "reopen": true, "review": true,
	},
	"issue": {
		"create": true, "comment": true, "close": true, "edit": true,
		"reopen": true, "pin": true, "unpin": true, "lock": true, "unlock": true,
		"transfer": false, // irreparable-ish cross-repo move; not a hot-loop verb → leave to fail-closed ASK
	},
	"release": {
		// `create` is already routed to ASK (publish) above; `edit`/`upload` are
		// recoverable release mutations.
		"edit": true, "upload": true,
	},
	"label": {
		"create": true, "edit": true, "clone": true,
		// `label delete` is a recoverable re-creatable metadata delete, but it is
		// not a hot-loop verb; leave it to fail-closed ASK.
	},
	"gist": {
		// `create` (secret) is the sanctioned form; `--public` already ASKs above.
		"create": true, "edit": true,
	},
	"cache": {
		"delete": true, // CI cache is regenerated on next run — recoverable.
	},
}

// isGhRecoverableWrite reports whether a gh command path is an enumerated
// recoverable-own-repo write verb. cmd is the flag-stripped command path
// (noun verb …). A noun/verb pair present in ghRecoverableWriteVerbs with a
// true value matches; everything else (unknown noun, unknown verb, or a verb
// explicitly mapped false) does not, and falls through to the fail-closed ASK.
func isGhRecoverableWrite(cmd []string) bool {
	if len(cmd) < 2 {
		return false
	}
	verbs, ok := ghRecoverableWriteVerbs[cmd[0]]
	if !ok {
		return false
	}
	return verbs[cmd[1]]
}

// ghExplicitRepoTarget returns the lowercased `owner/repo` target of a gh
// write, or "" when the command carries no explicit target. It prefers the
// leading `-R`/`--repo` global (already parsed) and otherwise scans the
// command path / args for a post-noun `-R`/`--repo` (gh accepts it in either
// position). Only a two-segment `owner/repo` is returned; a bare repo name or
// an unparseable value yields "" (treated as "no explicit target" → own-repo).
func ghExplicitRepoTarget(leadingRepo string, cmd []string) string {
	if leadingRepo != "" {
		return normalizeRepoSlug(leadingRepo)
	}
	for i := 0; i < len(cmd); i++ {
		a := cmd[i]
		switch {
		case a == "-R" || a == "--repo":
			if i+1 < len(cmd) {
				return normalizeRepoSlug(strings.ToLower(cmd[i+1]))
			}
		case strings.HasPrefix(a, "-R") && len(a) > 2:
			return normalizeRepoSlug(strings.ToLower(strings.TrimPrefix(a, "-R")))
		case strings.HasPrefix(a, "--repo="):
			return normalizeRepoSlug(strings.ToLower(strings.TrimPrefix(a, "--repo=")))
		}
	}
	return ""
}

// normalizeRepoSlug reduces a `-R`/`--repo` value to a bare lowercased
// `owner/repo`. gh accepts `owner/repo`, a full URL
// (`https://github.com/owner/repo`), or `[HOST/]owner/repo`; this strips a
// scheme/host prefix and a trailing `.git`, keeping the last two path segments.
// Returns "" for a value that is not a two-segment owner/repo (e.g. a bare repo
// name, which gh resolves against the current login — not a cross-repo target
// the gate can compare).
func normalizeRepoSlug(v string) string {
	if v == "" {
		return ""
	}
	if strings.Contains(v, "://") {
		if idx := strings.Index(v, "://"); idx >= 0 {
			v = v[idx+3:]
		}
		if slash := strings.IndexByte(v, '/'); slash >= 0 {
			v = v[slash+1:] // drop host
		}
	}
	v = strings.TrimSuffix(v, ".git")
	v = strings.Trim(v, "/")
	parts := strings.Split(v, "/")
	if len(parts) < 2 {
		return ""
	}
	owner := parts[len(parts)-2]
	repo := parts[len(parts)-1]
	if owner == "" || repo == "" {
		return ""
	}
	return owner + "/" + repo
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

// ghIrreparableDeny denies the DENY-tier gh operations: deletes of things
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
				"Blocked: 'gh repo delete' is irreparable — a repository is not a recoverable git object. Denied. "+
					"If archiving is the intent, 'gh repo archive' is reversible; do a genuine deletion deliberately "+
					"via the GitHub UI, not as part of automated work.")
		case "rename":
			return d("gh repo rename (#64)",
				"Blocked: 'gh repo rename' changes the repository's identity and breaks every existing reference. "+
					"Denied; rename deliberately via the GitHub UI if genuinely intended.")
		case "transfer":
			return d("gh repo transfer (#64)",
				"Blocked: 'gh repo transfer' moves the repository to another owner — irreparable from here. Denied. "+
					"Transfer deliberately via the GitHub UI's repository settings if genuinely intended.")
		}
	case "release":
		switch verb {
		case "delete":
			return d("gh release delete (#64)",
				"Blocked: 'gh release delete' destroys release assets, which are NOT git objects and not "+
					"recoverable. Denied. If a release should be withdrawn without destroying its assets, "+
					"'gh release edit <tag> --draft' un-publishes it reversibly; delete deliberately via the "+
					"GitHub UI if the assets are genuinely disposable.")
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
				"Blocked: 'gh gist delete' destroys the gist irreparably. Denied. If the content should just be "+
					"withdrawn, 'gh gist edit' can empty it reversibly; delete deliberately via the GitHub UI if it "+
					"is genuinely disposable.")
		}
	case "secret", "variable":
		// Any secret/variable write (set/delete/remove) is a write-only mutation
		// of values the gate cannot recover. Default-deny the whole noun's
		// mutating verbs; the read verbs (list/get) fall through to the
		// enumeration path, where isGhReadOnly ALLOWs them (secret/variable
		// are in its known-noun set for reads only).
		switch verb {
		case "list", "get":
			return Decision{}, false // a read; fall through to the enumerated-read ALLOW.
		default:
			return d("gh "+noun+" write (#64)",
				"Blocked: 'gh "+noun+" "+verb+"' writes or deletes a "+noun+" value the gate cannot recover. "+
					"Denied; set "+noun+"s deliberately via the GitHub UI's Settings → Secrets and variables, not "+
					"as part of automated work.")
		}
	case "ruleset":
		if verb == "delete" {
			return d("gh ruleset delete (#64)",
				"Blocked: 'gh ruleset delete' weakens branch-protection guardrails — it disarms the guardrail the "+
					"rest of this policy relies on. Denied. Adjust rulesets deliberately via the GitHub UI's "+
					"Settings → Rules, or re-run the gh-repo-setup-protection skill to reconverge them.")
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

// classifyghAPIDeny wraps the shared DENY label for the `gh api` shapes that
// still deny even after the write tiers softened: --hostname (own
// justification — the egress proxy's host-allowlist can see and control it)
// and an unclassifiable graphql document.
func classifyghAPIDeny(reason string) Decision {
	return deny("gh api deny (#64/#113)", reason)
}

// ghAPIGraphQLRedirectAsk is the redirect-to-file carve-out shared by both
// `gh api graphql` ALLOW paths — the provably query-only document and
// the allow-listed-mutations document. Redirecting an allowed graphql
// call's stdout/stderr into a real file turns a sanctioned read or metadata
// write into an exfil channel, so it escalates to a human either way.
func ghAPIGraphQLRedirectAsk() Decision {
	return ask("gh api graphql redirect-to-file",
		"'gh api graphql' with stdout/stderr redirected to a real file can exfiltrate. Confirm the target is intended.")
}

// classifyGhAPI gates `gh api` (bypass gate 1). It walks the argv after
// `api`, applies the --hostname DENY and the write ASK tiers first, then
// branches on the endpoint:
//
//   - --hostname (any form, signed-request redirect to a non-default host) →
//     DENY unconditionally — this is the one shape the egress proxy's
//     host-allowlist can see and control, so it keeps its own justification
//     (not the write/read asymmetry the other tiers below hinge on).
//   - Write ASK tiers (they denied outright before): an x-http-method-override
//     header, an explicit non-GET method, and a request-body flag
//     (-f/-F/--field/--raw-field/--input) with no explicit GET method
//     (implicit-POST flip). A `gh api` REST write is a credential-carrying
//     mutation of remote repo state the microVM cannot roll back — the same
//     "not backstopped by containment" class as an `aws` mutation and a
//     `git push` refspec — so it ASKs (one-click human approval) rather than
//     DENYs. The `-XGET -f …` carve-out (a GET with params) is preserved.
//   - graphql endpoint (Design A): classify the query DOCUMENT instead of
//     blanket-denying. The document is extractable only from a literal
//     `-f query=…` / `--raw-field query=…` value; `-F query=…`, `--input`, or no
//     statically-present query → DENY (genuinely unclassifiable). A provably
//     query-only document → ALLOW (subject to the redirect-to-file ASK); a
//     fragment-free mutation document whose every top-level field is on the
//     curated issue-metadata allowlist → ALLOW (same redirect-to-file
//     ASK); any other mutation-bearing document → ASK naming the mutation
//     fields; anything else (subscription, garbage, unbalanced) → DENY.
//   - REST endpoint (Design B): a known-flag-only GET whose endpoint is on
//     the path-prefix allowlist → ALLOW (subject to the redirect-to-file ASK); a
//     `://`- or `..`-bearing endpoint → DENY; an unknown flag or a non-matching
//     endpoint → ASK.
//
// args is the full gh argv (after the program), i.e. it still contains the
// leading `api` token and gh's globals. sc is threaded through only for the
// redirect-to-file ASK carve-out on an otherwise-allowed form.
func classifyGhAPI(args []string, sc simpleCommand) Decision {
	// Walk the tokens after `api`. Track method, body-bearing flags, graphql,
	// the endpoint positional, and whether the graphql query (if any) was
	// supplied via a body flag that is NOT a literal string field. hostname
	// DENYs immediately; the method-override header ASKs immediately.
	var method string
	var endpoint string
	bodyBearing := false
	graphql := false
	// graphqlQueryViaNonLiteral is set when a `query` field is supplied via a
	// body flag that is not literal (`-F query=…` / `--field query=…` do @file
	// expansion + coercion; `--input` reads the whole body from a file). Such a
	// document is not in argv and so is genuinely unclassifiable → DENY on the
	// graphql path.
	graphqlQueryViaNonLiteral := false
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
		case strings.HasPrefix(a, "-X") && len(a) > 2:
			method = strings.TrimPrefix(a, "-X")
		case strings.HasPrefix(a, "--method="):
			method = strings.TrimPrefix(a, "--method=")
		case a == "-F" || a == "--field":
			bodyBearing = true
			if i+1 < len(args) {
				if strings.HasPrefix(args[i+1], "query=") {
					graphqlQueryViaNonLiteral = true // -F/--field query=… is coerced/@-expanded
				}
				i++ // consume the value
			}
		case a == "--input":
			bodyBearing = true
			if i+1 < len(args) {
				graphqlQueryViaNonLiteral = true // whole body from a file → unclassifiable
				i++
			}
		case a == "-f" || a == "--raw-field":
			// Literal string field. Body-bearing, but the query (if any) IS in
			// argv and so is classifiable on the graphql path.
			bodyBearing = true
			if i+1 < len(args) {
				i++ // consume the value
			}
		case strings.HasPrefix(a, "-F") && len(a) > 2:
			bodyBearing = true
			if strings.HasPrefix(strings.TrimPrefix(a, "-F"), "query=") {
				graphqlQueryViaNonLiteral = true
			}
		case strings.HasPrefix(a, "--field="):
			bodyBearing = true
			if strings.HasPrefix(strings.TrimPrefix(a, "--field="), "query=") {
				graphqlQueryViaNonLiteral = true
			}
		case strings.HasPrefix(a, "--input="):
			bodyBearing = true
			graphqlQueryViaNonLiteral = true
		case strings.HasPrefix(a, "-f") && len(a) > 2,
			strings.HasPrefix(a, "--raw-field="):
			bodyBearing = true
		case a == "--hostname":
			// --hostname redirects the request to a non-default GitHub host —
			// the gh analog of `aws --endpoint-url`. The signed request (carrying
			// the credential) can be aimed at an attacker-controlled host
			// (credential/data exfil, SSRF). DENY unconditionally, symmetric with
			// the aws --endpoint-url deny (the spec's appendix step 6).
			return classifyghAPIDeny(
				"Blocked: 'gh api --hostname' redirects the SIGNED request — carrying your credential — to a " +
					"non-default host (credential/data exfil and SSRF), the gh analog of 'aws --endpoint-url'. Denied.")
		case strings.HasPrefix(a, "--hostname="):
			return classifyghAPIDeny(
				"Blocked: 'gh api --hostname' redirects the SIGNED request — carrying your credential — to a " +
					"non-default host (credential/data exfil and SSRF), the gh analog of 'aws --endpoint-url'. Denied.")
		case a == "-H" || a == "--header":
			if i+1 < len(args) {
				if headerIsMethodOverride(args[i+1]) {
					return ask("gh api x-http-method-override (#162)",
						"'gh api' with an X-HTTP-Method-Override header performs a write disguised as a GET. "+
							"Confirm this write is intended.")
				}
				i++
			}
		case strings.HasPrefix(a, "-H") && len(a) > 2:
			if headerIsMethodOverride(strings.TrimPrefix(a, "-H")) {
				return ask("gh api x-http-method-override (#162)",
					"'gh api' with an X-HTTP-Method-Override header performs a write disguised as a GET. "+
						"Confirm this write is intended.")
			}
		case strings.HasPrefix(a, "--header="):
			if headerIsMethodOverride(strings.TrimPrefix(a, "--header=")) {
				return ask("gh api x-http-method-override (#162)",
					"'gh api' with an X-HTTP-Method-Override header performs a write disguised as a GET. "+
						"Confirm this write is intended.")
			}
		case strings.HasPrefix(a, "-") && a != "-":
			// A flag the walker does not consume above. The REST GET-gate's
			// unknown-flag scan (Deviation 1) surfaces it; nothing to track here.
			// A value-taking known flag (e.g. `-q .login`) is handled there too.
		default:
			// A positional: the endpoint path (first one wins; gh takes a single
			// endpoint). `graphql` is the GraphQL endpoint.
			if endpoint == "" {
				endpoint = a
			}
			if a == "graphql" {
				graphql = true
			}
		}
	}

	// Write ASK tiers: an explicit non-GET method, or a body-bearing
	// flag with no explicit GET method (implicit-POST flip). These fire BEFORE the
	// endpoint branch so a `-X DELETE graphql` or a `-f a=b`-flipped POST to a
	// REST endpoint asks regardless of endpoint.
	if method != "" && !strings.EqualFold(method, "GET") {
		return ask("gh api non-GET method (#162)",
			"'gh api' with a non-GET method (-X/--method "+method+") performs a write. Confirm this write is intended.")
	}
	if bodyBearing && method == "" && !graphql {
		// Body-bearing on a REST endpoint with no explicit method flips the
		// default GET to a POST → a write. (On the graphql endpoint the body flag
		// is how the query is passed; the graphql path below classifies the
		// document instead of asking on the body flag.) The `-XGET -f …`
		// carve-out (method == "GET") stays a read and falls through.
		return ask("gh api implicit-POST body flag (#162)",
			"'gh api' with a request-body flag (-f/-F/--field/--raw-field/--input) and no explicit GET method "+
				"implicitly flips to POST and performs a write. Confirm this write is intended.")
	}

	// --- graphql endpoint (Design A): classify the query document. ---
	if graphql {
		if graphqlQueryViaNonLiteral {
			return classifyghAPIDeny(
				"Blocked: 'gh api graphql' with the query supplied via -F/--field (which does @file expansion and " +
					"type coercion) or --input (whole body from a file) carries no statically-present document — the " +
					"gate cannot classify it. Pass the query literally via -f query='…' / --raw-field query='…' so a " +
					"query-only document can be allowed, or run the mutation through a sanctioned skill.")
		}
		doc, ok := graphqlQueryDoc(args)
		if !ok {
			return classifyghAPIDeny(
				"Blocked: 'gh api graphql' has no exactly-one statically-present query document (either no literal " +
					"-f query=…/--raw-field query=… at all, or more than one such field) and is unclassifiable from " +
					"argv. Pass exactly one literal query field via -f query='…' so a query-only document can be allowed.")
		}
		res := scanGraphQLDoc(doc)
		if res.queryOnly {
			if sc.hasRedirectToFile {
				return ghAPIGraphQLRedirectAsk()
			}
			return allow("gh api graphql is a provably query-only (read) document")
		}
		if len(res.mutationFields) > 0 {
			// A document whose every top-level mutation field is on the
			// curated issue-metadata allowlist ALLOWs — these are the issues
			// plugin's sanctioned, recoverable, human-visible writes, and the
			// per-mutation prompt storm is what that issue exists to remove. A
			// bundled subscription rides no allowlist entry, so its presence keeps
			// the un-narrowed verdict; so does ANY fragment indirection, because the
			// scanner names the fragment rather than the fields it expands to and
			// a spread named after an allow-listed mutation would otherwise
			// launder an arbitrary one (`mutation { ...addSubIssue } fragment
			// addSubIssue on Mutation { deleteIssue(…) }`). Both signals only ever
			// withhold the ALLOW: the document falls through to the ASK below.
			if !res.sawSubscription && !res.sawFragment && allGraphQLMutationFieldsAllowed(res.mutationFields) {
				if sc.hasRedirectToFile {
					return ghAPIGraphQLRedirectAsk()
				}
				return allow("gh api graphql carries only allow-listed issue-metadata mutations (" +
					strings.Join(res.mutationFields, ", ") + ")")
			}
			return ask("gh api graphql mutation (#113)",
				"'gh api graphql' carries a mutation operation ("+strings.Join(res.mutationFields, ", ")+"). "+
					"Mutations write to GitHub; confirm this is intended.")
		}
		// Not query-only and no nameable mutation field: a subscription, an
		// unbalanced/garbage document, or otherwise unclassifiable → DENY.
		return classifyghAPIDeny(
			"Blocked: 'gh api graphql' document is not provably query-only (it contains a subscription, is " +
				"unbalanced, or is otherwise unclassifiable) and no top-level mutation field could be named. Denied. " +
				"Pass a well-formed query-only document, or run the write through a sanctioned skill.")
	}

	// --- REST endpoint (Design B): path-prefix GET-gate. ---
	rest := classifyGhAPIREST(endpoint, args)
	if rest.Bucket == BucketAllow && sc.hasRedirectToFile {
		return ask("gh api redirect-to-file",
			"'gh api' with stdout/stderr redirected to a real file can exfiltrate. Confirm the target is intended.")
	}
	return rest
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
		// secret/variable are here ONLY for their read verbs (list/get). Their
		// WRITE verbs (set/delete) never reach this map — ghIrreparableDeny DENYs
		// them before isGhReadOnly is consulted — so a `gh secret list` reads
		// while `gh secret set` denies (reads stay ALLOW as the floor moves
		// off writes).
		"secret": true, "variable": true,
	}
	// `gh api` is never classified here: classifyGh routes it to classifyGhAPI
	// (the api gate) BEFORE isGhReadOnly is ever consulted, so this
	// guard is belt-and-suspenders. The api gate — not this read-only shortcut —
	// owns the allow/ask/deny decision for `gh api` (a graphql query-only doc or
	// an allow-listed REST GET allows there; a write denies/asks there).
	if noun == "api" {
		return false
	}
	if !knownNouns[noun] {
		return false
	}
	return readVerbs[verb]
}

// classifyAws classifies an `aws <service> <operation>` invocation. Per the
// resolved design decisions this classifier NEVER defers:
//
//   - DENY:  the precondition (non-static argv, inline env-assignment);
//     --endpoint-url (redirects the SIGNED request to an attacker host —
//     credential/data exfil + SSRF).
//   - ASK:   reads that return credentials/secrets (sts get-session-token,
//     ecr get-login-password, secretsmanager get-secret-value, ssm
//     get-parameter --with-decryption, …); and every other aws
//     op the gate cannot prove read-only. An aws mutation is not a
//     guest-local operation: it carries the guest's credentials to a control
//     plane OUTSIDE the VM and mutates real cloud state the VM cannot roll
//     back, so containment-lives-in-the-microVM does not apply to it.
//   - ALLOW: read-only ops only (describe-/list-/get- hyphen anchor + the
//     explicit read-only whitelist).
//
// Classification is on the parsed operation TOKEN, never a substring match (§4).
func classifyAws(args []string, sc simpleCommand) Decision {
	// Precondition: static argv + no inline env-assignment, gated FIRST.
	if d, hit := preconditionDeny("aws", sc); hit {
		return d
	}

	// DENY: --endpoint-url redirects the signed request (with credentials)
	// to an arbitrary host. Gate this BEFORE op classification so even a
	// read-shaped op cannot exfiltrate via a redirected endpoint.
	if awsHasEndpointURL(args) {
		return deny("aws --endpoint-url (#64)",
			"Blocked: 'aws --endpoint-url <url>' redirects the SIGNED request — carrying your credentials — to an "+
				"arbitrary host (credential/data exfil and SSRF). Denied. Remove --endpoint-url; the default "+
				"AWS endpoints are the only sanctioned targets.")
	}

	svc, op, ok := awsServiceAndOp(args)
	if !ok {
		// An unrecognized leading global flag of unknown arity desynced the
		// service/operation split. We cannot trust which token is the operation,
		// so a credential read could be hiding behind the shift. Fail closed to
		// ASK rather than guess (the anti-desync decision).
		return ask("aws unknown-global (#64)",
			"'aws' has an unrecognized leading global flag whose argument shape the permission gate cannot "+
				"determine; this can hide a credential read behind a shifted operation token. Confirm the command "+
				"is intended, or remove the unrecognized global flag.")
	}
	if svc == "" || op == "" {
		// Not a recognizable `aws <service> <operation>` shape, so there is no
		// service/operation to apply policy to — ALLOW. This is unrelated to
		// the ask-by-default-for-mutations policy below: with nothing
		// classifiable, there is simply nothing here to gate.
		return allow("aws (no classifiable service/operation)")
	}

	// ASK: credential/secret reads.
	if awsCredentialRead(svc, op, args) {
		return ask("aws credential-read (#64)",
			fmt.Sprintf("'aws %s %s' returns credentials or secrets. Confirm this is intended; do not pipe the "+
				"output anywhere it could be captured.", svc, op))
	}

	// `aws configure get <non-secret-key>` reads the LOCAL config store
	// only (no network call, no cloud-side effect), so it ALLOWs even though it
	// is a bare-verb command excluded from awsReadOnlyOp's hyphen anchor.
	// awsCredentialRead already routed secret-bearing keys to ASK above, so
	// reaching here with svc/op == configure/get means the key was recognized
	// as non-secret.
	if svc == "configure" && op == "get" {
		return allow("aws configure get <non-secret-key> reads local config only")
	}

	// A real-file redirect is the residual exfil concern that ASKs (cannot
	// defer per the never-defer decision).
	if sc.hasRedirectToFile {
		return ask("aws redirect-to-file",
			"'aws' with stdout redirected to a real file can exfiltrate. Confirm the target is intended.")
	}

	if awsReadOnlyOp(op) {
		return allow(fmt.Sprintf("aws %s %s is a read-only operation", svc, op))
	}
	// ASK default: every aws op the gate cannot prove read-only ASKs. The
	// microVM cannot contain an authenticated AWS mutation: the call carries
	// the guest's credentials to a control plane OUTSIDE the VM and mutates
	// real cloud state the VM cannot roll back. The only VM-level AWS control
	// is the egress proxy, which gates by host:port/SNI (per service per
	// region) and cannot distinguish `s3 ls` from `s3 rm` inside one TLS
	// stream. So a non-read aws op escalates to a human rather than
	// auto-allowing.
	return ask("aws non-read op",
		fmt.Sprintf("'aws %s %s' is not a provably read-only operation and can mutate real "+
			"cloud state that the sandbox cannot roll back. Confirm this is intended.", svc, op))
}

// awsHasEndpointURL reports whether the args carry an --endpoint-url flag in
// any form aws accepts: the exact spaced (`--endpoint-url <url>`) or glued
// (`--endpoint-url=<url>`) form, OR an unambiguous prefix abbreviation
// (`--endp http://evil`, `--endpoint=…`). Resolving abbreviations here is
// security-critical: --endpoint-url redirects the signed request to an
// attacker host, and an exact-only check would let `--endp` evade the deny.
func awsHasEndpointURL(args []string) bool {
	for _, a := range args {
		if canonical, _, _, known := resolveAwsGlobal(a); known && canonical == "--endpoint-url" {
			return true
		}
	}
	return false
}

// awsCredentialRead reports whether an `aws <svc> <op>` is one of the reads that
// returns credentials or secrets (the ASK tier). The ssm get-parameter family
// is a credential read only with --with-decryption.
//
// This decision is the WHITELIST ANCHOR for the credential-exposure
// surface, not a blacklist. The exact-pair switch below still names the
// recognized credential reads (so they keep their specific explanatory ASK
// message), but it is no longer the ONLY thing standing between a
// credential-returning read and the ALLOW floor. The blacklist could only ever
// be one AWS release behind — a new credential-returning `get-*` op the switch
// does not name (`eks get-token`, `redshift get-cluster-credentials`, `sso
// get-role-credentials`, `lightsail get-instance-access-details`, …) would
// reach ALLOW via awsReadOnlyOp's `get-` prefix, and a miss there costs a
// LEAKED SECRET, not a prompt. So after the exact-pair switch, a STRUCTURAL
// credential-material name signal (awsCredentialShapedGet) pulls any remaining
// `get-*` whose operation name carries a credential-material token back to the
// ASK tier BY CONSTRUCTION. The failure asymmetry is the guide: on this
// (allow/deny) surface a miss must cost a prompt, never a leak, so the residual
// `get-*` reads are default-deny-shaped (allowed only if they do NOT look
// credential-shaped) rather than blanket-allowed.
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
	case "configure":
		// `aws configure get <key>` reads the LOCAL credential store. It is a
		// bare-verb command (no hyphen) so it is excluded from awsReadOnlyOp;
		// when the key it reads is secret-bearing it is a credential read → ASK
		// (exposure harm). The key is the next positional after `get`.
		if op == "get" {
			return awsConfigureReadsSecret(args)
		}
	}
	// Structural whitelist anchor: any `get-*` operation whose NAME carries a
	// credential-material token is treated as a credential read regardless of
	// service, so a credential-returning `get-*` the exact-pair switch above does
	// not enumerate still ASKs instead of reaching the ALLOW floor.
	return awsCredentialShapedGet(op)
}

// awsCredentialMaterialTokens are the hyphen-segment name tokens that mark an
// aws operation as returning credential material. They generalize the exact-pair
// blacklist in awsCredentialRead into a STRUCTURAL signal: AWS names its
// credential-returning reads with these tokens (`get-session-token`,
// `get-cluster-credentials`, `get-login-password`, `get-secret-value`,
// `get-instance-access-details`, `get-role-credentials`, …), so matching the
// token catches whole families at once — including future ops that follow the
// convention — rather than one exact (svc, op) pair at a time.
//
// The tokens are matched as WHOLE hyphen segments (see awsCredentialShapedGet),
// not substrings, so a benign op is not caught by an incidental substring. The
// set is deliberately conservative toward ASK: a benign `get-*` op that happens
// to carry one of these segments costs one spurious prompt (cheap, the accepted
// cost on the allow side), whereas a missed credential read costs a leak.
var awsCredentialMaterialTokens = map[string]bool{
	"credential":  true, // iam get-credential-report
	"credentials": true, // redshift get-cluster-credentials, sso get-role-credentials, cognito-identity get-credentials-for-identity
	"token":       true, // sts get-session-token, ecr get-authorization-token, eks get-token, cognito-identity get-open-id-token
	"password":    true, // ecr get-login-password
	"secret":      true, // secretsmanager get-secret-value
	"details":     true, // lightsail get-instance-access-details (the SSH key material segment)
}

// awsCredentialShapedGet reports whether a `get-*` operation name carries a
// credential-material token as one of its hyphen segments. Scoped to the
// `get-` prefix on purpose: `get-*` fetches one named resource, so a
// credential-material segment means the resource IS credential material. The
// convention-allowed `list-*`/`describe-*` reads are NOT scanned — they return
// collections/metadata (e.g. `iam list-access-keys`, `codecatalyst
// list-access-tokens` return identifiers/metadata, never the secret), so
// scanning them would trade real over-blocking of routine surveys for no
// exposure gain. Non-read prefixes (`generate-`/`request-`/`send-`) never reach
// the ALLOW floor at all — they already fall through awsReadOnlyOp to the
// ASK default — so they need no guard here.
func awsCredentialShapedGet(op string) bool {
	op = strings.ToLower(op)
	if !strings.HasPrefix(op, "get-") {
		return false
	}
	for _, seg := range strings.Split(op, "-") {
		if awsCredentialMaterialTokens[seg] {
			return true
		}
	}
	return false
}

// awsConfigureReadsSecret reports whether an `aws configure get …` invocation
// names a secret-bearing key. The key may be a bare positional
// (`aws configure get aws_secret_access_key`) or profile-qualified via
// `--profile`; either way it appears as a positional token after `configure`
// and `get`. A profile-dotted form (`profile.aws_secret_access_key`) is matched
// on its trailing segment. Conservative: an unrecognized key is treated as a
// secret read too (fail-closed toward ASK), since `aws configure get` of a
// custom key can still surface a secret and the cost is one prompt.
func awsConfigureReadsSecret(args []string) bool {
	seenConfigure, seenGet := false, false
	for i := 0; i < len(args); i++ {
		a := args[i]
		// Skip global flags (resolved prefix-aware, same as awsServiceAndOp) so
		// a value-taking global's value is not read as the key positional.
		// Reaching here means awsServiceAndOp already cleanly recognized
		// `configure get`, so the global screen parsed.
		if strings.HasPrefix(a, "--") {
			if _, takesValue, glued, known := resolveAwsGlobal(a); known {
				if takesValue && !glued {
					i++ // consume its separate value token
				}
				continue
			}
		}
		if strings.HasPrefix(a, "-") {
			continue
		}
		if !seenConfigure {
			if a == "configure" {
				seenConfigure = true
			}
			continue
		}
		if !seenGet {
			if a == "get" {
				seenGet = true
			}
			continue
		}
		// First positional after `configure get` is the key.
		key := strings.ToLower(a)
		if j := strings.LastIndexByte(key, '.'); j >= 0 {
			key = key[j+1:] // strip `profile.` qualifier
		}
		// Recognized non-secret keys read-allow; recognized + unrecognized
		// secret-shaped keys ASK (fail-closed toward ASK).
		switch key {
		case "region", "output", "aws_access_key_id", "cli_pager":
			return false
		}
		return true
	}
	return false
}

// awsGlobalFlags is the COMPLETE, authoritative set of AWS CLI v2 global
// options (verified against the AWS CLI User Guide "Command line options", the
// `aws` command reference, and `aws help`, CLI 2.34.x), each mapped to whether
// it consumes a following VALUE token. It is deliberately exhaustive: the whole
// point of the aws classifier is to ALLOW the many safe commands without
// interrupting the human, so an incomplete map (which would push benign
// commands to a spurious ASK) is a defect, not a safe default. Global flags are
// a closed, slow-moving set — unlike the open-ended per-operation flags, which
// appear AFTER the operation and never move the service/operation split.
//
// true  = takes a value in the space-separated form (`--region us-east-1`).
// false = boolean switch (`--debug`).
var awsGlobalFlags = map[string]bool{
	// value-taking
	"--ca-bundle": true, "--cli-binary-format": true, "--cli-connect-timeout": true,
	"--cli-error-format": true, "--cli-read-timeout": true,
	"--color": true, "--endpoint-url": true, "--output": true, "--profile": true,
	"--query": true, "--region": true,
	// boolean. Note: aws exposes the pager control ONLY as the boolean
	// `--no-cli-pager`; there is no value-taking `--cli-pager` global (aws
	// rejects `--cli-pager <v>` as an invalid choice), so it is absent above.
	"--cli-auto-prompt": false, "--debug": false, "--no-cli-auto-prompt": false,
	"--no-cli-pager": false, "--no-paginate": false, "--no-sign-request": false,
	"--no-verify-ssl": false, "--version": false,
}

// resolveAwsGlobal resolves a single `--token` to a canonical AWS global flag,
// mirroring aws's own argparse behavior: an exact name matches, and an
// UNAMBIGUOUS prefix abbreviation matches (aws accepts `--reg` for `--region`;
// AWS documents this for global options). An AMBIGUOUS prefix (matching ≥2
// globals, e.g. `--c`) is rejected by aws itself, so we report it as not a
// known global. The token may be `=`-joined (`--region=us-east-1`,
// `--reg=us-east-1`); the name is taken as the part before `=`.
//
// Returns:
//   - canonical: the resolved canonical flag name ("" if not a known global).
//   - takesValue: whether the canonical flag consumes a value token.
//   - glued: whether the token carried its value inline via `=` (so no separate
//     value token is consumed).
//   - known: whether the token resolved to exactly one known global.
//
// Handling abbreviations here is load-bearing: without it, `--endp http://evil`
// (an abbreviation of --endpoint-url) would evade the endpoint-url deny AND
// desync the operation, and `--reg us-east-1 ec2 describe-instances` (benign)
// would spuriously ASK — both failures the exhaustive-allow goal forbids.
func resolveAwsGlobal(token string) (canonical string, takesValue, glued, known bool) {
	if !strings.HasPrefix(token, "--") {
		return "", false, false, false
	}
	name := token
	if i := strings.IndexByte(token, '='); i >= 0 {
		name = token[:i]
		glued = true
	}
	// Exact match first.
	if tv, ok := awsGlobalFlags[name]; ok {
		return name, tv, glued, true
	}
	// Unambiguous prefix abbreviation: match iff exactly one global has `name`
	// as a prefix. aws rejects ambiguous abbreviations, so we do too.
	match := ""
	for flag := range awsGlobalFlags {
		if strings.HasPrefix(flag, name) {
			if match != "" {
				return "", false, glued, false // ambiguous → not a known global
			}
			match = flag
		}
	}
	if match != "" {
		return match, awsGlobalFlags[match], glued, true
	}
	return "", false, glued, false
}

// awsServiceAndOp extracts the service and operation tokens, skipping aws's
// global options. It returns ok=false when it cannot trust the positional
// split — specifically when it meets an UNRECOGNIZED flag whose arity
// (value-taking vs. boolean) is unknown BEFORE both the service and operation
// tokens have been captured. Guessing the arity is the exact desync the
// anti-desync decision warns about: a value-taking flag the gate does not know
// (`--some-unknown-global x`) would leave its value (`x`) as a stray positional,
// shifting svc/op by one and slipping a credential read past the ASK tier to
// the ALLOW floor. So an unknown flag in that window fails closed:
// awsServiceAndOp returns ok=false and classifyAws routes that to ASK.
//
// The fail-closed window extends until BOTH positionals are captured, not just
// the service token. aws places the real operation AFTER global flags for
// `aws configure get`, `aws sts get-session-token`, etc., so an unknown
// value-flag WEDGED between service and operation
// (`aws sts --cli-error-format json get-session-token`) desyncs the op token
// exactly as a leading one desyncs the service token. An unknown flag AFTER
// both tokens are captured is a genuine operation flag and cannot move svc/op,
// so it is harmless and does not trip the guard.
func awsServiceAndOp(args []string) (svc, op string, ok bool) {
	var positionals []string
	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case strings.HasPrefix(a, "--"):
			_, takesValue, glued, known := resolveAwsGlobal(a)
			if !known {
				// An unrecognized long flag of unknown arity. Until BOTH the
				// service and operation tokens are captured we cannot trust the
				// positional split — a value-taking unknown would leave its
				// value as a stray positional and shift svc/op — so fail closed
				// (the anti-desync decision). Once both are captured, an unknown flag is
				// an operation flag and is harmless to the split.
				if len(positionals) < 2 {
					return "", "", false
				}
				i++
				continue
			}
			if takesValue && !glued {
				i += 2 // consume the flag AND its separate value token
			} else {
				i++ // boolean, or `--flag=value` carrying its own value
			}
		case strings.HasPrefix(a, "-"):
			// A single-dash token. aws has no single-dash global aliases (every
			// documented global is `--long`), so before the service/op are
			// captured this is an unknown of unknown arity → fail closed;
			// after, it is an operation flag and harmless.
			if len(positionals) < 2 {
				return "", "", false
			}
			i++
		default:
			positionals = append(positionals, a)
			i++
		}
	}
	if len(positionals) >= 2 {
		return positionals[0], positionals[1], true
	}
	return "", "", true
}

// awsReadOnlyOp reports whether an aws operation token is read-only. The token
// must be a HYPHENATED operation (list-*, describe-*, get-*) — the hyphen anchor
// is load-bearing: it admits the convention-named API reads
// (`get-object`, `list-buckets`, `describe-instances`) while EXCLUDING the
// bare-verb high-level commands that don't follow the convention and are not
// safe (`aws configure get/set/list`, `aws s3 ls/cp`, `aws lambda invoke`). A
// bare `get`/`list`/`describe` (no hyphen) must NOT match — e.g.
// `aws configure get aws_secret_access_key` reads the local credential store
// and is routed to the credential-read ASK tier, not allowed here. The match is
// on the whole hyphen-segmented prefix, NOT a substring (so "delete-list-xyz"
// would not match list).
func awsReadOnlyOp(op string) bool {
	op = strings.ToLower(op)
	for _, prefix := range []string{"list", "describe", "get"} {
		if strings.HasPrefix(op, prefix+"-") {
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

// ghGlobalValueFlags are gh's leading global flags that consume a following
// VALUE token (in the space-separated form). `-R`/`--repo` selects the target
// repository and is accepted before the noun (`gh -R owner/repo issue delete`).
// If the value token is not consumed it is mistaken for the noun and the
// command slips past the deny tier to the ALLOW floor (the anti-desync decision).
var ghGlobalValueFlags = map[string]bool{
	"-R":     true,
	"--repo": true,
}

// ghGlobalBoolFlags are gh's leading global flags that take no value. These
// produce no dangerous operation on their own; they are recognized only so the
// fail-closed unknown-flag DENY below does not fire on them.
var ghGlobalBoolFlags = map[string]bool{
	"--help":    true,
	"-h":        true,
	"--version": true,
}

// parseGhGlobals walks the leading global-flag screen of a `gh` invocation and
// returns the command-path tokens (noun verb …) with all leading globals — and
// the values of value-taking globals — consumed. It stops at the first
// non-flag token (the noun).
//
// Two desync defenses, both motivated by the same hazard (with an ALLOW
// floor in place, a missed deny is a silent auto-allow, so the deny tier must
// be un-bypassable):
//
//   - A known value-taking global (`-R owner/repo`) consumes its value token so
//     the value (e.g. a repo slug) is never read as the noun. The glued forms
//     (`-Rowner/repo`, `--repo=owner/repo`) carry their own value and need no
//     extra consumption.
//   - An UNKNOWN leading global fails closed: parseGhGlobals returns a DENY
//     rather than skipping the flag, because an unrecognized global could take a
//     value (desyncing detection) or otherwise change behavior the gate cannot
//     reason about. Default-deny within the gate mirrors the gh-api unknown-flag
//     handling; the cost of a false deny is one human click.
//
// On the fail-closed path the second return is a non-nil DENY Decision and the
// caller returns it immediately. On the normal path the second return is nil.
//
// The third return is the value of any leading `-R`/`--repo` global (in spaced,
// glued, or `=`-joined form), lowercased — the explicit target repo used by the
// foreign-target write scoping. It is "" when no `-R`/`--repo` global was
// given. A `-R`/`--repo` given AFTER the noun (as a normal command flag rather
// than a leading global) is captured separately by the caller.
func parseGhGlobals(args []string) ([]string, *Decision, string) {
	i := 0
	repo := ""
	for i < len(args) {
		a := args[i]
		if !strings.HasPrefix(a, "-") {
			break // the noun — end of the global screen.
		}
		switch {
		case ghGlobalValueFlags[a]:
			if i+1 < len(args) {
				repo = strings.ToLower(args[i+1])
			}
			i += 2 // consume the flag AND its value token.
		case ghGlobalBoolFlags[a]:
			i++
		case isGhKnownGluedGlobal(a):
			if v, ok := ghGluedRepoValue(a); ok {
				repo = strings.ToLower(v)
			}
			i++ // `-Rfoo` / `--repo=foo` carry their value inline.
		default:
			d := deny("gh unknown-global (#64)",
				"Blocked: an unrecognized leading 'gh' global flag ("+a+") cannot be classified safely — it may "+
					"consume the following token as its value, desyncing the gate's noun/verb detection and letting an "+
					"irreparable operation slip past the deny tier. Fail-closed (issue #64 decision 3). Run gh without "+
					"the unrecognized global; if it is genuinely needed, surface it to the human.")
			return nil, &d, ""
		}
	}
	return args[i:], nil, repo
}

// ghGluedRepoValue extracts the value from a glued/`=`-joined `-R`/`--repo`
// global (`-Rowner/repo`, `--repo=owner/repo`). Returns ("", false) for other
// glued globals.
func ghGluedRepoValue(a string) (string, bool) {
	if strings.HasPrefix(a, "-R") && len(a) > 2 {
		return strings.TrimPrefix(a, "-R"), true
	}
	if strings.HasPrefix(a, "--repo=") {
		return strings.TrimPrefix(a, "--repo="), true
	}
	return "", false
}

// isGhKnownGluedGlobal reports whether a leading flag token is a recognized gh
// global in its glued / `=`-joined form, which carries its own value and so
// needs no separate value-token consumption: `-Rowner/repo` and `--repo=…`.
func isGhKnownGluedGlobal(a string) bool {
	if strings.HasPrefix(a, "-R") && len(a) > 2 {
		return true
	}
	if strings.HasPrefix(a, "--repo=") {
		return true
	}
	return false
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
