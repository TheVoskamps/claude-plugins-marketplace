package main

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// trackerRefInReason matches the non-actionable issue-tracker pointers that
// must never appear in an agent-facing Reason: an "issue(s) #N" pointer,
// or a bare "(#N)" parenthetical embedded in prose. An issue number
// tells a blocked agent nothing about what to do — the Reason must be
// self-sufficiently actionable. Deny/ask LABELS (the Operation field) may
// still carry a stable "(#N)" tag; only the Reason is constrained here.
var trackerRefInReason = regexp.MustCompile(`issues? #\d+|\(#\d+\)|the #\d+ |#\d+\)\.`)

// trackerRefInComment matches an issue-tracker reference in a Go comment. It is
// the comment-side sibling of trackerRefInReason, and it is deliberately
// stricter: a Reason is prose that legitimately contains other `#` forms, while
// a comment has no legitimate use for one at all, so a bare `#<digits>` is
// enough. `#` followed by a non-digit (a shell comment quoted in an example, a
// fragment identifier) is untouched.
var trackerRefInComment = regexp.MustCompile(`#\d+`)

// TestNoIssueRefsInComments is the class-level guard for the rule that code must
// be authoritative and stand on its own. A comment reading "pre-existing
// <issue-number> behavior" states no invariant: it makes the reader fetch a
// ticket to learn the rule, and the pointer that prompted this guard was not
// even correct — it named the wrong issue. Provenance needs no help from the
// comment: `git blame` yields the line, the commit, the merge, the PR and the
// issue on demand, without every comment carrying a pointer that rots.
//
// So every invariant must be stated COMPLETELY in place, and a comment must
// never require fetching a ticket. This walks the package's own source, so a
// newly added file is covered the moment it lands.
//
// Scope note: this constrains COMMENTS. Stable deny/ask LABELS (the Operation
// field) may still carry a "(#N)" tag — they are grep keys for the evolution
// log, not text an agent has to act on — and a test failure message may name the
// issue whose acceptance criterion it pins. trackerRefInReason covers the
// agent-facing Reason text; between the two, nothing an agent reads and nothing
// a maintainer reads in place carries a bare tracker pointer.
//
// The check runs on the JOINED comment block, not line by line. A comment is
// wrapped prose: its sentences straddle line breaks, so a reference the wrap
// splits (`… before #` / `132 allowlisted it …`) is invisible to a per-line
// regex and to the grep a sweep is audited with. Joining the block with the
// wraps closed up puts the two halves back together, and it strictly subsumes
// the per-line check, since any match inside one line survives concatenation.
// The line-level scan is kept only so the failure message can name the exact
// line; the joined scan is what decides whether the block is clean.
func TestNoIssueRefsInComments(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	checked := 0
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") {
			continue
		}
		f, err := parser.ParseFile(fset, e.Name(), nil, parser.ParseComments)
		if err != nil {
			t.Fatalf("parse %s: %v", e.Name(), err)
		}
		checked++
		for _, cg := range f.Comments {
			var lines []string
			for _, c := range cg.List {
				lines = append(lines, strings.Split(c.Text, "\n")...)
			}
			m := trackerRefInComment.FindString(joinCommentBlock(lines))
			if m == "" {
				continue
			}
			// Locate the offending line for the message. A reference the wrap
			// split matches no single line, so fall back to the whole block.
			where := strings.TrimSpace(cg.Text())
			for _, c := range cg.List {
				for _, line := range strings.Split(c.Text, "\n") {
					if trackerRefInComment.MatchString(line) {
						where = strings.TrimSpace(line)
					}
				}
			}
			pos := fset.Position(cg.Pos())
			t.Errorf("%s:%d: a Go comment carries the tracker reference %q; state the invariant in "+
				"place instead (git blame has the provenance):\n\t%s",
				pos.Filename, pos.Line, m, where)
		}
	}
	if checked == 0 {
		t.Fatal("no Go files were checked — the guard would pass vacuously")
	}
}

// joinCommentBlock renders a comment block as ONE string with every line break
// closed up: each line is stripped of its `//` marker and surrounding
// whitespace, then concatenated with no separator. Closing the wrap up (rather
// than joining with a space) is the point — it is what puts a reference the wrap
// split back together. It introduces no false positives, because the pattern
// requires a digit immediately after the `#`, so the only text it can newly
// match is a line that ends in `#` followed by a line that starts with a digit.
func joinCommentBlock(lines []string) string {
	var b strings.Builder
	for _, line := range lines {
		b.WriteString(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "//")))
	}
	return b.String()
}

// TestNoIssueRefsInCommentsSeesWrappedRefs is the negative control for the guard
// above: it proves the joined-block scan catches a reference a per-line scan
// structurally cannot, so the widening is not decorative. The shape is a real
// one — comments are wrapped prose, so a reference near a wrap point ends up
// with its marker on one line and its digits on the next, and both the per-line
// guard and the grep a sweep is audited with walk straight past it.
func TestNoIssueRefsInCommentsSeesWrappedRefs(t *testing.T) {
	wrapped := []string{"// the rule introduced in #", "// 132 applies here"}
	// The defect being guarded against: line by line, neither half matches.
	for _, line := range wrapped {
		if trackerRefInComment.MatchString(line) {
			t.Fatalf("precondition failed: %q already matches per-line, so this control proves nothing", line)
		}
	}
	joined := joinCommentBlock(wrapped)
	if got := trackerRefInComment.FindString(joined); got != "#"+"132" {
		t.Errorf("the joined-block scan must recover the split reference; got %q from %q", got, joined)
	}
	// The joined scan must also still see an ordinary same-line reference, or it
	// would trade one blind spot for another.
	if got := trackerRefInComment.FindString(joinCommentBlock([]string{"// see #64 for the rationale"})); got == "" {
		t.Error("the joined-block scan must still catch a same-line reference")
	}
}

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
