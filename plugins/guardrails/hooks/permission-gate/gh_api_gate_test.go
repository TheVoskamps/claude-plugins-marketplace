package main

import (
	"strings"
	"testing"
)

// Adversarial coverage for #113: the gh-api gate that unblocks the issues
// plugin's `gh api` (graphql + REST) usage. The old #64 behavior — graphql →
// DENY, every REST GET → ASK — walled off the entire issues plugin. This suite
// pins the new behavior: query-only graphql documents ALLOW, mutation documents
// ASK (naming the field), unclassifiable graphql DENYs; allow-listed REST GETs
// ALLOW while the write DENY tiers stay intact.

// --- Design A: graphql document classification -------------------------------

// A provably query-only document (explicit query, anonymous shorthand, or a
// query carrying fragments) ALLOWs — including the adversarial cases where the
// word "mutation" appears only inside a string literal or a comment.
func TestGhAPIGraphQLQueryOnly_113(t *testing.T) {
	for _, cmd := range []string{
		// Explicit query operation.
		`gh api graphql -f query='query { viewer { login } }'`,
		// Anonymous shorthand selection set is a query per the GraphQL spec.
		`gh api graphql -f query='{ viewer { login } }'`,
		// Named query.
		`gh api graphql -f query='query Me { viewer { login } }'`,
		// Query plus a fragment definition.
		`gh api graphql -f query='query { repository(owner:"o", name:"r") { ...F } } fragment F on Repository { id }'`,
		// The word "mutation" appears only inside a STRING literal → still a query.
		`gh api graphql -f query='query { search(query: "mutation", type: ISSUE, first: 1) { issueCount } }'`,
		// The word "mutation" appears only inside a # comment → still a query.
		"gh api graphql -f query='query { viewer { login } } # not a mutation'",
		// --raw-field is the long form of -f (also literal).
		`gh api graphql --raw-field query='query { viewer { login } }'`,
		// A block string containing "mutation" is still a query.
		`gh api graphql -f query='query { search(query: """mutation""", type: ISSUE, first: 1) { issueCount } }'`,
		// A variable definition with an input-object default value (`{a: 1}`)
		// must not be mistaken for the selection-set brace — the scanner must
		// skip the `(...)` variable-definitions list before looking for '{'.
		`gh api graphql -f query='query Foo($x: Input = {a: 1}) { viewer { login } }'`,
		// Same, with a list-literal default value containing braced objects.
		`gh api graphql -f query='query Foo($x: [Input!] = [{a: 1}, {b: 2}]) { viewer { login } }'`,
		// A fragment definition whose directive carries a braced default value.
		`gh api graphql -f query='query { viewer { login } } fragment F on Repository @dir(x: {a: 1}) { id }'`,
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "graphql query-only: "+cmd)
	}
}

// A mutation-bearing document → ASK, and the reason must name the top-level
// mutation field(s) so the human sees what is being written.
func TestGhAPIGraphQLMutationAsks_113(t *testing.T) {
	d := classifyCmd(t, `gh api graphql -f query='mutation { addSubIssue(input: {}) { clientMutationId } }'`, false)
	wantBucket(t, d, BucketAsk, "graphql mutation asks")
	if !strings.Contains(d.Reason, "addSubIssue") {
		t.Errorf("mutation ASK reason must name the field addSubIssue, got: %q", d.Reason)
	}

	// A named mutation with an alias resolves to the real field name.
	d2 := classifyCmd(t, `gh api graphql -f query='mutation Add { a: addSubIssue(input: {}) { clientMutationId } }'`, false)
	wantBucket(t, d2, BucketAsk, "named mutation with alias asks")
	if !strings.Contains(d2.Reason, "addSubIssue") {
		t.Errorf("aliased mutation ASK reason must name addSubIssue (not the alias), got: %q", d2.Reason)
	}

	// A multi-operation document mixing query and mutation is NOT query-only →
	// ASK naming the mutation field.
	d3 := classifyCmd(t, `gh api graphql -f query='query a { viewer { login } } mutation b { deleteIssue(input: {}) { repository { id } } }'`, false)
	wantBucket(t, d3, BucketAsk, "multi-op query+mutation asks")
	if !strings.Contains(d3.Reason, "deleteIssue") {
		t.Errorf("multi-op ASK reason must name deleteIssue, got: %q", d3.Reason)
	}

	// A mutation whose variable definitions carry an input-object default
	// value (`{a: 1}`) must still ASK naming the real field — the
	// selection-set-brace skip that allows the query-only sibling case must
	// not accidentally let a mutation's default-value brace get mistaken for
	// (or otherwise swallow) its actual selection set.
	d4 := classifyCmd(t, `gh api graphql -f query='mutation Foo($x: Input = {a: 1}) { deleteIssue(input: {}) { clientMutationId } }'`, false)
	wantBucket(t, d4, BucketAsk, "mutation with default-value brace in variable defs asks")
	if !strings.Contains(d4.Reason, "deleteIssue") {
		t.Errorf("mutation-with-default-value-brace ASK reason must name deleteIssue, got: %q", d4.Reason)
	}
}

