package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
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

// The contained-allow cases — every acceptance-criterion ALLOW form, run
// against a real repo so Engine B containment resolves a concrete worktree root.
func TestInRepoWriteContainedAllow(t *testing.T) {
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

// cp/mv with a destination that does not yet exist still resolves correctly
// (canonicalize resolves the segments that exist and carries the rest as
// written) and ALLOWs.
func TestInRepoWriteNonExistentDest(t *testing.T) {
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

// Escape-deny cases — a write whose operand resolves outside the repo (or
// into the primary clone) DENIES with the worktree-anchored remediation.
func TestInRepoWriteEscapeDeny(t *testing.T) {
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
		// The deny must carry the worktree-anchored remediation.
		if !containsSubstr(d.Reason, "current repo") && !containsSubstr(d.Reason, "worktree") {
			t.Errorf("%s: deny reason should name the repo/worktree boundary; got %q", tc.label, d.Reason)
		}
		if !containsSubstr(d.Reason, ".claude/tmp/") {
			t.Errorf("%s: deny reason should steer scratch to .claude/tmp/; got %q", tc.label, d.Reason)
		}
		// The bash-write denies prescribe BOTH destinations — the in-repo
		// one and the harness scratchpad for cross-repo / cross-session handoff.
		if !containsSubstr(d.Reason, harnessScratchDisplay()) {
			t.Errorf("%s: deny reason should also name the harness scratchpad; got %q", tc.label, d.Reason)
		}
	}
}

// Every in-place spelling sedInPlace recognizes reaches write containment, so
// one aimed at a sibling repository is denied there as a cross-repo write.
func TestInRepoWriteSedInPlaceSpellingsContained(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	gitInit(t, filepath.Join(base, "sibling"))
	root := canonicalize(repo)
	ev := bashEvIn(t, root, "main")

	for _, cmd := range []string{
		`sed -Ei 's/a+/b/' ../sibling/f`,
		`sed -ni 's/a/b/p' ../sibling/f`,
		`sed -I '' 's/a/b/' ../sibling/f`,
		`sed --in-place=.bak 's/a/b/' ../sibling/f`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket != BucketDeny || d.Operation != "bash-write:cross-repo" {
			t.Errorf("%q: got %q/%q (%q), want deny/bash-write:cross-repo", cmd, d.Bucket, d.Operation, d.Reason)
		}
	}
	wantBucket(t, classifyBash(`sed -Ei 's/a+/b/' f`, ev), BucketAllow, "contained sed -Ei")
	// The argument after a bare -i is BSD's suffix and GNU's script, so every
	// file either sed edits is contained: GNU edits the argument after it.
	wantBucket(t, classifyBash(`sed -i '' 's/a/b/' f`, ev), BucketAllow, "contained sed -i ''")
	wantBucket(t, classifyBash(`sed -I '' '/x/d' f`, ev), BucketAllow, "contained sed -I ''")
	for _, cmd := range []string{
		`sed -i "" ../sibling/f target.md`,
		`sed -i '' '/x/d' f`,
		`sed -i '' '/x/d' ../sibling/f`,
		// BSD's getopt stops at the script, so it edits ../sibling/f.
		`sed -i.bak f -e ../sibling/f`,
		// GNU writes the backup to the suffix with the file's name for `*`.
		`sed -i'../sibling/*' 's/a/b/' f`,
		`sed --in-place='../sibling/*.bak' 's/a/b/' f`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketDeny, cmd)
	}
	// Without --follow-symlinks GNU sed puts the file's name as spelled,
	// directory included, in place of `*` (get_backup_file_name,
	// sed/execute.c), so a backup suffix that climbs out of it is graded from
	// there.
	wantBucket(t, classifyBash(`sed -i'*/../../../x' 's/a/b/' sub/f`, ev), BucketDeny, "backup climbing out")
	wantBucket(t, classifyBash(`sed -i'*/../../x' 's/a/b/' sub/f`, ev), BucketAllow, "backup staying in")
}

