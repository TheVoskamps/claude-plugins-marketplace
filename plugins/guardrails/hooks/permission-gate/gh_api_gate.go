package main

import (
	"strings"
)

// This file implements the `gh api` classification the dangerous-command
// spec's appendix anticipated ("If it later proves hot in the loop, whitelist
// specific allowed forms, or adopt the GET-gate in the appendix"). It replaces
// the blanket graphql-DENY / any-REST-ASK behavior with two classifiers, both
// driven from classifyGhAPI in rules.go:
//
//   - the GraphQL document scanner (Design A): a provably query-only document
//     supplied literally via `-f query=…` / `--raw-field query=…` ALLOWs, as
//     does a fragment-free mutation document whose every top-level field is on
//     the curated issue-metadata allowlist (ghGraphQLMutationAllowlist);
//     any other mutation-bearing document ASKs (naming the mutation fields);
//     everything else (non-literal query source, unbalanced/garbage,
//     subscription) DENYs.
//   - the REST GET-gate (Design B): a known-flag-only GET whose endpoint is on
//     the path-prefix allowlist ALLOWs; an unknown flag or a non-matching
//     endpoint ASKs; a `://`- or `..`-bearing endpoint DENYs.
//
// The issues plugin makes `gh api` (both graphql and REST) hot in the loop, so
// the prior wall (graphql → DENY with no escape hatch; every REST read → ASK,
// which storms prompts and effectively denies in background subagents) is the
// bug this file exists to fix.

// ghAPIRESTFlags is the gh-api flag table (pinned to gh 2.96.0). The value maps
// each recognized flag to whether it consumes a following VALUE token in the
// space-separated form. The glued/`=`-joined forms (`-qfoo`, `--jq=foo`) carry
// their own value and are handled by prefix checks in the walker, not this map.
//
// Pinning the table to the installed gh version is deliberate (Design B): an
// unmodeled future flag lands in the unknown-flag → ASK path rather than being
// silently mis-parsed. `--hostname`, `-H/--header`, `-X/--method`, and the
// body-bearing flags (`-f/-F/--field/--raw-field/--input`) are NOT in this
// table — they are consumed by the dedicated deny/classify tiers in
// classifyGhAPI before the REST gate ever runs, so listing them here would be
// dead weight.
var ghAPIRESTFlags = map[string]bool{
	// value-taking
	"--cache":    true,
	"-q":         true,
	"--jq":       true,
	"-t":         true,
	"--template": true,
	"-p":         true,
	"--preview":  true,
	// bare switches
	"-i":         false,
	"--include":  false,
	"--paginate": false,
	"--silent":   false,
	"--slurp":    false,
	"--verbose":  false,
}

// restEndpointAllowExact is the set of endpoints (after leading-slash and
// query-string stripping) allowed as an exact match. These are the fixed,
// read-only GitHub REST endpoints the issue names (`/issue-create` and
// `/user-config` call `gh api user`).
var restEndpointAllowExact = map[string]bool{
	"rate_limit": true,
	"meta":       true,
	"user":       true,
}

// restEndpointAllowPrefixes is the set of segment-bounded path prefixes allowed
// for a GET. Segment-bounded means the endpoint must be exactly the bare word or
// continue with a `/` — so `repos/` matches `repos/o/r/issues` but a hypothetical
// `reposecret` does not. These cover the issues plugin's REST reads and the
// common GitHub read surface.
var restEndpointAllowPrefixes = []string{
	"repos/",
	"orgs/",
	"users/",
	"search/",
}

