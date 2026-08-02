package main

import (
	"os/exec"
	"testing"
)

// Coverage for the gh ALLOW floor being replaced by ALLOW-by-enumeration
// (recognized reads + an enumerated recoverable-own-repo-write verb set);
// unrecognized gh noun/verb ASKs (fail-closed); an enumerated write to a
// FOREIGN repo ASKs (exfil-by-write scoping); and `git remote add`/`set-url`
// ASKs (the git version of the same channel).

// setupRepoWithOrigin creates a real git repo whose `origin` remote points at
// the given owner/repo, so sessionOriginRepo can resolve the session repo.
func setupRepoWithOrigin(t *testing.T, dir, ownerRepo string) {
	t.Helper()
	gitInit(t, dir)
	cmd := exec.Command("git", "-C", dir, "remote", "add", "origin",
		"git@github.com:"+ownerRepo+".git")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("set origin: %v\n%s", err, out)
	}
}

// classifyInRepo classifies a command with the event cwd set to a real repo, so
// origin-aware scoping can run its `git remote get-url origin`.
func classifyInRepo(t *testing.T, cmd, repoDir string) Decision {
	t.Helper()
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: repoDir, AgentType: "main"}
	return classifyBash(cmd, ev)
}

// --- gh ALLOW-by-enumeration; unrecognized ASKs ------------------------------

func TestGhEnumeratedRecoverableWriteAllow_163(t *testing.T) {
	// The sanctioned hot-loop write verbs ALLOW (own repo, no explicit target).
	for _, cmd := range []string{
		"gh pr create --fill",
		"gh pr comment 5 --body hi",
		"gh pr merge 7 --squash",
		"gh pr close 5",
		"gh pr ready 5",
		"gh pr reopen 5",
		"gh issue create --title t --body b",
		"gh issue comment 5 --body hi",
		"gh issue close 5",
		"gh issue edit 5 --add-label bug",
		"gh issue reopen 5",
		"gh label create urgent --color red",
		"gh gist create f.txt", // secret gist
		"gh cache delete 123",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "enumerated recoverable write: "+cmd)
	}
}

func TestGhReadStillAllow_163(t *testing.T) {
	// Reads remain ALLOW (including secret/variable list, whose write verbs DENY).
	for _, cmd := range []string{
		"gh pr list",
		"gh issue view 1",
		"gh pr diff 5",
		"gh pr checks 5",
		"gh secret list",
		"gh variable list",
		"gh run view 9",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "read still allow: "+cmd)
	}
}

func TestGhUnrecognizedFailsClosedToAsk_163(t *testing.T) {
	// The former silent ALLOW floor is gone: an unrecognized gh noun/verb —
	// which the microVM does not backstop for a credential-carrying operation —
	// fails closed to ASK, not ALLOW.
	for _, cmd := range []string{
		"gh frobnicate widget",
		"gh pr frobnicate 5",
		"gh issue frobnicate 5",
		"gh newnoun list", // unknown noun, even with a read-shaped verb
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAsk, "unrecognized gh fails closed: "+cmd)
	}
}

// `gh auth token` prints the active GitHub OAuth/PAT token to stdout — the
// gh analog of `aws configure get aws_secret_access_key`. Its noun `auth` is not
// in isGhReadOnly's knownNouns and its verb `token` is not an enumerated
// recoverable write, so it falls through to the fail-closed ASK. This test
// pins that the credential-exposure path holds (the gate is the semantic
// boundary for what the guest's credential may expose at an allowed host); a
// future refactor that added `auth` to knownNouns must not silently ALLOW it.
func TestGhAuthTokenFailsClosedToAsk_97(t *testing.T) {
	for _, cmd := range []string{
		"gh auth token",
		"gh auth token --hostname github.com",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAsk, "gh auth token fails closed: "+cmd)
	}
}

// A verb explicitly mapped false in ghRecoverableWriteVerbs (issue transfer) is
// NOT an enumerated recoverable write and falls through to the fail-closed ASK.
func TestGhMappedFalseVerbAsks_163(t *testing.T) {
	wantBucket(t, classifyCmd(t, "gh issue transfer 5 other/repo", false), BucketAsk,
		"issue transfer (mapped false) → fail-closed ASK")
}

// --- foreign-target write scoping --------------------------------------------