// A write that escapes only in GNU's reading of a bare -i, where BSD sed's
// reading of the same line runs and stays inside, is denied with a reason
// naming the spellings no sed misreads; one that escapes in BSD's reading too,
// or one BSD sed refuses to run, keeps the ordinary cross-repo reason.
func TestSedBareInPlaceDenyReason(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	gitInit(t, filepath.Join(base, "sibling"))
	ev := bashEvIn(t, canonicalize(repo), "main")

	// Each row's reason names the spellings in allowed, and each of those is
	// allowed.
	for _, tc := range []struct {
		cmd     string
		names   []string
		allowed []string
	}{
		{`sed -i '' '/x/d' f`, []string{"'/x/d'", "`-I ''`", "Edit tool"}, []string{`sed -I '' '/x/d' f`}},
		{`sed -i '' -e '/x/d' f`, []string{"`-I ''`", "Edit tool"}, []string{`sed -I '' -e '/x/d' f`}},
		{`sed -i '' --expression='/x/d' f`, []string{"`-I ''`", "Edit tool"},
			[]string{`sed -I '' --expression='/x/d' f`}},
		{`sed -i .bak '/x/d' f`, []string{"'/x/d'", "`-i.bak`", "`-I .bak`", "Edit tool"},
			[]string{`sed -i.bak '/x/d' f`, `sed -I .bak '/x/d' f`}},
		{`sed -i '.b k' '/x/d' f`, []string{"`-i'.b k'`", "`-I '.b k'`"},
			[]string{`sed -i'.b k' '/x/d' f`, `sed -I '.b k' '/x/d' f`}},
	} {
		d := classifyBash(tc.cmd, ev)
		if d.Bucket != BucketDeny || d.Operation != "bash-write:cross-repo" {
			t.Errorf("%q: got %q/%q, want deny/bash-write:cross-repo", tc.cmd, d.Bucket, d.Operation)
			continue
		}
		for _, want := range tc.names {
			if !strings.Contains(d.Reason, want) {
				t.Errorf("%q: the reason does not name %s; got %q", tc.cmd, want, d.Reason)
			}
		}
		if strings.Contains(d.Reason, "`-e`") {
			t.Errorf("%q: the reason names `-e`, which leaves the line denied; got %q", tc.cmd, d.Reason)
		}
		for _, cmd := range tc.allowed {
			wantBucket(t, classifyBash(cmd, ev), BucketAllow, cmd+", which the reason for "+tc.cmd+" names")
		}
	}
	for _, cmd := range []string{
		`sed -i '' '/x/d' ../sibling/f`,
		`sed -i "" ../sibling/f target.md`,
		`sed -i 's/a/b/' ../sibling/f`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket != BucketDeny || strings.Contains(d.Reason, "-I ''") {
			t.Errorf("%q: got %q (%q), want the ordinary cross-repo deny", cmd, d.Bucket, d.Reason)
		}
	}
}