// classifyGhAPIREST is the Design B REST GET-gate. It runs only after
// classifyGhAPI has ruled out every write signal (explicit non-GET method,
// implicit-POST body flag, method-override header, `--hostname`) and confirmed
// the endpoint is not `graphql`. endpoint is the positional endpoint token (may
// be empty if none was found); restArgs is the argv slice after `api` (still
// carrying the endpoint and any flags) used to scan for unknown flags.
//
// Precedence:
//  1. endpoint containing `://` (full-URL prefix-match bypass) or `..`
//     (server-side path traversal) → DENY (appendix step 7).
//  2. any flag not in ghAPIRESTFlags (and not one already handled upstream) →
//     ASK (Deviation 1: a false ask costs one click; a hard deny on every future
//     gh flag is the no-escape-hatch failure this gate exists to remove).
//  3. endpoint on the path-prefix allowlist → ALLOW.
//  4. otherwise → ASK (Deviation 2: preserve today's human escape hatch rather
//     than getting stricter).
func classifyGhAPIREST(endpoint string, restArgs []string) Decision {
	// Step 1: full-URL / traversal endpoints deny (before any allow can fire).
	if endpoint != "" {
		if strings.Contains(endpoint, "://") {
			return classifyghAPIDeny(
				"Blocked: 'gh api' with a full-URL endpoint (containing '://') bypasses the path-prefix allowlist " +
					"and can aim the signed request at an arbitrary host. Use a bare API path (e.g. 'repos/o/r'), not a URL.")
		}
		if strings.Contains(endpoint, "..") {
			return classifyghAPIDeny(
				"Blocked: 'gh api' endpoint contains '..' (server-side path traversal). Denied. Use an explicit API " +
					"path with no '..' segments.")
		}
	}

	// Step 2: unknown-flag scan. Walk restArgs, skipping the endpoint positional
	// and consuming each known flag's value; any residual flag token that is not
	// in ghAPIRESTFlags is unmodeled → ASK. The body-bearing / method /
	// method-override / hostname flags never reach here (classifyGhAPI consumed
	// or decided on them upstream), but we still skip their value tokens so a
	// value like `-q .login` is not misread as an unknown flag.
	if unknown, ok := ghAPIRESTUnknownFlag(restArgs); ok {
		return ask("gh api unknown-flag (#113)",
			"'gh api "+unknown+"' carries a flag the permission gate does not model for the installed gh version. "+
				"Confirm the command is intended; it parses as a read (GET) but the gate cannot fully classify the flag.")
	}

	// Step 3: path-prefix allowlist → ALLOW.
	if endpoint != "" && restEndpointAllowed(endpoint) {
		return allow("gh api " + endpoint + " is an allow-listed read (GET) endpoint")
	}

	// Step 4: non-matching endpoint (or no endpoint at all) → ASK (Deviation 2).
	return ask("gh api (#113)",
		"'gh api' can perform reads and writes against the GitHub API. This form parses as a read (GET) but its "+
			"endpoint is not on the allow-listed read surface; confirm it is intended.")
}

// restEndpointAllowed reports whether a REST endpoint is on the GET allowlist.
// It strips a single leading '/' and any '?query' suffix before matching, so an
// inline query string (`repos/o/r/issues?state=open`) and a leading-slash form
// (`/user`) both match. gh path placeholders (`{owner}`, `:repo`) are inert —
// they are not '/', '?', '://', or '..', so they neither help nor break the
// segment-bounded match.
func restEndpointAllowed(endpoint string) bool {
	e := strings.TrimPrefix(endpoint, "/")
	if q := strings.IndexByte(e, '?'); q >= 0 {
		e = e[:q]
	}
	if restEndpointAllowExact[e] {
		return true
	}
	for _, p := range restEndpointAllowPrefixes {
		// Segment-bounded: exactly the bare word (prefix without its trailing '/')
		// or the word followed by '/…'. `repos/` matches `repos` and `repos/o/r`.
		bare := strings.TrimSuffix(p, "/")
		if e == bare || strings.HasPrefix(e, p) {
			return true
		}
	}
	return false
}

