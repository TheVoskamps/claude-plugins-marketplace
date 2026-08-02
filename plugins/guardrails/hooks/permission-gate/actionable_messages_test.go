package main

import (
	"path/filepath"
	"regexp"
	"testing"
)

// trackerRefInReason matches the non-actionable issue-tracker pointers that
// must never appear in an agent-facing Reason: an "issue(s) #N" pointer,
// or a bare "(#N)" parenthetical embedded in prose. An issue number
// tells a blocked agent nothing about what to do — the Reason must be
// self-sufficiently actionable. Deny/ask LABELS (the Operation field) may
// still carry a stable "(#N)" tag; only the Reason is constrained here.
var trackerRefInReason = regexp.MustCompile(`issues? #\d+|\(#\d+\)|the #\d+ |#\d+\)\.`)

// TestRemediationReasonsAreActionable_58 is a class-level regression guard:
// every deny/ask Reason an agent can receive must read as self-sufficient
// remediation, with no bare issue-tracker pointer. It exercises each rule that
// previously embedded an issue reference in its Reason. If a future edit
// reintroduces a "See issue #N" / "(#N)" pointer in agent-facing text, this
// fails.
func TestRemediationReasonsAreActionable_58(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)

	type tc struct {
		name string
		got  func() Decision
	}
	cases := []tc{
		{"gh auth switch", func() Decision { return classifyCmd(t, "gh auth switch", false) }},
		{"git reset --hard (subagent)", func() Decision { return classifyCmd(t, "git reset --hard HEAD", true) }},
		{"git reset --hard (main)", func() Decision { return classifyCmd(t, "git reset --hard HEAD", false) }},
		{"git config identity write", func() Decision {
			return classifyCmd(t, "git config user.email foo@bar", false)
		}},
		{"forbidden cd && git", func() Decision { return classifyCmd(t, "cd /tmp && git status", false) }},
		{"forbidden git -C abs", func() Decision { return classifyCmd(t, "git -C /tmp log", false) }},
		{".git tree write", func() Decision {
			return classifyFileTool(&Event{
				ToolName: "Write", CWD: canonicalize(repo), AgentType: "issue-developer",
				ToolInput: []byte(`{"file_path":"` + filepath.Join(repo, ".git", "config") + `"}`),
			})
		}},
		{"cross-repo Write", func() Decision {
			return classifyFileTool(&Event{
				ToolName: "Write", CWD: canonicalize(repo), AgentType: "issue-developer",
				ToolInput: []byte(`{"file_path":"` + filepath.Join(sibling, "x.txt") + `"}`),
			})
		}},
		{"cross-repo bash-read", func() Decision {
			return classifyCmd(t, "cat "+filepath.Join(sibling, "x.txt"), false)
		}},
	}

	for _, c := range cases {
		d := c.got()
		if d.Bucket != BucketDeny && d.Bucket != BucketAsk {
			t.Fatalf("%s: expected a deny/ask decision to inspect; got %q (%s)", c.name, d.Bucket, d.Reason)
		}
		if trackerRefInReason.MatchString(d.Reason) {
			t.Errorf("%s: Reason carries a non-actionable issue-tracker pointer; got %q", c.name, d.Reason)
		}
	}
}

// TestScratchDestinationsNameResolvedRoot_193 is a class-level guard over every
// deny that carries the prescriptive scratch guidance. The gate already holds
// the resolved repository root (rc.topLevel — the same value the adjacent
// cross-repo deny prints as `repo root %s`), so the prescription must name that
// real, directly-usable path.
//
// The forbidden spellings, both live before this test: a literal
// `<repo-root>` placeholder, which the model then resolves for itself and can
// resolve to the primary clone rather than its own worktree; and a
// `$(git rev-parse --show-toplevel)` incantation, which tells the model to run
// a command for a value the gate is already holding. Call sites used to
// disagree with each other AND with the helper's own doc comment.
func TestScratchDestinationsNameResolvedRoot_193(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	repoRoot := canonicalize(repo)
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	sib := canonicalize(sibling)
	primary, wt := setupWorktree(t)

	fileWrite := func(cwd, target string) func() Decision {
		return func() Decision {
			return classifyFileTool(&Event{
				ToolName: "Write", CWD: cwd, AgentType: "issue-developer",
				ToolInput: []byte(`{"file_path":"` + target + `"}`),
			})
		}
	}
	bashWrite := func(cwd, cmd string) func() Decision {
		return func() Decision {
			return classifyBash(cmd, &Event{
				HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "issue-developer",
			})
		}
	}

	cases := []struct {
		name     string
		wantRoot string
		got      func() Decision
	}{
		{"file-tool .git-tree write", repoRoot, fileWrite(repoRoot, filepath.Join(repoRoot, ".git", "config"))},
		{"file-tool cross-repo write", repoRoot, fileWrite(repoRoot, filepath.Join(sib, "x.txt"))},
		{"file-tool worktree escape", wt, fileWrite(wt, filepath.Join(primary, "agents", "x.md"))},
		{"bash .git-tree write", repoRoot, bashWrite(repoRoot, "touch "+filepath.Join(repoRoot, ".git", "x"))},
		{"bash cross-repo write", repoRoot, bashWrite(repoRoot, "touch "+filepath.Join(sib, "x.txt"))},
		{"bash worktree escape", wt, bashWrite(wt, "touch "+filepath.Join(primary, "x.md"))},
	}

	for _, c := range cases {
		d := c.got()
		wantBucket(t, d, BucketDeny, c.name)
		if !containsSubstr(d.Reason, c.wantRoot+"/.claude/tmp/") {
			t.Errorf("%s: the deny must prescribe the RESOLVED root %q; got %q", c.name, c.wantRoot, d.Reason)
		}
		if containsSubstr(d.Reason, "<repo-root>") {
			t.Errorf("%s: the deny must not carry a <repo-root> placeholder; got %q", c.name, d.Reason)
		}
		if containsSubstr(d.Reason, "$(git rev-parse --show-toplevel)/.claude/tmp/") {
			t.Errorf("%s: the deny must not tell the model to run rev-parse for a root the gate holds; got %q",
				c.name, d.Reason)
		}
		// Both sanctioned destinations, per the prescriptive-remediation rule.
		if !containsSubstr(d.Reason, harnessScratchDisplay()) {
			t.Errorf("%s: the deny must also name the harness scratchpad handoff destination; got %q",
				c.name, d.Reason)
		}
	}
}