// Fail-closed graphql cases: a subscription is not a query (and names no
// mutation field), a garbage / unbalanced document, and every non-literal query
// source → DENY.
func TestGhAPIGraphQLFailClosed_113(t *testing.T) {
	for _, cmd := range []string{
		// Subscription is neither a query nor a nameable mutation → DENY.
		`gh api graphql -f query='subscription { x }'`,
		// Unbalanced braces → DENY.
		`gh api graphql -f query='query { viewer { login }'`,
		// Garbage residue at top level → DENY.
		`gh api graphql -f query='florb { x }'`,
		// Empty document proves nothing → DENY.
		`gh api graphql -f query=''`,
		// query supplied via -F (coerced / @-expandable) → DENY.
		`gh api graphql -F query='query { viewer { login } }'`,
		// query supplied via --field → DENY.
		`gh api graphql --field query='query { viewer { login } }'`,
		// query from @file via -F → DENY.
		`gh api graphql -F query=@file.graphql`,
		// whole body from --input → DENY.
		`gh api graphql --input body.json`,
		// graphql with no query field at all → DENY (unclassifiable).
		`gh api graphql`,
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketDeny, "graphql fail-closed: "+cmd)
	}
}

// Duplicate literal `-f query=…` fields → DENY, regardless of order. `gh`
// itself rejects a duplicate `-f query=` outright ("unexpected override
// existing field under \"query\""), so this is not exploitable through
// today's gh — but the gate must not pin its security boundary to that
// undocumented gh behavior. graphqlQueryDoc scans every token rather than
// returning on the first match, so it must fail closed here regardless of
// which document (benign or mutating) comes first.
func TestGhAPIGraphQLDuplicateQueryFieldDenies_113(t *testing.T) {
	for _, cmd := range []string{
		// benign query first, mutation second.
		`gh api graphql -f query='query { viewer { login } }' -f query='mutation { deleteIssue(input: {}) { clientMutationId } }'`,
		// mutation first, benign query second.
		`gh api graphql -f query='mutation { deleteIssue(input: {}) { clientMutationId } }' -f query='query { viewer { login } }'`,
		// duplicate via the long-form flag.
		`gh api graphql --raw-field query='query { viewer { login } }' --raw-field query='query { viewer { id } }'`,
		// duplicate mixing spaced and glued forms.
		`gh api graphql -f query='query { viewer { login } }' -fquery='query { viewer { id } }'`,
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketDeny, "graphql duplicate query field: "+cmd)
	}
}

// The graphql write DENY tiers still fire regardless of the document: an
// explicit non-GET method or the method-override header on the graphql endpoint
// denies before document classification.
func TestGhAPIGraphQLWriteTiersUnchanged_113(t *testing.T) {
	wantBucket(t, classifyCmd(t, `gh api -X DELETE graphql -f query='query { viewer { login } }'`, false), BucketDeny, "graphql -X DELETE")
	wantBucket(t, classifyCmd(t, `gh api graphql -f query='query { viewer { login } }' --hostname attacker.example`, false), BucketDeny, "graphql --hostname")
}