// ghAPIRESTUnknownFlag walks the argv after `api` and returns the first flag
// token that is neither a known gh-api flag (ghAPIRESTFlags) nor one of the
// flags classifyGhAPI already handled upstream (method, body-bearing, header,
// hostname). It consumes value tokens of known value-taking flags so a value
// like `.login` after `-q` is never mistaken for an endpoint or an unknown flag.
// Returns ("", false) when every flag is recognized.
//
// The upstream-handled flags are included in the "known" set here so that, e.g.,
// a `-q .login` (jq query) whose value happens to start with '-' does not desync
// the scan. The body/method/header/hostname flags cannot reach the ALLOW path
// (classifyGhAPI decides on them first), but their VALUE tokens must still be
// consumed so the walk stays in sync.
func ghAPIRESTUnknownFlag(args []string) (string, bool) {
	seenAPI := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !seenAPI {
			if a == "api" {
				seenAPI = true
			}
			continue
		}
		if !strings.HasPrefix(a, "-") {
			continue // a positional (the endpoint or a known flag's already-consumed value)
		}
		// Split a `=`-joined flag (`--jq=.login`) into its name for lookup; the
		// value rides with the token so nothing extra is consumed.
		name := a
		glued := false
		if eq := strings.IndexByte(a, '='); eq >= 0 {
			name = a[:eq]
			glued = true
		}
		// Upstream-handled value-taking flags: consume the value, never unknown.
		switch name {
		case "-X", "--method", "-H", "--header", "-f", "-F", "--field",
			"--raw-field", "--input", "--hostname":
			if !glued && !isGluedShortFlag(a) && i+1 < len(args) {
				i++ // consume the separate value token
			}
			continue
		}
		// Glued short forms of upstream/known value flags (`-qfoo`, `-Xfoo`, `-ffoo`).
		if isGluedShortFlag(a) {
			continue
		}
		if takesValue, ok := ghAPIRESTFlags[name]; ok {
			if takesValue && !glued && i+1 < len(args) {
				i++ // consume the separate value token
			}
			continue
		}
		// Unrecognized flag → surface it (ASK, Deviation 1).
		return a, true
	}
	return "", false
}

// isGluedShortFlag reports whether a token is a single-dash short flag carrying
// a glued value (`-qfoo`, `-Xfoo`, `-ffoo`, `-tfoo`, `-pfoo`) for one of gh
// api's value-taking short flags. Such a token carries its own value and
// consumes no following token. The bare `-i` (include) is a switch, not a
// value flag, so `-ifoo` is NOT a glued value form and is left to the
// unknown-flag path.
func isGluedShortFlag(a string) bool {
	if len(a) <= 2 || a[0] != '-' || a[1] == '-' {
		return false
	}
	switch a[1] {
	case 'q', 't', 'p', 'X', 'H', 'f', 'F':
		return true
	}
	return false
}

// graphqlQueryDoc extracts the GraphQL document from a `gh api graphql`
// invocation ONLY when it is supplied as a literal `-f query=…` /
// `--raw-field query=…` value. These two flags pass the value verbatim (no
// `@file` expansion, no type coercion), so the argv carries the full document
// and it can be scanned. `-F query=…` / `--field query=…` (which does `@<path>`
// expansion and coercion), `--input`, or no statically present query are NOT
// extractable — classifyGhAPI DENYs those as genuinely unclassifiable before
// calling here.
//
// It scans ALL tokens after `api` (not just the first `-f`/`--raw-field`
// match) and collects every literal `query=…` value found, in any spaced or
// glued form. Returns (doc, true) only when EXACTLY ONE such value is present;
// ("", false) — the DENY path, same as "no query field at all" — when zero or
// more than one is found.
//
// The more-than-one case is review hardening, not a live `gh` exploit:
// verified live (not observable from inside this sandbox), the installed gh
// REJECTS a duplicate `-f query=…` outright with "unexpected override
// existing field under \"query\"", before assembling any request — so
// `-f query='query{…}' -f query='mutation{…}'` never reaches the GitHub API
// today. But that rejection is gh's undocumented behavior, not a contract the
// gate should pin its security boundary to; a future gh version could accept
// the last (or first) occurrence and silently execute the other. Failing
// closed on any duplicate costs legitimate callers nothing — no sanctioned
// template passes `query=` twice — and keeps the gate's classification
// correct regardless of which `query=` gh itself would honor.
//
// args is the argv after the program (still carrying `api graphql`).
func graphqlQueryDoc(args []string) (string, bool) {
	seenAPI := false
	var docs []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !seenAPI {
			if a == "api" {
				seenAPI = true
			}
			continue
		}
		// Spaced form: `-f query=…` / `--raw-field query=…`.
		if a == "-f" || a == "--raw-field" {
			if i+1 < len(args) {
				if v, ok := stripQueryPrefix(args[i+1]); ok {
					docs = append(docs, v)
				}
				i++ // consume the value even when it is not the query field
			}
			continue
		}
		// Glued forms: `-fquery=…` / `--raw-field=query=…`.
		if strings.HasPrefix(a, "-f") && len(a) > 2 {
			if v, ok := stripQueryPrefix(strings.TrimPrefix(a, "-f")); ok {
				docs = append(docs, v)
			}
			continue
		}
		if strings.HasPrefix(a, "--raw-field=") {
			if v, ok := stripQueryPrefix(strings.TrimPrefix(a, "--raw-field=")); ok {
				docs = append(docs, v)
			}
			continue
		}
	}
	if len(docs) != 1 {
		return "", false
	}
	return docs[0], true
}

