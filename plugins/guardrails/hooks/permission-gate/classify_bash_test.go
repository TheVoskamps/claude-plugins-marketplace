package main

import "testing"

// classifyCmd is a test helper: parse and classify a bash command line in a
// given agent context.
func classifyCmd(t *testing.T, cmd string, subagent bool) Decision {
	t.Helper()
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: "/tmp"}
	if subagent {
		ev.AgentType = "issue-developer"
	} else {
		ev.AgentType = "main"
	}
	return classifyBash(cmd, ev)
}

func wantBucket(t *testing.T, d Decision, want Bucket, label string) {
	t.Helper()
	if d.Bucket != want {
		t.Errorf("%s: got bucket %q (reason=%q), want %q", label, d.Bucket, d.Reason, want)
	}
}

// §10: git globals before -C (#13); commands inside &&/;/pipelines;
// env VAR=x <cmd>; quoted/expanded strings (#1) — verified by classification.

func TestGitGlobalsBeforeSubcommand_13(t *testing.T) {
	// --no-pager / -c k=v / -P globals must be consumed; the real subcommand
	// (status) is read-only → ALLOW.
	for _, cmd := range []string{
		"git --no-pager status",
		"git -c color.ui=always status",
		"git -P log --oneline",
		"git --no-pager -c core.pager=cat log",
	} {
		d := classifyCmd(t, cmd, false)
		wantBucket(t, d, BucketAllow, "git globals: "+cmd)
	}
}

func TestCompoundCommands(t *testing.T) {
	// Every part read-only → ALLOW.
	wantBucket(t, classifyCmd(t, "git status && git log", false), BucketAllow, "&& both read-only")
	// A pipeline of read-only git ops → ALLOW.
	wantBucket(t, classifyCmd(t, "git log | git status", false), BucketAllow, "pipeline read-only")
	// One destructive part (subagent reset --hard) → DENY wins.
	wantBucket(t, classifyCmd(t, "git status && git reset --hard HEAD~1", true), BucketDeny, "&& with destructive part")
	// A semicolon sequence with an identity write → DENY wins.
	wantBucket(t, classifyCmd(t, "echo hi ; git config user.email x@y.z", false), BucketDeny, "; with identity write")
}

func TestEnvWrapper(t *testing.T) {
	// env VAR=x git status — the env wrapper and assignment must be stripped
	// so the real program (git status, read-only) is classified → ALLOW.
	wantBucket(t, classifyCmd(t, "env FOO=bar git status", false), BucketAllow, "env VAR=x git status")
	wantBucket(t, classifyCmd(t, "FOO=bar git log", false), BucketAllow, "VAR=x git log (assignment prefix)")
	// env wrapping a destructive subagent reset still classifies the inner cmd.
	wantBucket(t, classifyCmd(t, "env GIT_PAGER=cat git reset --hard", true), BucketDeny, "env + destructive")
}

func TestQuotedAndExpandedStrings_1(t *testing.T) {
	// Quoted argument to a read-only command — still classified ALLOW.
	wantBucket(t, classifyCmd(t, `git log --grep="fix bug"`, false), BucketAllow, "quoted arg read-only")
	// A command substitution anywhere makes the line non-statically-safe; it
	// must NOT auto-allow. git status with a substituted arg → defer (not allow).
	d := classifyCmd(t, `git log $(cat /etc/passwd)`, false)
	if d.Bucket == BucketAllow {
		t.Errorf("command substitution must not ALLOW; got %q", d.Bucket)
	}
}

// §10: gh auth switch and multi-identity switch forms are denied (#117).
func TestGhAuthSwitchDenied_117(t *testing.T) {
	wantBucket(t, classifyCmd(t, "gh auth switch", false), BucketDeny, "gh auth switch")
	wantBucket(t, classifyCmd(t, "gh auth switch --user other", false), BucketDeny, "gh auth switch --user")
	wantBucket(t, classifyCmd(t, "gh auth switch && gh pr list", false), BucketDeny, "gh auth switch in compound")
}

// §10: subagent git reset --hard is denied/asked with detached-checkout
// remediation in stderr (#120).
func TestGitResetHard_120(t *testing.T) {
	dSub := classifyCmd(t, "git reset --hard HEAD", true)
	wantBucket(t, dSub, BucketDeny, "subagent git reset --hard")
	if !containsSubstr(dSub.Reason, "detached checkout") {
		t.Errorf("#120 remediation must mention detached checkout; got %q", dSub.Reason)
	}
	// Main session: ask (still destructive) with the same remediation hint.
	dMain := classifyCmd(t, "git reset --hard HEAD", false)
	wantBucket(t, dMain, BucketAsk, "main git reset --hard")
}

