package main

import (
	"os/exec"
	"testing"
)

// setupRepoWithEmail creates a real git repo with a given local user.email.
func setupRepoWithEmail(t *testing.T, dir, email string) {
	t.Helper()
	gitInit(t, dir)
	cmd := exec.Command("git", "-C", dir, "config", "--local", "user.email", email)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("set email: %v\n%s", err, out)
	}
}

// Ported behavior from auto-approve-compound-commands.sh: naked gh in an App
// repo (bot email) is denied; in a non-App repo it is not.
func TestNakedGhInAppRepoDenied(t *testing.T) {
	appRepo := t.TempDir()
	setupRepoWithEmail(t, appRepo, "1234567+claude-bot[bot]@users.noreply.github.com")

	ev := &Event{ToolName: "Bash", CWD: appRepo, AgentType: "main"}
	d := classifyBash("gh pr create --fill", ev)
	wantBucket(t, d, BucketDeny, "naked gh in App repo")
	if !containsSubstr(d.Reason, "gh_wrapper") {
		t.Errorf("deny reason should point at gh_wrapper; got %q", d.Reason)
	}

	// Even a read-only naked gh is denied in an App repo (wrong identity).
	d2 := classifyBash("gh pr list", ev)
	wantBucket(t, d2, BucketDeny, "read-only naked gh in App repo")
}

func TestNakedGhInNonAppRepoNotDenied(t *testing.T) {
	nonApp := t.TempDir()
	setupRepoWithEmail(t, nonApp, "dev@example.com")

	ev := &Event{ToolName: "Bash", CWD: nonApp, AgentType: "main"}
	d := classifyBash("gh pr list", ev)
	if d.Bucket == BucketDeny {
		t.Errorf("non-App repo naked gh must not DENY; got %q", d.Reason)
	}
}