// stripQueryPrefix returns the value of a `query=<doc>` field token, or
// ("", false) if the token is not the query field. The GraphQL document is
// everything after the first '='.
func stripQueryPrefix(kv string) (string, bool) {
	const key = "query="
	if strings.HasPrefix(kv, key) {
		return kv[len(key):], true
	}
	return "", false
}

// graphqlDocResult is the outcome of scanning a GraphQL document.
type graphqlDocResult struct {
	// queryOnly is true iff every top-level operation is provably a query
	// (explicit `query`, the anonymous `{…}` shorthand, or a `fragment`
	// definition) and the document is well-formed enough to prove it.
	queryOnly bool
	// mutationFields holds the top-level selection-set field names of any
	// `mutation` operation found, in source order (for the ASK reason). Non-nil
	// and non-empty only when a mutation operation was found.
	mutationFields []string
	// sawSubscription is true when a top-level `subscription` operation was
	// found. It is tracked separately from queryOnly because the mutation
	// allowlist may only fire on a document whose every non-query
	// operation is a mutation: a subscription names no allow-listable field, so
	// a document bundling one with an allow-listed mutation must keep its
	// un-narrowed verdict rather than riding the mutation's allowlist entry.
	sawSubscription bool
	// sawFragment is true when the document carries ANY fragment indirection: a
	// `...` spread token (fragment spread or inline fragment) anywhere in the
	// document, or a top-level `fragment` definition.
	//
	// It exists because mutationFields is NOT a faithful list of the root fields
	// GitHub will execute once fragments are in play: topLevelSelectionFields
	// names the identifier that FOLLOWS a `...`, and walkGraphQLTopLevel
	// discards fragment-definition bodies entirely. So
	// `mutation { ...addSubIssue } fragment addSubIssue on Mutation {
	// deleteIssue(…) }` reports the field `addSubIssue` while GitHub executes
	// `deleteIssue` (`__schema { mutationType { name } }` is literally
	// `Mutation`, so `on Mutation` is a valid type condition and the shape does
	// execute). That mislabel was harmless while EVERY mutation ASKed; the
	// allowlist turns some mutations into an ALLOW, which would make the
	// mislabel a laundering bypass. A fragment-bearing mutation document
	// therefore may not ride the allowlist and keeps its un-narrowed ASK.
	//
	// The signal deliberately does not gate the query-only ALLOW: a
	// query-only document executes against the Query root type, so no fragment
	// it spreads can reach a mutation field.
	sawFragment bool
}

