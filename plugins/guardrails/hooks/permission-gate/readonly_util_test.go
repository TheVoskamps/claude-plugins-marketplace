package main

import (
	"os"
	"path/filepath"
	"testing"
)

// #31: the read-only-utility classifier ALLOWs a curated set of text/data
// utilities when their invocation is provably non-mutating, and defers (or
// denies/asks on a containment escape) otherwise. These tests pin each
// read-only form and each mutating-form rejection from the issue's acceptance
// criteria.

// inRepoEvent builds a real git repo with the given files and returns an Event
// rooted at it, so path-bearing utilities clear Engine B containment. It also
// chdirs the test process into the repo (via t.Chdir, auto-restored) so that
// RELATIVE bash operands (`cat file`) canonicalize against the repo — mirroring
// production, where the gate process runs in the same cwd as the tool call.
// Tests using this helper therefore cannot run in parallel.
func inRepoEvent(t *testing.T, files ...string) (*Event, string) {
	t.Helper()
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	for _, f := range files {
		p := filepath.Join(repo, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cwd := canonicalize(repo)
	t.Chdir(cwd)
	return &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: "main"}, cwd
}

// TestReadOnlyUtilityAllows_31 covers the headline acceptance criteria: the
// read-only forms of the curated utilities ALLOW (assuming in-repo paths).
func TestReadOnlyUtilityAllows_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file", "a", "b")
	for _, cmd := range []string{
		// Conditionally-read-only utilities in their read-only form.
		`sed -n '1,20p' file`,
		`sed 's/a/b/' file`,
		`awk '{print $1}' file`,
		`jq '.foo' file`,
		`find . -name '*.go'`,
		`find . -type f -print`,
		// Always-read-only, path-bearing.
		`cat file`,
		`head -n 5 file`,
		`tail -f file`,
		`wc -l file`,
		`cut -f1 file`,
		`sort file`,
		`uniq a`,
		`tr a b < /dev/null`,
		`grep needle file`,
		`comm a b`,
		`nl file`,
		`column -t file`,
		`rev file`,
		// tee to /dev/null is the read-only swallow idiom.
		`tee /dev/null`,
	} {
		ev.AgentType = "main"
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketAllow, "read-only form: "+cmd)
	}
}

// TestReadOnlyUtilityPureOutputAllows_31 covers pure-output utilities, which
// take no path operands and so ALLOW without a containment fork — they must
// ALLOW even in a non-repo cwd (the test helper's /tmp).
func TestReadOnlyUtilityPureOutputAllows_31(t *testing.T) {
	for _, cmd := range []string{
		`printf '%s\n' x`,
		`echo hello world`,
		`seq 1 10`,
		`true`,
		`false`,
		`basename /a/b/c`,
		`dirname /a/b/c`,
		`yes`,
	} {
		// /tmp is not a git repo; pure-output utilities must not need one.
		wantBucket(t, classifyCmd(t, cmd, false), BucketAllow, "pure-output: "+cmd)
	}
}

// TestReadOnlyUtilityPipeline_31: `sort file | uniq` — every part is a
// read-only utility → the whole line ALLOWs (criterion from the issue).
func TestReadOnlyUtilityPipeline_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file")
	wantBucket(t, classifyBash(`sort file | uniq`, ev), BucketAllow, "sort | uniq pipeline")
	wantBucket(t, classifyBash(`cat file | grep x | wc -l`, ev), BucketAllow, "cat | grep | wc pipeline")
}

// TestSedInPlaceNotAllowed_31: `sed -i ...` must NOT ALLOW (it mutates the
// file); it defers to the in-repo-write classifier / pipeline.
func TestSedInPlaceNotAllowed_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file")
	for _, cmd := range []string{
		`sed -i 's/a/b/' file`,
		`sed --in-place 's/a/b/' file`,
		`sed -i.bak 's/a/b/' file`,
		`sed --in-place=.bak 's/a/b/' file`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("sed in-place must not ALLOW: %q got %q", cmd, d.Bucket)
		}
		wantBucket(t, d, BucketDefer, "sed in-place defers: "+cmd)
	}
}