// Under --follow-symlinks GNU sed edits a symlink operand under the name it
// follows the link to, and builds the backup's name from that name, so the
// backup is contained from there. A link the gate cannot follow defers.
func TestSedFollowSymlinksBackupContained(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink semantics differ on windows")
	}
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	root := canonicalize(repo)
	for _, dir := range []string{filepath.Join(root, "a", "b"), filepath.Join(root, "c")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{filepath.Join(root, "c", "f"), filepath.Join(root, "a", "b", "plain")} {
		if err := os.WriteFile(f, []byte("a"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink("../../c/f", filepath.Join(root, "a", "b", "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../c/missing", filepath.Join(root, "a", "b", "dangling")); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, filepath.Join(root, "a", "b"), "main")

	// GNU follows link to ../../c/f, from a/b, and writes the backup to
	// ../../../c/f, from a/b: outside the repository.
	for _, cmd := range []string{
		`sed -i'../*' --follow-symlinks 's/a/b/' link`,
		`sed --follow-symlinks --in-place='../*' 's/a/b/' link`,
		`sed --follow -i'../*' 's/a/b/' link`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket != BucketDeny || d.Operation != "bash-write:cross-repo" {
			t.Errorf("%q: got %q/%q (%q), want deny/bash-write:cross-repo", cmd, d.Bucket, d.Operation, d.Reason)
		}
	}
	// Without --follow-symlinks the backup is ../link, from a/b; a regular file
	// is its own name; and a suffix that stays inside from c/f is allowed.
	for _, cmd := range []string{
		`sed -i'../*' 's/a/b/' link`,
		`sed -i'../*' --follow-symlinks 's/a/b/' plain`,
		`sed -i'*.bak' --follow-symlinks 's/a/b/' link`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, cmd)
	}
	for _, cmd := range []string{
		`sed -i --follow-symlinks 's/a/b/' dangling`,
		`sed -i --follow-symlinks 's/a/b/' absent`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket != BucketDefer || d.Operation != "bash-write:unreadable-link" {
			t.Errorf("%q: got %q/%q (%q), want defer/bash-write:unreadable-link", cmd, d.Bucket, d.Operation, d.Reason)
		}
	}
	// An escape elsewhere on the line still denies past a link it cannot follow.
	gitInit(t, filepath.Join(base, "sibling"))
	cmd := `sed -i --follow-symlinks 's/a/b/' dangling ../../../sibling/f`
	wantBucket(t, classifyBash(cmd, ev), BucketDeny, cmd)
}

// sedFollowSymlink names a file as GNU sed's follow_symlink does: the link
// text alone when it is absolute or the name has no directory, and behind the
// name's directory otherwise, link after link.
func TestSedFollowSymlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink semantics differ on windows")
	}
	base := canonicalize(t.TempDir())
	if err := os.MkdirAll(filepath.Join(base, "d", "e"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, "t"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	links := map[string]string{
		"rel":         "t",
		"d/up":        "../t",
		"d/e/chain":   "../up",
		"abs":         filepath.Join(base, "t"),
		"d/dangling":  "nowhere",
		"d/e/to-dang": "../dangling",
	}
	for name, text := range links {
		if err := os.Symlink(text, filepath.Join(base, name)); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		name, want string
		ok         bool
	}{
		{"t", "t", true},
		{"rel", "t", true},
		{"d/up", "d/../t", true},
		{"d/e/chain", "d/e/../../t", true},
		{"abs", filepath.Join(base, "t"), true},
		{base + "/d/up", base + "/d/../t", true},
		{"d/dangling", "", false},
		{"d/e/to-dang", "", false},
		{"absent", "", false},
	} {
		got, ok := sedFollowSymlink(tc.name, base)
		if ok != tc.ok || ok && got != tc.want {
			t.Errorf("sedFollowSymlink(%q) = %q, %v, want %q, %v", tc.name, got, ok, tc.want, tc.ok)
		}
	}
}

// A sed carrying an option outside sed's table still has its files contained:
// an escape denies, and a contained one defers rather than being allowed.
func TestSedUnknownOptionFilesContained(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	gitInit(t, filepath.Join(base, "sibling"))
	ev := bashEvIn(t, canonicalize(repo), "main")

	// Past sedMaxForks the argv is read once, with every argument that is not
	// an option a file.
	pastForkCap := `sed -i -X` + strings.Repeat(` -l`, 10) + ` ../sibling/f`
	if n := len(sedReadings(strings.Fields(pastForkCap)[1:])); n != 1 {
		t.Fatalf("%q: got %d readings, want the one past sedMaxForks", pastForkCap, n)
	}
	for _, cmd := range []string{
		`sed -i -X p ../sibling/f`,
		`sed -n p -X ../sibling/f`,
		`sed -i --bogus 's/a/b/' ../sibling/f`,
		pastForkCap,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketDeny, cmd)
	}
	for _, cmd := range []string{
		`sed -i -X p f`,
		`sed -n p -X f`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketDefer, cmd)
	}
}

// BSD sed reads a label to the end of the line, so its reading of `-l` taking
// no value runs `:l;1~2`, which GNU's label rule rejects, and reads the file
// after it: that file is contained.
func TestSedBSDLabelReadingContained(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	gitInit(t, filepath.Join(base, "sibling"))
	ev := bashEvIn(t, canonicalize(repo), "main")

	cmd := `sed -l ':l;1~2' ../sibling/f`
	if d := classifyBash(cmd, ev); d.Bucket != BucketDeny || !strings.Contains(d.Operation, "cross-repo") {
		t.Errorf("%q: got %q/%q (%q), want a cross-repo deny", cmd, d.Bucket, d.Operation, d.Reason)
	}
}