// scanGraphQLDoc conservatively classifies a GraphQL document extracted from
// argv. It strips string literals (`"""…"""` and `"…"`) and `#` comments, then
// walks the remaining top-level constructs. The document is queryOnly iff every
// top-level construct is a `query` operation, an anonymous `{…}` selection set
// (the GraphQL-spec shorthand, which is a query), or a `fragment` definition.
// Anything else — a `mutation` or `subscription` operation, unrecognized
// residue, or unbalanced braces — fails closed (queryOnly=false).
//
// When a `mutation` operation is present, its top-level selection-set field
// names are collected so the ASK reason can name them (e.g. `addSubIssue`) and
// so the allowlist can judge them. Because those names are only as
// faithful as the document is fragment-free, any fragment indirection in the
// document also sets sawFragment (see that field, and
// graphqlDocHasFragmentSpread below).
//
// Failing closed is the security-critical direction: the GraphQL spec requires
// the `mutation` keyword at top level to write, and a defaulted/anonymous
// operation is a query (the safe direction), so a document that does not
// PROVABLY read stays out of the ALLOW path.
func scanGraphQLDoc(doc string) graphqlDocResult {
	stripped, ok := stripGraphQLStringsAndComments(doc)
	if !ok {
		return graphqlDocResult{} // unterminated string / block → fail closed
	}
	res := walkGraphQLTopLevel(stripped)
	// A spread can sit at any depth, inside any operation, so it is detected
	// document-wide rather than by the top-level walk (which sets sawFragment
	// for a `fragment` DEFINITION). Detecting it here also covers the shapes the
	// walk fails closed on, which is harmless: those already DENY.
	if graphqlDocHasFragmentSpread(stripped) {
		res.sawFragment = true
	}
	return res
}

// graphqlDocHasFragmentSpread reports whether a string-and-comment-stripped
// GraphQL document contains a `...` spread token — the sole syntax for both a
// named fragment spread (`...Name`) and an inline fragment (`... on Type {…}`).
// GraphQL spells the token as exactly three consecutive dots (it is a single
// punctuator, so `. . .` is not a spread), which makes the substring test both
// sufficient and exact.
//
// Callers use this only to REFUSE an ALLOW, so the one direction that could
// matter — a false positive on a `...` that is not a spread — costs at most an
// unnecessary ASK.
func graphqlDocHasFragmentSpread(stripped string) bool {
	return strings.Contains(stripped, "...")
}

// ghGraphQLMutationAllowlist is the curated set of top-level GraphQL mutation
// FIELD names whose document ALLOWs. The issues plugin's hot loop is
// mutation-heavy — a single `/issue-create` or triage pass costs several
// prompts under the plain "any mutation → ASK" rule — for operations
// that are that plugin's sanctioned job.
//
// The principled basis is the GraphQL spelling of the verbs classifyGh already
// ALLOWs as enumerated recoverable writes (ghRecoverableWriteVerbs), plus the
// issues plugin's issue-metadata verbs: field/project/type/relationship sets
// and close/reopen. `closeIssue`/`reopenIssue` mirror `gh issue close` /
// `gh issue reopen`, which are already recoverable-write verbs.
//
// Each field-set verb is paired with its clear verb, because unsetting a value
// is the same write on the same surface as setting it:
// `deleteIssueFieldValue` clears one native issue field (the direct spelling of
// the `delete: Boolean` that `setIssueFieldValue`'s own input already carries),
// and `clearProjectV2ItemFieldValue` clears one project-board item field (the
// only way to do it — `updateProjectV2ItemFieldValue` demands a concrete value
// and cannot clear). A clear is recoverable exactly as its set counterpart is,
// since the value can simply be set again, so neither adds exposure the set
// verb has not already accepted.
//
// Recorded trade-off: these mutations address opaque node IDs, so — unlike the
// `-R`/`--repo` foreign-target check — the gate cannot see which repo the
// target belongs to. Accepted because the writes are recoverable, land on
// human-visible surfaces (issue threads, project boards), and require write
// access the credential already holds. Later configuration work makes this
// list repo-extendable via `repo-can-extend`.
//
// GraphQL names are case-sensitive, so lookups are exact-match by design.
var ghGraphQLMutationAllowlist = map[string]bool{
	"setIssueFieldValue":            true,
	"deleteIssueFieldValue":         true,
	"updateProjectV2ItemFieldValue": true,
	"clearProjectV2ItemFieldValue":  true,
	"addProjectV2ItemById":          true,
	"updateIssueIssueType":          true,
	"addSubIssue":                   true,
	"removeSubIssue":                true,
	"addBlockedBy":                  true,
	"removeBlockedBy":               true,
	"closeIssue":                    true,
	"reopenIssue":                   true,
}