// §10: git config user.* identity writes are denied (#125 write), including the
// `--file <path>` form where the file path precedes the user.* key. (The direct
// file-tool Write/Edit of a .git/config is exercised separately in
// containment_test.go's TestGitConfigFileWriteDenied_125.)
func TestGitConfigIdentityDenied_125(t *testing.T) {
	wantBucket(t, classifyCmd(t, "git config user.email x@y.z", false), BucketDeny, "git config user.email")
	wantBucket(t, classifyCmd(t, "git config user.name Foo", false), BucketDeny, "git config user.name")
	wantBucket(t, classifyCmd(t, "git config --global user.email x@y.z", false), BucketDeny, "git config --global user.email")
	// The `--file <path>` form routes the write through an explicit config file;
	// the path token sits BEFORE the user.* key, so the scan must skip the
	// --file value and still reach the key. (Previously this DEFERRED — the bug
	// the MEDIUM finding flagged.)
	wantBucket(t, classifyCmd(t, "git config --file .git/config user.email x@y.z", false), BucketDeny, "git config --file .git/config user.email")
	wantBucket(t, classifyCmd(t, "git config -f .git/config user.name Foo", false), BucketDeny, "git config -f .git/config user.name")
	wantBucket(t, classifyCmd(t, "git config --file=/tmp/cfg user.email x@y.z", false), BucketDeny, "git config --file=<path> user.email")
	// Read forms are not identity writes.
	d := classifyCmd(t, "git config --get user.email", false)
	if d.Bucket == BucketDeny {
		t.Errorf("git config --get must not DENY; got %q", d.Bucket)
	}
	// A non-identity config write (with a --file value preceding it) must NOT be
	// captured by the identity rule — confirms the value-skip does not over-match.
	if dc := classifyCmd(t, "git config --file .git/config core.editor vim", false); dc.Bucket == BucketDeny {
		t.Errorf("non-identity config write must not DENY as identity; got %q (%s)", dc.Bucket, dc.Reason)
	}
}

// §10: aws list/describe/get, read-only gh/acli/git subcommands allowed.
func TestReadOnlyAllowed(t *testing.T) {
	for _, cmd := range []string{
		"aws s3api list-buckets",
		"aws ec2 describe-instances",
		"aws --region us-west-2 lambda get-function --function-name f",
		"aws s3 ls",
		"gh pr list",
		"gh issue view 1",
		"gh repo view",
		"acli jira issue view ABC-1",
		"git status",
		"git diff HEAD",
		"git rev-parse --show-toplevel",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "read-only: "+cmd)
	}
}

func TestMutatingAwsNotAllowed(t *testing.T) {
	// A mutating aws op must not ALLOW (defers to the pipeline).
	d := classifyCmd(t, "aws s3api delete-object --bucket b --key k", false)
	if d.Bucket == BucketAllow {
		t.Errorf("aws delete-object must not ALLOW; got %q", d.Bucket)
	}
	// Substring trap: an op token that merely contains "list" but isn't a
	// list-* prefix must not be treated as read-only.
	d2 := classifyCmd(t, "aws foo unlist-thing", false)
	if d2.Bucket == BucketAllow {
		t.Errorf("unlist-thing must not ALLOW (substring trap); got %q", d2.Bucket)
	}
}

// §10: redirect to a real file must not ride an allow-listed prefix.
func TestRedirectToFileNotAllowed(t *testing.T) {
	d := classifyCmd(t, "git status > /tmp/exfil.txt", false)
	if d.Bucket == BucketAllow {
		t.Errorf("redirect to real file must not ALLOW; got %q", d.Bucket)
	}
	// Redirect to /dev/null is fine.
	wantBucket(t, classifyCmd(t, "git status 2>/dev/null", false), BucketAllow, "redirect /dev/null")
}

// §10: unparseable command fails closed (ASK, never allow).
func TestUnparseableFailsClosed(t *testing.T) {
	d := classifyCmd(t, "git status && (", false) // unbalanced paren
	if d.Bucket == BucketAllow || d.Bucket == BucketDefer {
		t.Errorf("unparseable command must fail closed (ask/deny); got %q", d.Bucket)
	}
}

func containsSubstr(s, sub string) bool {
	return len(sub) == 0 || (len(s) >= len(sub) && indexOf(s, sub) >= 0)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
