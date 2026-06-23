package main

import "testing"

// Ported forbidden-form denies from auto-approve-compound-commands.sh.
func TestForbiddenForms(t *testing.T) {
	deny := []string{
		"cd /tmp && git status",
		"git status && cd /tmp && git diff",
		"git -C /tmp log",
		"echo --- && git -C /tmp log",
		`git -C "/tmp" log`,
		"git -C '/var' status",
	}
	for _, cmd := range deny {
		d := classifyCmd(t, cmd, false)
		wantBucket(t, d, BucketDeny, "forbidden form: "+cmd)
	}

	notForbidden := []string{
		"cd /tmp",               // bare cd (no &&) is fine
		"git -C ./ log",         // relative -C is not the absolute forbidden form
		"git status && git log", // && without leading cd is fine
		"echo 'cd /x && y'",     // quoted literal must not trigger (AST sees one word)
		// Subagent carve-out (git-workflow.md): cd <subdir> && <non-git-cmd> is
		// explicitly allowed and must NOT be a forbidden-form deny.
		"cd frontend && npm run build",
		"cd backend && ruff check .",
	}
	for _, cmd := range notForbidden {
		d := classifyCmd(t, cmd, false)
		if d.Bucket == BucketDeny && (containsSubstr(d.Reason, "Forbidden form")) {
			t.Errorf("%q should NOT be a forbidden-form deny; got %q", cmd, d.Reason)
		}
	}
}
