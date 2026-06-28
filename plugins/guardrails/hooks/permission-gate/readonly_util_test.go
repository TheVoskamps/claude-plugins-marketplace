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

// TestAlwaysReadOnlyWriteFormsNotAllowed_31 covers the #31 review HIGH finding:
// always-read-only path-bearing utilities that have a write-capable flag or a
// write-destination operand must NOT ride the ALLOW track. Each form here writes
// a file in the repo (the common case containment does NOT catch), so it must
// defer to the in-repo-write classifier rather than auto-allow.
func TestAlwaysReadOnlyWriteFormsNotAllowed_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file", "README.md", "out.txt", "clobber.txt")
	for _, cmd := range []string{
		// sort -o / --output writes a file (sort -o f f clobbers in place).
		`sort -o out.txt README.md`,
		`sort --output=out.txt README.md`,
		`sort -o README.md README.md`,
		// uniq INPUT OUTPUT: the second path operand is a WRITE destination.
		`uniq README.md clobber.txt`,
		`uniq -c README.md clobber.txt`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("write-capable always-read-only form must not ALLOW: %q got %q", cmd, d.Bucket)
		}
		wantBucket(t, d, BucketDefer, "write form defers: "+cmd)
	}
}

// TestAlwaysReadOnlyUnknownFlagDefers_31 covers the #31 review HIGH finding's
// criterion-4 generalization: an unrecognized flag on an ALWAYS-read-only
// utility must fail safe (defer), not allow — previously these utilities carried
// no flag inspection at all, so `sort --frobnicate file` rode the ALLOW track.
func TestAlwaysReadOnlyUnknownFlagDefers_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file")
	for _, cmd := range []string{
		`sort --frobnicate file`,
		`uniq --frobnicate file`,
		`cat --frobnicate file`,
		`head --frobnicate file`,
		`wc --frobnicate file`,
		`cut --frobnicate file`,
		`comm --frobnicate file`,
		`paste --frobnicate file`,
		`nl --frobnicate file`,
		`fold --frobnicate file`,
		`fmt --frobnicate file`,
		`column --frobnicate file`,
		`rev --frobnicate file`,
		`realpath --frobnicate file`,
		`grep --frobnicate x file`,
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("unknown flag on always-read-only utility must not ALLOW (fail-safe): %q got %q", cmd, d.Bucket)
		}
		wantBucket(t, d, BucketDefer, "unknown flag defers: "+cmd)
	}
}

// TestAlwaysReadOnlyReadFormsStillAllow_31 guards against over-correction: the
// genuinely read-only forms of every always-read-only utility — including the
// common flag forms — must STILL ALLOW after the write-form/fail-safe tightening.
func TestAlwaysReadOnlyReadFormsStillAllow_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file", "a", "b", "README.md")
	for _, cmd := range []string{
		`sort -r file`,
		`sort -k2,3 -t: file`,
		`sort -u file`,
		`uniq file`,    // single (input-only) operand is read-only
		`uniq -c file`, // count flag, single operand
		`uniq -D file`, // -D is a bool flag, not a value flag swallowing the path
		`cat -n file`,
		`head -n 5 file`,
		`head -n5 file`, // attached value
		`tail -c 10 file`,
		`wc -lwc file`, // clustered bool flags
		`cut -d: -f1 file`,
		`cut -f1 file`,
		`comm -12 a b`,
		`paste -d, a b`,
		`nl -ba file`,
		`fold -w 80 file`,
		`fmt -w 72 file`,
		`column -t -s, file`,
		`rev file`,
		`realpath -e file`,
		`grep -i -n needle file`,
		`grep -e needle -e other file`,
	} {
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketAllow, "read-only form still allows: "+cmd)
	}
}

