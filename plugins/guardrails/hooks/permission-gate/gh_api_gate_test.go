package main

import (
	"strings"
	"testing"
)

// Adversarial coverage for the gh-api gate that unblocks the issues
// plugin's `gh api` (graphql + REST) usage. The old behavior — graphql →
// DENY, every REST GET → ASK — walled off the entire issues plugin. This suite
// pins the new behavior: query-only graphql documents ALLOW, mutation documents
// ASK (naming the field), unclassifiable graphql DENYs; allow-listed REST GETs
// ALLOW. The REST/graphql write tiers (non-GET method, implicit-POST
// body flag, method-override header) ASK rather than DENY — a `gh api` REST
// write is a credential-carrying remote mutation the microVM cannot roll back,
// the same class as an `aws` mutation; --hostname keeps its own DENY
// (the one shape the egress proxy's host-allowlist can see and control).
//
// The mutation ASK is narrowed by a curated issue-metadata allowlist:
// a document whose EVERY top-level mutation field is on it ALLOWs (subject to
// the same redirect-to-file ASK), while any other mutation-bearing document
// keeps today's ASK naming the fields.

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
//
// The fields exercised here are deliberately OFF the issue-metadata
// allowlist — an allow-listed field now ALLOWs, and that path is pinned by the
// _195 tests below. This test owns the residual "any other mutation" ASK.
func TestGhAPIGraphQLMutationAsks_113(t *testing.T) {
	d := classifyCmd(t, `gh api graphql -f query='mutation { deleteIssue(input: {}) { clientMutationId } }'`, false)
	wantBucket(t, d, BucketAsk, "graphql mutation asks")
	if !strings.Contains(d.Reason, "deleteIssue") {
		t.Errorf("mutation ASK reason must name the field deleteIssue, got: %q", d.Reason)
	}

	// A named mutation with an alias resolves to the real field name.
	d2 := classifyCmd(t, `gh api graphql -f query='mutation Del { a: deleteIssue(input: {}) { clientMutationId } }'`, false)
	wantBucket(t, d2, BucketAsk, "named mutation with alias asks")
	if !strings.Contains(d2.Reason, "deleteIssue") {
		t.Errorf("aliased mutation ASK reason must name deleteIssue (not the alias), got: %q", d2.Reason)
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

// --- the curated issue-metadata mutation allowlist ---------------------------

// A mutation document whose every top-level field is on the curated allowlist
// ALLOWs — the issues plugin's sanctioned metadata writes, which cost 2–5
// prompts per triage pass under the plain "any mutation → ASK" rule.
func TestGhAPIGraphQLAllowlistedMutationAllows_195(t *testing.T) {
	for _, cmd := range []string{
		// Every allow-listed field, one document each (the enumerated list).
		`gh api graphql -f query='mutation { setIssueFieldValue(input: {}) { issue { id } } }'`,
		`gh api graphql -f query='mutation { updateProjectV2ItemFieldValue(input: {}) { projectV2Item { id } } }'`,
		`gh api graphql -f query='mutation { addProjectV2ItemById(input: {}) { item { id } } }'`,
		`gh api graphql -f query='mutation { updateIssueIssueType(input: {}) { issue { id } } }'`,
		`gh api graphql -f query='mutation { addSubIssue(input: {}) { issue { id } } }'`,
		`gh api graphql -f query='mutation { removeSubIssue(input: {}) { issue { id } } }'`,
		`gh api graphql -f query='mutation { addBlockedBy(input: {}) { issue { id } } }'`,
		`gh api graphql -f query='mutation { removeBlockedBy(input: {}) { issue { id } } }'`,
		`gh api graphql -f query='mutation { closeIssue(input: {}) { issue { id } } }'`,
		`gh api graphql -f query='mutation { reopenIssue(input: {}) { issue { id } } }'`,
		// Named mutation with variable definitions — the shape the issues
		// plugin's own templates emit.
		`gh api graphql -f query='mutation($issueId: ID!, $fieldId: ID!, $optionId: ID!) { setIssueFieldValue(input: { issueId: $issueId, issueFields: [{ fieldId: $fieldId, singleSelectOptionId: $optionId }] }) { issue { id number } } }'`,
		// Multi-operation document: every operation's fields are allow-listed.
		`gh api graphql -f query='mutation a { addSubIssue(input: {}) { issue { id } } } mutation b { addBlockedBy(input: {}) { issue { id } } }'`,
		// A query operation alongside an allow-listed mutation.
		`gh api graphql -f query='query q { viewer { login } } mutation m { closeIssue(input: {}) { issue { id } } }'`,
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "graphql allow-listed mutation: "+cmd)
	}
}

// Aliases resolve to the real field name before the allowlist check, so a
// multi-aliased document calling one allow-listed field N times ALLOWs — the
// batched `/issue-create` metadata write observed in live sessions.
func TestGhAPIGraphQLAliasedAllowlistedMutationAllows_195(t *testing.T) {
	for _, cmd := range []string{
		`gh api graphql -f query='mutation { a: setIssueFieldValue(input: {}) { issue { id } } }'`,
		`gh api graphql -f query='mutation Batch($i: ID!) { p: setIssueFieldValue(input: {}) { issue { id } } s: setIssueFieldValue(input: {}) { issue { id } } }'`,
		// Aliases across two operations, mixing two allow-listed fields.
		`gh api graphql -f query='mutation one { x: addSubIssue(input: {}) { issue { id } } } mutation two { y: updateIssueIssueType(input: {}) { issue { id } } }'`,
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "graphql aliased allow-listed mutation: "+cmd)
	}
}