// The files a sed script's own commands read and write are contained: a read
// in any sed, and a write as the write it is.
func TestSedScriptCommandFilesContained(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	gitInit(t, filepath.Join(base, "sibling"))
	ev := bashEvIn(t, canonicalize(repo), "main")

	for _, cmd := range []string{
		`sed -n 'r ../sibling/x' f`,
		`sed -n '1R ../sibling/x' f`,
		`sed -n 'w ../sibling/x' f`,
		`sed -n '/a/W ../sibling/x' f`,
		`sed 's/a/b/w ../sibling/x' f`,
		`sed 's/a/b/gp w ../sibling/x' f`,
		`sed -n -e p -e 'w ../sibling/x' f`,
		`sed -n --expression='$r ../sibling/x' f`,
		`sed -n ':a;w ../sibling/x' f`,
		`sed -n '/x/{p;w ../sibling/x
}' f`,
		`sed -i 'w ../sibling/x' f`,
		`sed 's/[/]/x/w ../sibling/x' f`,
		`sed -i 's/a/b/' f -e 'w ../sibling/x'`,
		// GNU's -l takes `x` as its value, so the script is the one after it.
		`sed -l x 'r ../sibling/x' f`,
		`sed -n -lx 'r ../sibling/x' f`,
		// A label ends at a blank, and GNU reads the next command after it.
		`sed -n ':a w ../sibling/x' f`,
		`sed -n 'b a r ../sibling/x' f`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketDeny, cmd)
	}
	for _, cmd := range []string{
		`sed -n 'w out.txt' f`,
		`sed -n 'r in.txt' f`,
		`sed 's/a/b/w out.txt' f`,
		`sed -n 'w /dev/stdout' f`,
		`sed '1a ../sibling/x' f`,
		`sed -n 'p # w ../sibling/x' f`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, cmd)
	}
}

// sedCommandFiles reads the files a script's commands name, in GNU's reading
// of a bracket expression and BSD's.
func TestSedCommandFiles(t *testing.T) {
	for _, tc := range []struct {
		script        string
		brackets      bool
		reads, writes []string
	}{
		{"p", false, nil, nil},
		{"r a", false, []string{"a"}, nil},
		{"R  a b;c", false, []string{"a b;c"}, nil},
		{"w a\np", false, nil, []string{"a"}},
		{"1,/x/W a", false, nil, []string{"a"}},
		{`\,x,!w a`, false, nil, []string{"a"}},
		{"s/a/b/w a", false, nil, []string{"a"}},
		{"s|a/w|b/w x|g", false, nil, nil},
		{"y/abc/xyz/;w a", false, nil, []string{"a"}},
		{"/x/I,+3{s/a/b/2;w a\n}", false, nil, []string{"a"}},
		{"b end;w a", false, nil, []string{"a"}},
		{":a w b", false, nil, []string{"b"}},
		{"t a r b", false, []string{"b"}, nil},
		{"/x/{b end}\nw a", false, nil, []string{"a"}},
		{"a\\\nw a\\\nw b\nw c", false, nil, []string{"c"}},
		{"i w a", false, nil, nil},
		{"# w a\nw b", false, nil, []string{"b"}},
		{"w /dev/stdout\nr /dev/stdin", false, nil, nil},
		{"w a\nk\nw b", false, nil, []string{"a"}},
		{"s/[/]/x/w a", false, nil, nil},
		{"s/[/]/x/w a", true, nil, []string{"a"}},
		{"s/[[:alpha:]/]/x/w a", true, nil, []string{"a"}},
		{"s/[]/]/x/w a", true, nil, []string{"a"}},
	} {
		reads, writes := sedCommandFiles(tc.script, tc.brackets)
		if !sliceEq(reads, tc.reads) || !sliceEq(writes, tc.writes) {
			t.Errorf("sedCommandFiles(%q, %v) = %q, %q, want %q, %q",
				tc.script, tc.brackets, reads, writes, tc.reads, tc.writes)
		}
	}
}