// TestClusteredReadOnlyShortFlagsAllow_31 covers the round-2 review MEDIUM
// regression: the round-1 binary (09bd8e7) ALLOWed clustered read-only short
// flags on every always-read-only utility, but the round-1 fix (e24a135) added
// per-utility flagScan predicates that only set clusterable on cat/wc/tr/comm —
// so very high-frequency forms the issue targets (grep -rn, sort -rn, uniq -cd,
// cut -sf1) began to DEFER. Enabling clusterable on the read-only-only-flag
// specs restores them. Each form below is an all-bool cluster (or a bool cluster
// with a trailing value flag) with NO write flag, so it must ALLOW.
func TestClusteredReadOnlyShortFlagsAllow_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file", "a", "b")
	for _, cmd := range []string{
		// grep: the headline form. -rn = -r -n, -in = -i -n, -rin = -r -i -n.
		`grep -rn needle file`,
		`grep -in needle file`,
		`grep -rin needle file`,
		`grep -lc needle file`,
		// sort: -rn = -r -n, -ru = -r -u, -bn = -b -n (all bool, no -o).
		`sort -rn file`,
		`sort -ru file`,
		`sort -bn file`,
		// uniq: -cd = -c -d, -ci = -c -i (all bool; single read operand).
		`uniq -cd file`,
		`uniq -ci file`,
		// cut: -sf1 = -s (bool) + -f1 (value flag with attached value).
		`cut -sf1 file`,
		`cut -sn file`,
		// nl/fold/fmt/paste/column/realpath clustered bool forms.
		`fmt -cs file`,
		`fold -bs file`,
		`realpath -em file`,
		`comm -123 a b`,
	} {
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketAllow, "clustered read-only short flags allow: "+cmd)
	}
}

// TestClusteredWriteFlagStillDefers_31 is the load-bearing safety guard for the
// round-2 fix: enabling clusterable on sort (whose -o writes a file) must NOT
// let a write-capable flag ride through a cluster. `sort -ro file` (where -o
// would consume `file` as a write target) and every other cluster containing a
// write flag MUST still defer. This guards against the regression's fix opening
// a write hole.
func TestClusteredWriteFlagStillDefers_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file")
	for _, cmd := range []string{
		`sort -ro file`, // -o inside the cluster writes file → must defer
		`sort -or file`, // -o leading the cluster → must defer
		`sort -uo file`, // -u (bool) + -o (write) → must defer
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("cluster containing a write flag must not ALLOW: %q got %q", cmd, d.Bucket)
		}
		wantBucket(t, d, BucketDefer, "clustered write flag defers: "+cmd)
	}
}

// TestClusterIsReadOnlyHelper_31 exercises clusterIsReadOnly directly: all-bool
// clusters and a trailing value flag are read-only; a write flag anywhere in the
// cluster (or an unknown char) is not.
func TestClusterIsReadOnlyHelper_31(t *testing.T) {
	bools := map[string]bool{"-r": true, "-n": true, "-i": true, "-s": true, "-u": true}
	values := map[string]bool{"-f": true, "-k": true}
	writes := map[string]bool{"-o": true}

	for _, a := range []string{"-rn", "-rin", "-sf1", "-f1", "-u"} {
		if !clusterIsReadOnly(a, bools, values, writes) {
			t.Errorf("cluster %q must be read-only", a)
		}
	}
	for _, a := range []string{
		"-ro", // -o writes
		"-or", // -o leads
		"-uo", // -u bool then -o write
		"-rx", // -x unknown
		"-x",  // unknown
	} {
		if clusterIsReadOnly(a, bools, values, writes) {
			t.Errorf("cluster %q must NOT be read-only (write flag or unknown char)", a)
		}
	}
}

// TestAwkProfileOutputDumpNotAllowed_31 covers the #31 review MEDIUM finding:
// gawk's profile/pretty-print/dump-variables flags write a file (awkprof.out /
// awkvars.out) and must NOT ALLOW. They were previously listed as read-only
// boolFlags. Bare, attached, and long-with-value forms all defer.
func TestAwkProfileOutputDumpNotAllowed_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file", "prof")
	for _, cmd := range []string{
		`awk -p prof '{print}' file`, // bare -p writes awkprof.out; "prof" is program text
		`awk -p '{print}' file`,
		`awk -o '{print}' file`,
		`awk -d '{print}' file`,
		`awk --profile '{print}' file`,
		`awk --pretty-print '{print}' file`,
		`awk --dump-variables '{print}' file`,
		`awk -pprof.out '{print}' file`,         // attached short form
		`awk --profile=prof.out '{print}' file`, // long-with-value form
	} {
		d := classifyBash(cmd, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("awk file-writing flag must not ALLOW: %q got %q", cmd, d.Bucket)
		}
		wantBucket(t, d, BucketDefer, "awk write flag defers: "+cmd)
	}
}