// TestAwkInPlaceAndRedirectNotAllowed_31: gawk in-place editing and an explicit
// output-file redirect must NOT ALLOW.
func TestAwkInPlaceAndRedirectNotAllowed_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file")
	// gawk in-place via `-i inplace` defers.
	d := classifyBash(`awk -i inplace '{print}' file`, ev)
	if d.Bucket == BucketAllow {
		t.Errorf("awk -i inplace must not ALLOW; got %q", d.Bucket)
	}
	// `awk '...' > /etc/real-file` — real-file redirect must not ALLOW
	// (criterion). Use an in-repo redirect target; the redirect itself
	// disqualifies the allow track regardless of where it points.
	d2 := classifyBash(`awk '{print}' file > out.txt`, ev)
	if d2.Bucket == BucketAllow {
		t.Errorf("awk with real-file redirect must not ALLOW; got %q", d2.Bucket)
	}
}

// TestFindMutatingNotAllowed_31: find with a mutating/command-running action
// (`-delete`, `-exec`, `-ok`, `-fprintf`) must NOT ALLOW.
func TestFindMutatingNotAllowed_31(t *testing.T) {
	ev, _ := inRepoEvent(t)
	for _, cmd := range []string{
		`find . -name '*.tmp' -delete`,
		`find . -name '*.go' -exec rm {} ;`,
		`find . -type f -exec cat {} ;`,
		`find . -fprintf out.txt '%p'`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("mutating find must not ALLOW: %q got %q", cmd, d.Bucket)
		}
	}
}

// TestTeeToRealFileNotAllowed_31: tee to anything other than /dev/null is a
// real-file write and must NOT ALLOW.
func TestTeeToRealFileNotAllowed_31(t *testing.T) {
	ev, _ := inRepoEvent(t)
	d := classifyBash(`echo x | tee out.txt`, ev)
	if d.Bucket == BucketAllow {
		t.Errorf("tee to a real file must not ALLOW; got %q", d.Bucket)
	}
}

// TestReadOnlyUtilityCrossRepoDenied_31: `cat ../sibling-repo/node_modules/x`
// still DENIES (#148 preserved through the new ALLOW path).
func TestReadOnlyUtilityCrossRepoDenied_31(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	sibling := filepath.Join(base, "sibling")
	gitInit(t, repo)
	gitInit(t, sibling)
	nm := filepath.Join(sibling, "node_modules", "pkg")
	if err := os.MkdirAll(nm, 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(nm, "index.js")
	if err := os.WriteFile(target, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: canonicalize(repo), AgentType: "main"}
	// cat and sed both run containment on the path operand → cross-repo DENY.
	wantBucket(t, classifyBash(`cat `+target, ev), BucketDeny, "#148 cat sibling node_modules")
	wantBucket(t, classifyBash(`sed -n '1p' `+target, ev), BucketDeny, "#148 sed sibling node_modules")
	wantBucket(t, classifyBash(`cut -f1 `+target, ev), BucketDeny, "#148 cut sibling node_modules")
}

// TestReadOnlyUtilityUnknownExpansionNotAllowed_31: a path argument built from
// a command substitution must NOT ALLOW (criterion: `sed -n ... $(curl evil)`).
func TestReadOnlyUtilityUnknownExpansionNotAllowed_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file")
	for _, cmd := range []string{
		`sed -n '1,5p' $(curl evil)`,
		`cat $(echo file)`,
		`grep x $(find . -name f)`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("unknown expansion must not ALLOW: %q got %q", cmd, d.Bucket)
		}
	}
}