// A write whose target lands under .git/ is denied, even though it
// is technically in-repo / contained.
func TestInRepoWriteGitTreeDenied(t *testing.T) {
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

// A subagent writing into the primary clone via cp/sed -i DENIES — the
// worktree-escape deny is preserved (the classifier inherits Engine B's
// worktree-root resolution, so the subagent's worktree root is the containment
// boundary).
func TestInRepoWriteSubagentPrimaryCloneDenied(t *testing.T) {
	primary, wt := setupWorktree(t)
	if err := os.WriteFile(filepath.Join(wt, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev := bashEvIn(t, wt, "issue-developer")

	// cp from the worktree INTO the primary clone → worktree-escape deny.
	cpd := classifyBash(`cp a.txt `+filepath.Join(primary, "stolen.txt"), ev)
	wantBucket(t, cpd, BucketDeny, "subagent cp into primary clone")
	if !containsSubstr(cpd.Reason, "worktree") {
		t.Errorf("cp deny should mention the worktree; got %q", cpd.Reason)
	}

	// sed -i targeting a file in the primary clone → worktree-escape deny.
	sedd := classifyBash(`sed -i 's/a/b/' `+filepath.Join(primary, "README.md"), ev)
	wantBucket(t, sedd, BucketDeny, "subagent sed -i into primary clone")

	// A subagent writing INSIDE its own worktree is contained → ALLOW.
	own := classifyBash(`cp a.txt b.txt`, ev)
	wantBucket(t, own, BucketAllow, "subagent in-worktree cp is contained")
}

// A symlink inside the worktree pointing outside it is caught (both
// sides canonicalized) when used as a cp/sed -i target.
func TestInRepoWriteSymlinkEscape(t *testing.T) {
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
	wantBucket(t, d, BucketDeny, "cp through symlink escaping worktree")
}

// Unknown-expansion targets DEFER, not ALLOW (a $(...)-built target cannot be
// statically contained).
func TestInRepoWriteDynamicPathDefers(t *testing.T) {
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
		if d.Bucket != BucketDefer {
			t.Errorf("dynamic-path write must DEFER, not %q: %s", d.Bucket, cmd)
		}
		// The half that carries the safety: it must never ride the in-repo-write
		// ALLOW, and the defer must be loggable so the unpinnable write shows up
		// in the tuning feed rather than vanishing.
		if d.Operation == "" || d.Reason == "" {
			t.Errorf("dynamic-path write defer must carry the gate's analysis; got op=%q reason=%q for %s",
				d.Operation, d.Reason, cmd)
		}
	}
}

// rm stays OFF the in-repo-write allow track (conservative default). A
// contained `rm` must NOT auto-allow — it defers (the normal pipeline / its
// ask-list governs it).
func TestInRepoWriteRmStaysOffAllowTrack(t *testing.T) {
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
			t.Errorf("rm must NOT ride the in-repo-write allow track (conservative); got ALLOW for %q", cmd)
		}
	}
}