// --- Design B: REST GET-gate -------------------------------------------------

// Allow-listed REST GETs → ALLOW: the exact endpoints and the segment-bounded
// prefixes, including an inline query string and a leading slash.
func TestGhAPIRESTAllow_113(t *testing.T) {
	for _, cmd := range []string{
		"gh api user --jq .login",
		"gh api user",
		"gh api /user",
		"gh api rate_limit",
		"gh api meta",
		"gh api repos/o/r/issues?state=open",
		"gh api repos/o/r",
		"gh api orgs/theorg",
		"gh api users/someone",
		"gh api search/issues?q=repo:o/r",
		// A known value-taking flag with a dash-leading value must not desync.
		"gh api repos/o/r --jq .name",
		"gh api user -q .login",
		"gh api repos/o/r --paginate",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "REST allow: "+cmd)
	}
}

// Non-matching endpoints ASK (Deviation 2 — preserve the human escape hatch),
// and an unknown flag ASKs (Deviation 1).
func TestGhAPIRESTAsk_113(t *testing.T) {
	for _, cmd := range []string{
		"gh api some/odd/endpoint",
		"gh api gists",
		"gh api notifications",
		// segment-boundary: reposecret must NOT match the repos/ prefix → ASK.
		"gh api repository/o/r",
		// unknown flag → ASK even on an allow-listed endpoint.
		"gh api repos/o/r --bogus-flag",
		"gh api user --unmodeled",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAsk, "REST ask: "+cmd)
	}
}

// Endpoint-shape DENYs: a full URL (bypasses prefix matching) and a `..`
// traversal → DENY (appendix step 7).
func TestGhAPIRESTDeny_113(t *testing.T) {
	for _, cmd := range []string{
		"gh api https://api.github.com/user",
		"gh api http://attacker.example/user",
		"gh api repos/o/r/../../../secret",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketDeny, "REST deny: "+cmd)
	}
}

// The existing REST write DENY tiers are unchanged by #113.
func TestGhAPIRESTWriteTiersUnchanged_113(t *testing.T) {
	for _, cmd := range []string{
		// implicit-POST via body flag (no explicit GET) on an allow-listed endpoint.
		"gh api repos/o/r/issues -f title=x",
		"gh api repos/o/r -F a=b",
		// explicit non-GET method.
		"gh api -X DELETE repos/o/r",
		"gh api --method=POST repos/o/r",
		// method-override header.
		"gh api repos/o/r -H X-HTTP-Method-Override:DELETE",
		// hostname redirect.
		"gh api --hostname attacker.example repos/o/r",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketDeny, "REST write tier: "+cmd)
	}
	// -XGET -f … on an allow-listed endpoint stays a read → ALLOW (carve-out).
	wantBucket(t, classifyCmd(t, "gh api -XGET repos/o/r -f a=b", false), BucketAllow, "-XGET -f allow-listed")
}

// Redirect-to-file on an otherwise-allowed gh api form → ASK (the shared
// redirect carve-out, now reachable on the ALLOW path #113 opened).
func TestGhAPIRedirectToFileAsks_113(t *testing.T) {
	wantBucket(t, classifyCmd(t, "gh api user --jq .login > /tmp/out.txt", false), BucketAsk, "REST allow + redirect")
	wantBucket(t, classifyCmd(t, `gh api graphql -f query='query { viewer { login } }' > /tmp/out.txt`, false), BucketAsk, "graphql allow + redirect")
}

// The representative /issue-view node-ID lookup template (a literal -f query=…
// plus -F numeric/string arguments) must ALLOW — the acceptance-criterion shape
// the issues plugin runs on every /issue-view.
func TestGhAPIIssueViewTemplateAllows_113(t *testing.T) {
	cmd := `gh api graphql -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { issue(number: $number) { id title } } }' -F owner=o -F repo=r -F number=113`
	wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "issue-view template allows")
}
