package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// bashEvIn builds a Bash event rooted at repoRoot for the in-repo-write tests
// and chdirs the test process into it (via t.Chdir, auto-restored) so RELATIVE
// bash operands (`cp a b`) canonicalize against the repo — mirroring production,
// where the gate process runs in the same cwd as the tool call. Tests using this
// helper therefore cannot run in parallel.
func bashEvIn(t *testing.T, repoRoot, agentType string) *Event {
	t.Helper()
	t.Chdir(repoRoot)
	return &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: repoRoot, AgentType: agentType}
}

// #32: the contained-allow cases — every acceptance-criterion ALLOW form, run
// against a real repo so Engine B containment resolves a concrete worktree root.
func TestInRepoWriteContainedAllow_32(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	// Seed a source file so cp/mv have something real (containment also handles
	// not-yet-existing tails, exercised separately below).
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "in.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	ev := bashEvIn(t, root, "main")
	allowCmds := []string{
		`sed -i 's/a/b/' a.txt`,
		`sed -i 's/a/b/' in.txt a.txt`,
		`sed -i.bak 's/a/b/' a.txt`,
		`cp a.txt b.txt`,
		`cp in.txt a.txt b.txt`, // multiple sources... actually 2 sources + dest dir; all in-repo
		`mv a.txt b.txt`,
		`tee out.txt`,
		`tee -a out.txt`,
		`mkdir sub`,
		`mkdir -p sub/dir`,
		`touch new.txt`,
		`touch -r in.txt new.txt`,
	}
	for _, cmd := range allowCmds {
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketAllow, "contained in-repo write: "+cmd)
	}
}

// #32: cp/mv with a destination that does not yet exist still resolves correctly
// (canonicalize handles the non-existent tail via the longest existing ancestor)
// and ALLOWs.
func TestInRepoWriteNonExistentDest_32(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, root, "issue-developer")

	// Dest file under an existing (in-repo) dir, not yet created.
	wantBucket(t, classifyBash(`cp a.txt does/not/exist-yet.txt`, ev), BucketAllow,
		"cp to a not-yet-existing in-repo dest")
	wantBucket(t, classifyBash(`mv a.txt brand-new-name.txt`, ev), BucketAllow,
		"mv to a not-yet-existing in-repo dest")
}

// #32: escape-deny cases — a write whose operand resolves outside the repo (or
// into the primary clone) DENIES with the worktree-anchored remediation.
func TestInRepoWriteEscapeDeny_32(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	sibling := filepath.Join(base, "sibling")
	gitInit(t, repo)
	gitInit(t, sibling)
	root := canonicalize(repo)
	sib := canonicalize(sibling)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, root, "main")

	// cp/mv to an out-of-repo dest, sed -i / tee targeting an out-of-repo path.
	denyCmds := []struct{ cmd, label string }{
		{`cp a.txt ` + filepath.Join(sib, "x.txt"), "cp dest escapes to sibling repo"},
		{`mv a.txt ` + filepath.Join(base, "other-x.txt"), "mv dest escapes the repo"},
		{`sed -i 's/a/b/' ` + filepath.Join(sib, "a.txt"), "sed -i out-of-repo path"},
		{`tee ` + filepath.Join(base, "log.txt"), "tee out-of-repo destination"},
		{`touch ` + filepath.Join(base, "stamp"), "touch out-of-repo path"},
		{`mkdir ` + filepath.Join(base, "newdir"), "mkdir out-of-repo path"},
	}
	for _, tc := range denyCmds {
		d := classifyBash(tc.cmd, ev)
		wantBucket(t, d, BucketDeny, tc.label)
		// The deny must carry the worktree-anchored remediation (#127/#148 style).
		if !containsSubstr(d.Reason, "current repo") && !containsSubstr(d.Reason, "worktree") {
			t.Errorf("%s: deny reason should name the repo/worktree boundary; got %q", tc.label, d.Reason)
		}
		if !containsSubstr(d.Reason, ".claude/tmp/") {
			t.Errorf("%s: deny reason should steer scratch to .claude/tmp/; got %q", tc.label, d.Reason)
		}
	}
}