// The read-only forms of the dual-mode programs (sed without -i, tee
// /dev/null) keep their read-only-utility ALLOW and do NOT route through the
// write classifier.
func TestInRepoWriteDualModeReadOnlyUnaffected(t *testing.T) {
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

// A real-file redirect on a write command disqualifies the ALLOW (bytes
// also leave for a file the operand parser does not model) → defer.
func TestInRepoWriteRedirectDefers(t *testing.T) {
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

// Unit: sedFileOperands excludes the inline script but keeps files, and
// keeps every operand when -e/-f supplies the script.
func TestSedFileOperands(t *testing.T) {
	cases := []struct {
		args []string
		want []string
	}{
		{[]string{"-i", "s/a/b/", "f1", "f2"}, []string{"f1", "f2"}},
		{[]string{"-i", "s/a/b/"}, nil}, // script only, no file → no in-place target
		{[]string{"-i", "-e", "s/a/b/", "f1"}, []string{"f1"}},
		// BSD's getopt takes s/a/b/ as the script and stops there, so -e and
		// s/c/d/ are files too.
		{[]string{"-i", "-e", "s/a/b/", "-e", "s/c/d/", "f1", "f2"}, []string{"f1", "f2", "-e", "s/c/d/"}},
		{[]string{"-n", "s/a/b/", "f1", "-f", "x.sed"}, []string{"s/a/b/", "f1", "-f", "x.sed"}},
		{[]string{"-i.bak", "s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"-i", "--expression=s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"-i", "-n", "s/a/b/", "f1"}, []string{"f1"}}, // -n bool before script
		// An unknown option still yields the files, for containment.
		{[]string{"-i", "--bogus", "s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"-Ei", "s/a+/b/", "f1"}, []string{"f1"}},
		{[]string{"-nEi.bak", "s/a/b/p", "f1"}, []string{"f1"}},
		{[]string{"-xi", "s/a/b/", "f1"}, []string{"f1"}},
		// BSD's -I takes its suffix from the next argument; GNU has no -I.
		{[]string{"-I", ".bak", "s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"-I", "", "/x/d", "f1"}, []string{"f1"}},
		{[]string{"-I", "s/a/b/", "f1"}, nil}, // suffix s/a/b/, script f1, no file
		// After a bare -i, BSD's suffix and GNU's script: GNU takes /x/d for a
		// file.
		{[]string{"-i", "", "/x/d", "f1"}, []string{"/x/d", "f1"}},
		{[]string{"-ni", "", "/x/d", "f1"}, []string{"/x/d", "f1"}},
		{[]string{"-i", "", "../sibling/f", "target.md"}, []string{"../sibling/f", "target.md"}},
		// -l: GNU's line length takes the next argument or the rest of the
		// cluster, whatever it holds; BSD's takes none. A BSD reading whose
		// script both seds reject (`5`), or with an option BSD lacks (`-5`), runs
		// nothing and adds no file.
		{[]string{"-l", "5", "/x/d", "f1"}, []string{"f1"}},
		{[]string{"-l5", "/x/d", "f1"}, []string{"f1"}},
		{[]string{"-l", "/x/d", "f1"}, []string{"f1"}},
		{[]string{"-nl", "/x/d", "f1"}, []string{"f1"}},
		{[]string{"-l", "x", "r /etc/passwd", "f1"}, []string{"f1", "r /etc/passwd"}},
		{[]string{"-ln", "p", "f1"}, []string{"f1"}},
		// BSD reads a label to the end of the line, so its reading of `:l;1~2`
		// runs and reads the file.
		{[]string{"-l", ":l;1~2", "../sibling/f"}, []string{"../sibling/f"}},
		{[]string{"--line-length", "5", "/x/d", "f1"}, []string{"f1"}},
		{[]string{"--line-length=5", "/x/d", "f1"}, []string{"f1"}},
		// The rest of the table, and GNU's abbreviated long options.
		{[]string{"-a", "-H", "-b", "-s", "-z", "-u", "s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"--debug", "--posix", "--sandbox", "--zero-terminated", "s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"--expr", "s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"--expr=s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"--fil", "x.sed", "f1"}, []string{"f1"}},
		{[]string{"--qui", "s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"--in", "s/a/b/", "f1"}, []string{"f1"}},
		{[]string{"--s", "s/a/b/", "f1"}, []string{"f1"}},       // silent, separate or sandbox
		{[]string{"--quiet=x", "s/a/b/", "f1"}, []string{"f1"}}, // a value on a bool option
		{[]string{"-ef1", "f2"}, []string{"f2"}},
		{[]string{"-ei", "f1"}, []string{"f1"}},
		{[]string{"-nfx.sed", "f1"}, []string{"f1"}},
		{[]string{"--", "-i"}, nil}, // the script, and no file
	}
	for _, tc := range cases {
		got := sedFileOperands(tc.args)
		if !sliceEq(got, tc.want) {
			t.Errorf("sedFileOperands(%q) = %q, want %q", tc.args, got, tc.want)
		}
	}
}

// Unit: sedScriptFiles returns the file every -f and --file spelling names.
func TestSedScriptFiles(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want []string
	}{
		{[]string{"-f", "x.sed", "f1"}, []string{"x.sed"}},
		{[]string{"-fx.sed", "f1"}, []string{"x.sed"}},
		{[]string{"-nf", "x.sed", "f1"}, []string{"x.sed"}},
		{[]string{"--file", "x.sed", "f1"}, []string{"x.sed"}},
		{[]string{"--file=x.sed", "f1"}, []string{"x.sed"}},
		{[]string{"--fil", "x.sed", "f1"}, []string{"x.sed"}},
		{[]string{"--fi=x.sed", "f1"}, []string{"x.sed"}},
		{[]string{"-l", "-f", "x.sed", "f1"}, []string{"x.sed"}},
		{[]string{"-e", "-f", "f1"}, nil},
		{[]string{"s/a/b/", "f1"}, nil},
	} {
		if got := sedScriptFiles(tc.args); !sliceEq(got, tc.want) {
			t.Errorf("sedScriptFiles(%q) = %q, want %q", tc.args, got, tc.want)
		}
	}
}

// A sed script file named by an abbreviated --file is contained like any
// other spelling of it.
func TestSedAbbreviatedScriptFileContained(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	gitInit(t, filepath.Join(base, "sibling"))
	ev := bashEvIn(t, canonicalize(repo), "main")
	for _, cmd := range []string{
		`sed -n --fil ../sibling/x.sed f`,
		`sed -n --fi=../sibling/x.sed f`,
		`sed -i --fil ../sibling/x.sed f`,
	} {
		if d := classifyBash(cmd, ev); d.Bucket != BucketDeny {
			t.Errorf("%q: got %q/%q (%q), want a deny", cmd, d.Bucket, d.Operation, d.Reason)
		}
	}
}

// Unit: cpMvOperands keeps all path operands incl. dest, handles -t DEST and
// skips suffix values.
func TestCpMvOperands(t *testing.T) {
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

// Unit: teeTargets returns real-file destinations, dropping /dev/null and flags.
func TestTeeTargets(t *testing.T) {
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