// TestAwkNonWritingFlagsStillAllow_31 guards the MEDIUM fix against
// over-correction: gawk flags that do NOT write a file (-O/--optimize,
// -P/--posix, -D/--debug) must STILL ALLOW.
func TestAwkNonWritingFlagsStillAllow_31(t *testing.T) {
	ev, _ := inRepoEvent(t, "file")
	for _, cmd := range []string{
		`awk -O '{print}' file`,
		`awk --optimize '{print}' file`,
		`awk -P '{print}' file`,
		`awk --posix '{print}' file`,
		`awk '{print $1}' file`,
		`awk -F: '{print $1}' file`,
	} {
		wantBucket(t, classifyBash(cmd, ev), BucketAllow, "awk non-writing flag allows: "+cmd)
	}
}

// TestAwkDefersHelper_31 exercises awkDefers directly for the write/non-write
// flag distinction (MEDIUM finding).
func TestAwkDefersHelper_31(t *testing.T) {
	for _, a := range [][]string{
		{"-p", "{print}", "file"},
		{"-o", "{print}", "file"},
		{"-d", "{print}", "file"},
		{"--profile", "{print}", "file"},
		{"--pretty-print", "{print}", "file"},
		{"--dump-variables", "{print}", "file"},
		{"-pprof.out", "{print}", "file"},
		{"--profile=prof.out", "{print}", "file"},
	} {
		if !awkDefers(a) {
			t.Errorf("awk write flag must defer: %v", a)
		}
	}
	for _, a := range [][]string{
		{"-O", "{print}", "file"},
		{"--optimize", "{print}", "file"},
		{"-P", "{print}", "file"},
		{"--posix", "{print}", "file"},
		{"-F", ":", "{print}", "file"},
	} {
		if awkDefers(a) {
			t.Errorf("awk non-writing flag must not defer: %v", a)
		}
	}
}

// TestSortUniqDefersHelpers_31 exercises sortDefers/uniqDefers directly for the
// write-flag and write-operand detection (HIGH finding).
func TestSortUniqDefersHelpers_31(t *testing.T) {
	// sort: -o / --output write a file → defer; read-only flags do not.
	if !sortDefers([]string{"-o", "out.txt", "file"}) {
		t.Error("sort -o must defer")
	}
	if !sortDefers([]string{"--output=out.txt", "file"}) {
		t.Error("sort --output= must defer")
	}
	if !sortDefers([]string{"--frobnicate", "file"}) {
		t.Error("sort unknown flag must defer (fail-safe)")
	}
	if sortDefers([]string{"-r", "-k2,3", "-t:", "file"}) {
		t.Error("sort read-only flags must not defer")
	}
	// uniq: a second (OUTPUT) operand defers; one operand does not.
	if !uniqDefers([]string{"in.txt", "out.txt"}) {
		t.Error("uniq IN OUT must defer (OUT is a write destination)")
	}
	if !uniqDefers([]string{"-c", "in.txt", "out.txt"}) {
		t.Error("uniq -c IN OUT must defer")
	}
	if uniqDefers([]string{"in.txt"}) {
		t.Error("uniq IN (input only) must not defer")
	}
	if uniqDefers([]string{"-D", "in.txt"}) {
		t.Error("uniq -D IN must not defer (-D is a bool flag, not a value flag)")
	}
	if !uniqDefers([]string{"--frobnicate", "file"}) {
		t.Error("uniq unknown flag must defer (fail-safe)")
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