// #32: a write whose target lands under .git/ is denied (#125), even though it
// is technically in-repo / contained.
func TestInRepoWriteGitTreeDenied_32(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	ev := bashEvIn(t, root, "issue-developer")

	d := classifyBash(`tee `+filepath.Join(root, ".git", "hooks", "pre-commit"), ev)
	wantBucket(t, d, BucketDeny, "tee into .git/ tree")
	if !containsSubstr(d.Operation, ".git tree") {
		t.Errorf(".git write deny should be the .git-tree rule; got op %q (%s)", d.Operation, d.Reason)
	}

	d2 := classifyBash(`sed -i 's/a/b/' `+filepath.Join(root, ".git", "config"), ev)
	wantBucket(t, d2, BucketDeny, "sed -i into .git/config")
}

// #32: a subagent writing into the primary clone via cp/sed -i DENIES — #127 is
// preserved (the classifier inherits Engine B's worktree-root resolution, so the
// subagent's worktree root is the containment boundary).
func TestInRepoWriteSubagentPrimaryCloneDenied_127(t *testing.T) {
	primary, wt := setupWorktree(t)
	if err := os.WriteFile(filepath.Join(wt, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, wt, "issue-developer")

	// cp from the worktree INTO the primary clone → #127 deny.
	cpd := classifyBash(`cp a.txt `+filepath.Join(primary, "stolen.txt"), ev)
	wantBucket(t, cpd, BucketDeny, "#127 subagent cp into primary clone")
	if !containsSubstr(cpd.Reason, "worktree") {
		t.Errorf("#127 cp deny should mention the worktree; got %q", cpd.Reason)
	}

	// sed -i targeting a file in the primary clone → #127 deny.
	sedd := classifyBash(`sed -i 's/a/b/' `+filepath.Join(primary, "README.md"), ev)
	wantBucket(t, sedd, BucketDeny, "#127 subagent sed -i into primary clone")

	// A subagent writing INSIDE its own worktree is contained → ALLOW.
	own := classifyBash(`cp a.txt b.txt`, ev)
	wantBucket(t, own, BucketAllow, "subagent in-worktree cp is contained")
}

// #32: a symlink inside the worktree pointing outside it is caught (#12 — both
// sides canonicalized) when used as a cp/sed -i target.
func TestInRepoWriteSymlinkEscape_12(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink semantics differ on windows")
	}
	primary, wt := setupWorktree(t)
	if err := os.WriteFile(filepath.Join(wt, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	outsideTarget := filepath.Join(primary, "secret.txt")
	if err := os.WriteFile(outsideTarget, []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(wt, "link-to-outside")
	if err := os.Symlink(outsideTarget, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	ev := bashEvIn(t, wt, "issue-developer")

	// cp into the symlinked path resolves into the primary clone → deny.
	d := classifyBash(`cp a.txt `+link, ev)
	wantBucket(t, d, BucketDeny, "#12 cp through symlink escaping worktree")
}

// #32: unknown-expansion targets ASK, not ALLOW (a $(...)-built target cannot be
// statically contained — #1).
func TestInRepoWriteDynamicPathAsks_32(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, root, "main")

	for _, cmd := range []string{
		`cp a.txt $(echo dest).txt`,
		`sed -i 's/a/b/' "$(find . -name x)"`,
		`tee "$OUT"`, // unresolved env var
		`mkdir "$DIR"`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket != BucketAsk {
			t.Errorf("dynamic-path write must ASK (fail-closed), not %q: %s", d.Bucket, cmd)
		}
	}
}

// #32: rm stays OFF the in-repo-write allow track (conservative default). A
// contained `rm` must NOT auto-allow — it defers (the normal pipeline / its
// ask-list governs it).
func TestInRepoWriteRmStaysOffAllowTrack_32(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, root, "main")

	for _, cmd := range []string{`rm a.txt`, `rm -rf sub`, `rm -f a.txt b.txt`} {
		d := classifyBash(cmd, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("rm must NOT ride the in-repo-write allow track (conservative #32); got ALLOW for %q", cmd)
		}
	}
}

// #32: the read-only forms of the dual-mode programs (sed without -i, tee
// /dev/null) keep their #31 read-only-utility ALLOW and do NOT route through the
// write classifier.
func TestInRepoWriteDualModeReadOnlyUnaffected_32(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, root, "main")

	wantBucket(t, classifyBash(`sed -n '1p' a.txt`, ev), BucketAllow, "sed -n stays read-only ALLOW")
	wantBucket(t, classifyBash(`sed 's/a/b/' a.txt`, ev), BucketAllow, "sed without -i stays read-only ALLOW")
	wantBucket(t, classifyBash(`tee /dev/null`, ev), BucketAllow, "tee /dev/null stays read-only ALLOW")
}

// #32: a real-file redirect on a write command disqualifies the ALLOW (bytes
// also leave for a file the operand parser does not model) → defer.
func TestInRepoWriteRedirectDefers_32(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, root, "main")

	d := classifyBash(`cp a.txt b.txt > log.txt`, ev)
	if d.Bucket == BucketAllow {
		t.Errorf("cp with a real-file redirect must not ALLOW; got %q", d.Bucket)
	}
}