// All fields must pass: a document bundling an allow-listed field with a
// non-allow-listed one still ASKs, and the reason names the fields so the human
// sees what is being written. A multi-operation document is judged by its
// broadest operation.
func TestGhAPIGraphQLMixedMutationAsks_195(t *testing.T) {
	for _, tc := range []struct {
		cmd  string
		want []string
	}{
		// Two fields in one selection set, one of them off-list.
		{
			`gh api graphql -f query='mutation { addSubIssue(input: {}) { issue { id } } deleteIssue(input: {}) { repository { id } } }'`,
			[]string{"addSubIssue", "deleteIssue"},
		},
		// Two operations, the second off-list.
		{
			`gh api graphql -f query='mutation a { closeIssue(input: {}) { issue { id } } } mutation b { deleteProjectV2Item(input: {}) { deletedItemId } }'`,
			[]string{"closeIssue", "deleteProjectV2Item"},
		},
		// The off-list field hides behind an alias that IS an allow-listed name.
		{
			`gh api graphql -f query='mutation { closeIssue: deleteIssue(input: {}) { repository { id } } }'`,
			[]string{"deleteIssue"},
		},
		// A subscription bundled with an allow-listed mutation rides no
		// allowlist entry — it keeps the un-narrowed ASK verdict.
		{
			`gh api graphql -f query='subscription s { x } mutation m { addSubIssue(input: {}) { issue { id } } }'`,
			[]string{"addSubIssue"},
		},
	} {
		d := classifyCmd(t, tc.cmd, false)
		wantBucket(t, d, BucketAsk, "graphql mixed mutation: "+tc.cmd)
		for _, f := range tc.want {
			if !strings.Contains(d.Reason, f) {
				t.Errorf("mixed-mutation ASK reason must name %q, got: %q", f, d.Reason)
			}
		}
	}
}

// The redirect-to-file carve-out stays AHEAD of the new ALLOW: an allow-listed
// mutation whose stdout/stderr lands in a real file still ASKs.
func TestGhAPIGraphQLAllowlistedMutationRedirectAsks_195(t *testing.T) {
	for _, cmd := range []string{
		`gh api graphql -f query='mutation { addSubIssue(input: {}) { issue { id } } }' > /tmp/out.txt`,
		`gh api graphql -f query='mutation { closeIssue(input: {}) { issue { id } } }' 2> /tmp/err.txt`,
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAsk, "allow-listed mutation + redirect: "+cmd)
	}
}

// Variables passed via separate `-f`/`-F name=value` fields do not affect
// classification: the document under judgement is still the literal
// `-f query=…` value, and a non-query `-f` field is neither a second document
// nor a mutation field.
func TestGhAPIGraphQLAllowlistedMutationWithVariables_195(t *testing.T) {
	for _, cmd := range []string{
		`gh api graphql -f query='mutation($parentId: ID!, $childId: ID!) { addSubIssue(input: { issueId: $parentId, subIssueId: $childId }) { issue { id } } }' -f parentId=I_abc -f childId=I_def`,
		`gh api graphql -f query='mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: Float!) { updateProjectV2ItemFieldValue(input: { projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: { number: $value } }) { projectV2Item { id } } }' -F value=3`,
		// A `-F` field whose value is NOT the query keeps the document literal.
		`gh api graphql -f query='mutation { closeIssue(input: {}) { issue { id } } }' -F number=195`,
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "allow-listed mutation + variables: "+cmd)
	}
}