// allGraphQLMutationFieldsAllowed reports whether EVERY named top-level
// mutation selection field is on ghGraphQLMutationAllowlist. Aliases
// already resolve to the real field name in topLevelSelectionFields, so an
// aliased multi-operation document is judged on the fields it actually calls.
//
// All fields must pass: a document bundling an allow-listed field with
// anything else still ASKs, because a multi-operation document is judged by
// its broadest operation. An empty list is NOT "all allowed" — it means no
// mutation field was nameable, which is the fail-closed DENY path, not an
// allowlist hit.
//
// This function judges only the names it is handed; it cannot tell whether
// those names are the fields GitHub will actually execute. Callers MUST first
// reject a document whose graphqlDocResult reports sawFragment or
// sawSubscription — the names are trustworthy only for a fragment-free
// mutation document.
func allGraphQLMutationFieldsAllowed(fields []string) bool {
	if len(fields) == 0 {
		return false
	}
	for _, f := range fields {
		if !ghGraphQLMutationAllowlist[f] {
			return false
		}
	}
	return true
}

// stripGraphQLStringsAndComments removes string literals and `#` comments from a
// GraphQL document, replacing each with a single space so token boundaries are
// preserved (so `query"x"{…}` does not weld into one token). It handles block
// strings (`"""…"""`), ordinary strings (`"…"` with `\"` escapes), and `#`
// line comments. Returns (stripped, false) if a string is left unterminated (a
// malformed document → the caller fails closed).
func stripGraphQLStringsAndComments(doc string) (string, bool) {
	var b strings.Builder
	i := 0
	n := len(doc)
	for i < n {
		c := doc[i]
		switch {
		case c == '#':
			// Line comment: skip to end of line.
			for i < n && doc[i] != '\n' {
				i++
			}
		case strings.HasPrefix(doc[i:], `"""`):
			// Block string: skip to the closing `"""`.
			i += 3
			closed := false
			for i < n {
				if strings.HasPrefix(doc[i:], `"""`) {
					i += 3
					closed = true
					break
				}
				i++
			}
			if !closed {
				return "", false
			}
			b.WriteByte(' ')
		case c == '"':
			// Ordinary string: skip to the unescaped closing quote.
			i++
			closed := false
			for i < n {
				if doc[i] == '\\' && i+1 < n {
					i += 2
					continue
				}
				if doc[i] == '"' {
					i++
					closed = true
					break
				}
				if doc[i] == '\n' {
					// A newline inside a non-block string is malformed GraphQL.
					return "", false
				}
				i++
			}
			if !closed {
				return "", false
			}
			b.WriteByte(' ')
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String(), true
}

// walkGraphQLTopLevel walks a string-and-comment-stripped GraphQL document at
// brace depth 0 and classifies every top-level construct. It requires each
// top-level construct to be one of: an anonymous `{…}` selection set (query
// shorthand), an explicit `query …{…}` operation, or a `fragment …{…}`
// definition. A `mutation …{…}` operation is recorded (its top-level fields
// collected) but flips queryOnly to false. Anything else — a `subscription`,
// an unrecognized leading keyword, or unbalanced braces — also fails closed.
//
// Fragment-definition bodies are discarded rather than resolved into the
// operations that spread them, so a `fragment` sets sawFragment; scanGraphQLDoc
// sets the same field for the `...` spread token itself.
func walkGraphQLTopLevel(doc string) graphqlDocResult {
	res := graphqlDocResult{queryOnly: true}
	i := 0
	n := len(doc)
	sawOperation := false
	for i < n {
		// Skip whitespace and commas (insignificant in GraphQL) between
		// top-level constructs.
		for i < n && (isGraphQLSpace(doc[i]) || doc[i] == ',') {
			i++
		}
		if i >= n {
			break
		}
		sawOperation = true
		if doc[i] == '{' {
			// Anonymous selection set → query shorthand.
			body, next, ok := extractBracedBlock(doc, i)
			if !ok {
				return graphqlDocResult{} // unbalanced → fail closed
			}
			_ = body
			i = next
			continue
		}
		// A keyword-led construct: read the leading identifier.
		kw, after := readGraphQLIdentifier(doc, i)
		if kw == "" {
			return graphqlDocResult{} // unrecognized residue → fail closed
		}
		switch kw {
		case "query", "mutation", "subscription":
			// Operation. Advance past an optional name and an optional
			// variable-definitions `(...)` list (which may itself contain `{...}`
			// / `[...]` default values, e.g. `($x: Input = {a: 1})`) to reach the
			// operation's own selection set '{'.
			braceIdx := selectionSetBraceIndex(doc, after)
			if braceIdx < 0 {
				return graphqlDocResult{} // operation without a body → fail closed
			}
			body, next, ok := extractBracedBlock(doc, braceIdx)
			if !ok {
				return graphqlDocResult{}
			}
			if kw == "subscription" {
				res.queryOnly = false
				res.sawSubscription = true
			}
			if kw == "mutation" {
				res.queryOnly = false
				res.mutationFields = append(res.mutationFields, topLevelSelectionFields(body)...)
			}
			i = next
		case "fragment":
			// Fragment definition: `fragment Name on Type Directives? {…}`.
			// Directives can themselves carry `(...)` arguments with default-value
			// braces (`@dir(x: {a: 1})`), so use the same paren-aware skip.
			//
			// The body is deliberately DISCARDED — a definition executes nothing on
			// its own — but that is exactly why it must be recorded: whatever it
			// defines reaches the wire through a spread this walk cannot resolve,
			// so a document containing one may not reach the mutation ALLOW.
			res.sawFragment = true
			braceIdx := selectionSetBraceIndex(doc, after)
			if braceIdx < 0 {
				return graphqlDocResult{}
			}
			_, next, ok := extractBracedBlock(doc, braceIdx)
			if !ok {
				return graphqlDocResult{}
			}
			i = next
		default:
			// Unrecognized top-level keyword (e.g. a type-system definition, or
			// garbage) → fail closed.
			return graphqlDocResult{}
		}
	}
	if !sawOperation {
		// An empty (or all-whitespace) document proves nothing → fail closed.
		return graphqlDocResult{}
	}
	return res
}

// selectionSetBraceIndex returns the index of the '{' that opens an
// operation's or fragment definition's own selection set, scanning forward
// from start (just past the `query`/`mutation`/`subscription`/`fragment`
// keyword). Returns -1 if no such brace is found.
//
// Unlike a naive "find the next '{'", this skips over any `(...)` region
// encountered before that brace — an operation's variable-definitions list
// (`($x: Input = {a: 1})`) or a fragment's directive arguments
// (`@dir(x: {a: 1})`) — because GraphQL default values can themselves contain
// `{...}` object literals and `[...]` list literals. A brace inside such a
// region belongs to a default value, not the selection set, and must not be
// mistaken for one (which would desync the walk: extractBracedBlock would
// then treat the default-value object as the operation's entire body, and any
// mutation fields after the real selection-set brace would go unscanned —
// silently mis-classifying a mutation as a query. Skipping to the CORRECT
// brace, not just refusing to allow, is what closes that gap).
//
// This is a flat scan, not a doc-wide brace-depth walk: it tracks only
// parenthesis depth (`(`/`)`) so it can step over one or more `(...)` regions
// (variable defs, then directives, each independently parenthesized) without
// being confused by the `{`/`[` default-value delimiters nested inside them.
// Strings and comments are already stripped by the caller, so a stray paren
// cannot appear inside a literal here. GraphQL argument/variable-definition
// lists never nest `(` within `(` at the top level scanned here (nested calls
// are not part of the grammar), so a simple depth counter is sufficient; any
// unbalanced parenthesis simply runs to the end of the document and the
// function returns -1, which the caller already treats as fail-closed.
func selectionSetBraceIndex(doc string, start int) int {
	i := start
	n := len(doc)
	parenDepth := 0
	for i < n {
		c := doc[i]
		switch {
		case c == '(':
			parenDepth++
		case c == ')':
			if parenDepth > 0 {
				parenDepth--
			}
		case c == '{' && parenDepth == 0:
			return i
		}
		i++
	}
	return -1
}

// extractBracedBlock returns the contents of a `{…}` block starting at the '{'
// at index open, the index just past the matching '}', and ok=false if the
// braces are unbalanced. Strings/comments are already stripped, so brace
// matching is a plain depth count.
func extractBracedBlock(doc string, open int) (body string, next int, ok bool) {
	if open >= len(doc) || doc[open] != '{' {
		return "", open, false
	}
	depth := 0
	for i := open; i < len(doc); i++ {
		switch doc[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return doc[open+1 : i], i + 1, true
			}
		}
	}
	return "", open, false // unbalanced
}

// topLevelSelectionFields returns the field names at the top level of a
// selection-set body (the content between the outer braces), skipping nested
// braces, arguments (…), and directives. It names the mutation fields in the
// ASK reason (e.g. `addSubIssue`) and feeds the allowlist decision. A
// field is an identifier at brace depth 0 of the body; an alias
// (`alias: field`) resolves to the field name after the ':'.
//
// LOSSY, and load-bearing for that allowlist — read this before trusting its output:
// it is a token scanner, not a resolver. It reports the identifiers PRESENT in
// the body, which equal the root fields GitHub executes only when the body is
// fragment-free. Given `...addSubIssue` it reports `addSubIssue` — the fragment
// NAME, not the fields that fragment's definition selects; given `... on
// Mutation {…}` it reports `on` and `Mutation`. Anything deciding an ALLOW from
// this list must therefore also require graphqlDocResult.sawFragment to be
// false. Any future indirection added to GraphQL's grammar needs the same
// treatment: a new signal on graphqlDocResult, not a new special case here.
func topLevelSelectionFields(body string) []string {
	var fields []string
	i := 0
	n := len(body)
	depth := 0
	parenDepth := 0
	for i < n {
		c := body[i]
		switch {
		case c == '(':
			parenDepth++
			i++
		case c == ')':
			if parenDepth > 0 {
				parenDepth--
			}
			i++
		case c == '{':
			depth++
			i++
		case c == '}':
			if depth > 0 {
				depth--
			}
			i++
		case depth == 0 && parenDepth == 0 && (isGraphQLNameStart(c)):
			id, after := readGraphQLIdentifier(body, i)
			i = after
			// Skip whitespace to see whether this is an alias (`id :`).
			j := i
			for j < n && isGraphQLSpace(body[j]) {
				j++
			}
			if j < n && body[j] == ':' {
				// Alias: the real field name is the next identifier.
				j++
				for j < n && isGraphQLSpace(body[j]) {
					j++
				}
				name, after2 := readGraphQLIdentifier(body, j)
				if name != "" {
					fields = append(fields, name)
					i = after2
					continue
				}
			}
			if id != "" {
				fields = append(fields, id)
			}
		default:
			i++
		}
	}
	return fields
}

// readGraphQLIdentifier reads a GraphQL name (/[_A-Za-z][_0-9A-Za-z]*/) starting
// at index start and returns it plus the index just past it. Returns ("", start)
// if there is no name at start.
func readGraphQLIdentifier(doc string, start int) (string, int) {
	if start >= len(doc) || !isGraphQLNameStart(doc[start]) {
		return "", start
	}
	i := start + 1
	for i < len(doc) && isGraphQLNameCont(doc[i]) {
		i++
	}
	return doc[start:i], i
}

func isGraphQLNameStart(c byte) bool {
	return c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

func isGraphQLNameCont(c byte) bool {
	return isGraphQLNameStart(c) || (c >= '0' && c <= '9')
}

func isGraphQLSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}