// #32 unit: sedFileOperands excludes the inline script but keeps files, and
// keeps every operand when -e/-f supplies the script.
func TestSedFileOperands_32(t *testing.T) {
	cases := []struct {
		args []string
		want []string
	}{
		{[]string{"-i", "s/a/b/", "f1", "f2"}, []string{"f1", "f2"}},
		{[]string{"-i", "s/a/b/"}, nil}, // script only, no file → no in-place target
		{[]string{"-i", "-e", "s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"-i", "-e", "s/a/b/", "-e", "s/c/d/", "f1", "f2"}, []string{"f1", "f2"}},
		{[]string{"-i.bak", "s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"-i", "--expression=s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"-i", "-n", "s/a/b/", "f1"}, []string{"f1"}}, // -n bool before script
		{[]string{"-i", "--bogus", "s/a/b/", "f1"}, nil},       // unknown flag → fail safe
	}
	for _, tc := range cases {
		got := sedFileOperands(tc.args)
		if !sliceEq(got, tc.want) {
			t.Errorf("sedFileOperands(%v) = %v, want %v", tc.args, got, tc.want)
		}
	}
}

// #32 unit: cpMvOperands keeps all path operands incl. dest, handles -t DEST and
// skips suffix values.
func TestCpMvOperands_32(t *testing.T) {
	cases := []struct {
		args []string
		want []string
	}{
		{[]string{"a", "b"}, []string{"a", "b"}},
		{[]string{"-r", "a", "b"}, []string{"a", "b"}},
		{[]string{"a", "b", "c/"}, []string{"a", "b", "c/"}},
		{[]string{"-t", "destdir", "a", "b"}, []string{"destdir", "a", "b"}},
		{[]string{"--target-directory=destdir", "a"}, []string{"destdir", "a"}},
		{[]string{"-S", ".bak", "a", "b"}, []string{"a", "b"}}, // suffix value skipped
		{[]string{"--", "-weird-name", "b"}, []string{"-weird-name", "b"}},
	}
	for _, tc := range cases {
		got := cpMvOperands(tc.args)
		if !sliceEq(got, tc.want) {
			t.Errorf("cpMvOperands(%v) = %v, want %v", tc.args, got, tc.want)
		}
	}
}

// #32 unit: teeTargets returns real-file destinations, dropping /dev/null and flags.
func TestTeeTargets_32(t *testing.T) {
	cases := []struct {
		args []string
		want []string
	}{
		{[]string{"out.txt"}, []string{"out.txt"}},
		{[]string{"-a", "out.txt"}, []string{"out.txt"}},
		{[]string{"/dev/null"}, nil},
		{[]string{"a", "/dev/null", "b"}, []string{"a", "b"}},
	}
	for _, tc := range cases {
		got := teeTargets(tc.args)
		if !sliceEq(got, tc.want) {
			t.Errorf("teeTargets(%v) = %v, want %v", tc.args, got, tc.want)
		}
	}
}

func sliceEq(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