// Fragment indirection may never reach the allowlist ALLOW. topLevelSelectionFields
// names the identifier that FOLLOWS a `...`, and the top-level walk discards
// fragment-definition bodies, so a spread NAMED after an allow-listed mutation
// would otherwise launder an arbitrary one: GitHub's mutation root type is
// literally `Mutation`, so `fragment addSubIssue on Mutation { deleteIssue(…) }`
// is a valid type condition that executes. Any fragment-bearing mutation
// document therefore keeps the un-narrowed ASK.
func TestGhAPIGraphQLFragmentBearingMutationAsks_195(t *testing.T) {
	for _, cmd := range []string{
		// The exploit: a spread named after an allow-listed field, whose
		// definition calls an off-list one. Spread first...
		`gh api graphql -f query='mutation { ...addSubIssue } fragment addSubIssue on Mutation { deleteIssue(input: {issueId: "I_x"}) { repository { id } } }'`,
		// ...and fragment definition first (the walk is order-independent).
		`gh api graphql -f query='fragment closeIssue on Mutation { deleteProjectV2(input: {projectId: "PVT_x"}) { clientMutationId } } mutation { ...closeIssue }'`,
		// A named operation and variable definitions do not change it.
		`gh api graphql -f query='mutation Meta($id: ID!) { ...setIssueFieldValue } fragment setIssueFieldValue on Mutation { deleteIssue(input: {issueId: $id}) { repository { id } } }'`,
		// A genuine allow-listed field bundled with a laundering spread: the
		// whole document is judged by its least provable part.
		`gh api graphql -f query='mutation { closeIssue(input: {}) { issue { id } } ...reopenIssue } fragment reopenIssue on Mutation { deleteIssue(input: {}) { repository { id } } }'`,
		// An inline fragment at the mutation root hides its fields from the
		// scanner the same way.
		`gh api graphql -f query='mutation { ... on Mutation { deleteIssue(input: {}) { repository { id } } } }'`,
		// Conservative by design: even a benign fragment in an allow-listed
		// mutation's PAYLOAD selection withholds the ALLOW. The gate does not
		// resolve fragments, so it cannot tell this one from the exploits above;
		// falling back to the un-narrowed ASK is the safe direction.
		`gh api graphql -f query='mutation { addSubIssue(input: {}) { issue { ...F } } } fragment F on Issue { id }'`,
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAsk, "graphql fragment-bearing mutation: "+cmd)
	}
}

// The sibling name-laundering shape, pinned so it cannot regress alongside the
// fragment fix: an OPERATION named after an allow-listed field proves nothing
// about the fields it selects, and the walk must judge the selection set.
func TestGhAPIGraphQLAllowlistedOperationNameAsks_195(t *testing.T) {
	d := classifyCmd(t, `gh api graphql -f query='mutation addSubIssue { deleteIssue(input: {}) { repository { id } } }'`, false)
	wantBucket(t, d, BucketAsk, "operation named after an allow-listed field asks")
	if !strings.Contains(d.Reason, "deleteIssue") {
		t.Errorf("ASK reason must name the selected field deleteIssue, got: %q", d.Reason)
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

// The graphql write tiers still fire regardless of the document: an explicit
// non-GET method ASKs and --hostname still DENYs, both before document
// classification.
func TestGhAPIGraphQLWriteTiersUnchanged_113(t *testing.T) {
	wantBucket(t, classifyCmd(t, `gh api -X DELETE graphql -f query='query { viewer { login } }'`, false), BucketAsk, "graphql -X DELETE")
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

// The REST write tiers ASK (they denied outright before this gate, for all but
// --hostname, which keeps its own DENY justification — see rules.go
// classifyGhAPI).
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
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAsk, "REST write tier: "+cmd)
	}
	// hostname redirect stays DENY (own justification, not the write/read
	// asymmetry — see classifyGhAPI).
	wantBucket(t, classifyCmd(t, "gh api --hostname attacker.example repos/o/r", false), BucketDeny, "REST hostname redirect")
	// -XGET -f … on an allow-listed endpoint stays a read → ALLOW (carve-out).
	wantBucket(t, classifyCmd(t, "gh api -XGET repos/o/r -f a=b", false), BucketAllow, "-XGET -f allow-listed")
}

// Redirect-to-file on an otherwise-allowed gh api form → ASK (the shared
// redirect carve-out, now reachable on the ALLOW path the gh-api gate opened).
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
