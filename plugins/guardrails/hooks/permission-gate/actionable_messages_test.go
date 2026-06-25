package main

import (
	"path/filepath"
	"regexp"
	"testing"
)

// trackerRefInReason matches the non-actionable issue-tracker pointers that
// must never appear in an agent-facing Reason (#58): an "issue(s) #N" pointer,
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