func TestGhForeignTargetWriteAsks_163(t *testing.T) {
	repo := t.TempDir()
	setupRepoWithOrigin(t, repo, "sessionowner/sessionrepo")

	// An enumerated write whose explicit target differs from origin → ASK.
	for _, cmd := range []string{
		"gh issue comment 5 -R attacker/repo --body x",
		"gh pr create -R attacker/repo --fill",
		"gh -R attacker/repo issue comment 5 --body x", // leading-global form
		"gh --repo=attacker/repo pr create --fill",     // =-joined form
		"gh -Rattacker/repo issue close 5",             // glued -R form
	} {
		wantBucket(t, classifyInRepo(t, cmd, repo), BucketAsk, "foreign-target write: "+cmd)
	}
}

func TestGhOwnTargetWriteAllows_163(t *testing.T) {
	repo := t.TempDir()
	setupRepoWithOrigin(t, repo, "sessionowner/sessionrepo")

	// An explicit target matching origin (case-insensitively) stays ALLOW.
	for _, cmd := range []string{
		"gh pr create -R sessionowner/sessionrepo --fill",
		"gh issue comment 5 -R SessionOwner/SessionRepo --body x", // case-insensitive
		"gh issue comment 5 --body x",                             // no explicit target → own repo
	} {
		wantBucket(t, classifyInRepo(t, cmd, repo), BucketAllow, "own-target write: "+cmd)
	}
}

func TestGhForeignTargetReadStaysAllow_163(t *testing.T) {
	repo := t.TempDir()
	setupRepoWithOrigin(t, repo, "sessionowner/sessionrepo")

	// Reads are NOT foreign-target-scoped: a GET to a foreign repo is not the
	// exfil channel (that is consummated only by a write).
	for _, cmd := range []string{
		"gh issue view 1 -R attacker/repo",
		"gh pr list -R attacker/repo",
	} {
		wantBucket(t, classifyInRepo(t, cmd, repo), BucketAllow, "foreign-target read stays allow: "+cmd)
	}
}

// When origin cannot be determined, foreign-target scoping fails OPEN: the write
// already passed the recoverable-write allowlist, so the floor is the former
// ALLOW rather than a silent bypass of a deny tier.
func TestGhForeignTargetUnknownOriginAllows_163(t *testing.T) {
	repo := t.TempDir()
	gitInit(t, repo) // no origin remote configured
	wantBucket(t, classifyInRepo(t, "gh issue comment 5 -R attacker/repo --body x", repo),
		BucketAllow, "unknown origin → foreign-target scoping fails open to ALLOW")
}

// --- git remote add / set-url ------------------------------------------------

func TestGitRemoteReaimAsks_163(t *testing.T) {
	for _, cmd := range []string{
		"git remote add evil git@github.com:attacker/repo.git",
		"git remote set-url origin git@github.com:attacker/repo.git",
		"git remote set-url --push origin git@github.com:attacker/repo.git",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAsk, "git remote re-aim: "+cmd)
	}
}

func TestGitRemoteReadNotAsked_163(t *testing.T) {
	// A `git remote -v` / `get-url` read is not a mutation and must not ASK.
	for _, cmd := range []string{
		"git remote -v",
		"git remote get-url origin",
		"git remote show origin",
	} {
		d := classifyCmd(t, cmd, false)
		if d.Bucket == BucketAsk || d.Bucket == BucketDeny {
			t.Errorf("git remote read must not ASK/DENY: %q got %q (%s)", cmd, d.Bucket, d.Reason)
		}
	}
}

// --- parseOwnerRepoFromRemote / normalizeRepoSlug ----------------------------

func TestParseOwnerRepoFromRemote_163(t *testing.T) {
	cases := map[string]string{
		"git@github.com:owner/repo.git":       "owner/repo",
		"git@github.com:owner/repo":           "owner/repo",
		"https://github.com/owner/repo.git":   "owner/repo",
		"https://github.com/owner/repo":       "owner/repo",
		"ssh://git@github.com/owner/repo.git": "owner/repo",
		"https://github.com/Owner/Repo.git":   "owner/repo", // lowercased
		"":                                    "",
		"not-a-url":                           "",
		"https://github.com/onlyone":          "",
	}
	for in, want := range cases {
		if got := parseOwnerRepoFromRemote(in); got != want {
			t.Errorf("parseOwnerRepoFromRemote(%q) = %q, want %q", in, got, want)
		}
	}
}