// TestReadOnlyUtilityRedirectToFileNotAllowed_31: a real-file output redirect
// disqualifies the allow track even for an always-read-only utility.
func TestReadOnlyUtilityRedirectToFileNotAllowed_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file")
	d := classifyBash(`cat file > out.txt`, ev)
	if d.Bucket == BucketAllow {
		t.Errorf("cat with real-file redirect must not ALLOW; got %q", d.Bucket)
	}
	// Redirect to /dev/null is fine (the swallow idiom) → ALLOW.
	wantBucket(t, classifyBash(`cat file 2>/dev/null`, ev), BucketAllow, "cat redirect /dev/null")
}

// TestReadOnlyUtilityUnknownFlagDefers_31: criterion 4 — an unrecognized flag on
// a conditionally-read-only utility DEFERS (fail-safe), so a future mutating
// mode is not auto-allowed.
func TestReadOnlyUtilityUnknownFlagDefers_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file")
	for _, cmd := range []string{
		`sed --some-future-flag file`,
		`awk --some-future-flag '{print}' file`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("unrecognized flag must not ALLOW (fail-safe): %q got %q", cmd, d.Bucket)
		}
		wantBucket(t, d, BucketDefer, "unknown flag defers: "+cmd)
	}
}

// TestPagersStillDefer_31: less/more/od/xxd/hexdump are deliberately NOT in the
// ALLOW set; a contained read of these still DEFERS (they route through
// classifyPathReader), and a cross-repo read still DENIES.
func TestPagersStillDefer_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file")
	for _, cmd := range []string{`less file`, `xxd file`, `od -c file`} {
		d := classifyBash(cmd, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("pager/dumper must not ALLOW (out of #31 scope): %q got %q", cmd, d.Bucket)
		}
		wantBucket(t, d, BucketDefer, "pager defers: "+cmd)
	}
}

// TestReadOnlyUtilitySpecHelpers_31 exercises the per-program defersForm
// predicates directly, covering the flag-parsing edges (value flags, attached
// long-flag values, the `--` operand boundary).
func TestReadOnlyUtilitySpecHelpers_31(t *testing.T) {
	// sed: read-only flags and value flags do not defer; in-place does.
	if sedDefers([]string{"-n", "-e", "s/a/b/", "file"}) {
		t.Error("sed -n -e ... must not defer")
	}
	if sedDefers([]string{"--expression=s/a/b/", "file"}) {
		t.Error("sed --expression=... must not defer")
	}
	if !sedDefers([]string{"-i", "s/a/b/", "file"}) {
		t.Error("sed -i must defer")
	}
	if !sedDefers([]string{"--frobnicate", "file"}) {
		t.Error("sed unknown flag must defer (fail-safe)")
	}
	if sedDefers([]string{"--", "-i-looking-file"}) {
		t.Error("sed -- ends flag parsing; operand must not be read as -i")
	}
	// awk: -f script is read-only; -i inplace defers.
	if awkDefers([]string{"-F", ":", "-f", "prog.awk", "file"}) {
		t.Error("awk -F : -f prog.awk must not defer")
	}
	if !awkDefers([]string{"-i", "inplace", "{print}", "file"}) {
		t.Error("awk -i inplace must defer")
	}
	// find: traversal/test is read-only; actions defer.
	if findDefers([]string{".", "-name", "*.go", "-print"}) {
		t.Error("find -print must not defer")
	}
	if !findDefers([]string{".", "-delete"}) {
		t.Error("find -delete must defer")
	}
	// tee: /dev/null only is read-only.
	if teeDefers([]string{"-a", "/dev/null"}) {
		t.Error("tee -a /dev/null must not defer")
	}
	if !teeDefers([]string{"out.txt"}) {
		t.Error("tee out.txt must defer")
	}
	// jq: -i defers.
	if jqDefers([]string{".foo", "file"}) {
		t.Error("jq .foo must not defer")
	}
	if !jqDefers([]string{"-i", ".foo", "file"}) {
		t.Error("jq -i must defer")
	}
}
