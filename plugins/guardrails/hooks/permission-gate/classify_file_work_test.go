package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// fileWorkConfig installs a fixture home for the test and, unless body is
// empty, writes body as its ~/.config/guardrails/config.yml. Git is detached
// from the driving machine's global and system config, which a relocated home
// would otherwise make it read through.
func fileWorkConfig(t *testing.T, body string) string {
	t.Helper()
	home := filepath.Join(t.TempDir(), "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_SYSTEM", os.DevNull)
	t.Setenv("HOME", home)
	if body != "" {
		writeCarveOutConfig(t, home, body)
	}
	return home
}

// fileWorkModeConfig is a config body that stamps the current schema and sets the
// redirect to mode.
func fileWorkModeConfig(mode string) string {
	return "schema-version: 2\nredirect-bash-file-work: " + mode + "\n"
}

// fileWorkRepo builds a plain repository to run events in.
func fileWorkRepo(t *testing.T) string {
	t.Helper()
	repo := filepath.Join(t.TempDir(), "repo")
	gitInit(t, repo)
	return canonicalize(repo)
}

// fileWorkEvent is a Bash PreToolUse event run in cwd by agentType.
func fileWorkEvent(cwd, agentType string) *Event {
	return &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: agentType}
}

// verdictsWithoutConfig classifies each command in cwd with no operator config
// file — the verdict each gets with the redirect off — and leaves the test's
// home as it found it.
func verdictsWithoutConfig(t *testing.T, cwd string, agentType string, cmds []string) map[string]Decision {
	t.Helper()
	home := os.Getenv("HOME")
	fileWorkConfig(t, "")
	out := map[string]Decision{}
	for _, cmd := range cmds {
		out[cmd] = classifyBash(cmd, fileWorkEvent(cwd, agentType))
	}
	t.Setenv("HOME", home)
	return out
}

// coveredShapes are lines the redirect denies, with the operation each earns.
var coveredShapes = []struct {
	cmd string
	op  string
}{
	{"cat f.txt", "bash-file-work:read"},
	{"head -n 5 f.txt", "bash-file-work:read"},
	{"tail -n 20 f.txt", "bash-file-work:read"},
	{"tail -f f.txt", "bash-file-work:read"},
	{"tail -F f.txt", "bash-file-work:read"},
	{"sed -n '1,5p' f.txt", "bash-file-work:read"},
	{"nl -ba f.txt", "bash-file-work:read"},
	{"less f.txt", "bash-file-work:read"},
	{"less -p pattern f.txt", "bash-file-work:read"},
	{"less +G f.txt", "bash-file-work:read"},
	{"less --wheel-lines 2 f.txt", "bash-file-work:read"},
	{"less --pat x f.txt", "bash-file-work:read"},
	{"tail +2 f.txt", "bash-file-work:read"},
	{"sed -n -l 5 '1p' f.txt", "bash-file-work:read"},
	{"sed --qui '1p' f.txt", "bash-file-work:read"},
	{"sed -n -e -i p f.txt", "bash-file-work:read"},
	{"cat f.txt && make", "bash-file-work:read"},
	{"cat a.txt; cat b.txt", "bash-file-work:read"},
	{"cat f.txt | cat", "bash-file-work:read"},
	{"cat f.txt | head", "bash-file-work:read"},
	{"sed -i 's/a/b/' f.txt", "bash-file-work:edit"},
	{"sed -i.bak -e 's/a/b/' f.txt", "bash-file-work:edit"},
	{"sed --in-place 's/a/b/' f.txt", "bash-file-work:edit"},
	{"sed -I '' 's/a/b/' f.txt", "bash-file-work:edit"},
	{"sed -i '' 's/a/b/' f.txt", "bash-file-work:edit"},
	{"sed -I '' '/x/d' f.txt", "bash-file-work:edit"},
	{"sed --in 's/a/b/' f.txt", "bash-file-work:edit"},
	{"sed -ni 's/a/b/p' f.txt", "bash-file-work:edit"},
	{"sed -Ei 's/a+/b/' f.txt", "bash-file-work:edit"},
	{"sed -i -f s.sed f.txt", "bash-file-work:edit"},
	{"sed -i 's/a/b/e' f.txt", "bash-file-work:edit"},
	{"sed -n -f s.sed f.txt", "bash-file-work:read"},
	{"sed -n '1e date' f.txt", "bash-file-work:read"},
	{"cat f.txt | sed -n -f s.sed", "bash-file-work:read"},
	{"perl -pi -e 's/a/b/' f.txt", "bash-file-work:edit"},
	{"perl -i -pe 's/a/b/' f.txt", "bash-file-work:edit"},
	{"make && sed -i 's/a/b/' f.txt", "bash-file-work:edit"},
	{"grep -l x . | sed -i 's/a/b/' f.txt", "bash-file-work:edit"},
	{"sed -i 's/a/b/' f.txt | sort", "bash-file-work:edit"},
	{"echo x > f.txt", "bash-file-work:write"},
	{"printf x >> f.txt", "bash-file-work:write"},
	{"cat <<'EOF' > f.txt\nx\nEOF", "bash-file-work:write"},
	{"cat > f.txt <<EOF\nx\nEOF", "bash-file-work:write"},
	{"tee f.txt <<'EOF'\nx\nEOF", "bash-file-work:write"},
	{"tee -a f.txt <<'EOF' >/dev/null\nx\nEOF", "bash-file-work:write"},
	{"cat <<'EOF' | tee f.txt\nx\nEOF", "bash-file-work:write"},
	{"cat <<'EOF' | tee -a f.txt >/dev/null\nx\nEOF", "bash-file-work:write"},
}

// coveredCmds is the command text of every covered shape.
func coveredCmds() []string {
	out := make([]string, len(coveredShapes))
	for i, c := range coveredShapes {
		out[i] = c.cmd
	}
	return out
}

// uncoveredShapes are lines the redirect never denies.
var uncoveredShapes = []string{
	"make 2>&1 | tail -20",
	"ls | head",
	"ls | head -n 5",
	"ls | tail -n 20",
	"ls | nl -ba",
	"make | less -p pattern",
	"make | less +G",
	"make | less --wheel-lines 2",
	"make | less --wheel-lines=2",
	"make | less --header 1",
	"make | less --intr x",
	"make | less --rscroll -",
	"make | less --line-num-width 3",
	"make | less --match-shift 2",
	"make | less --modelines 5",
	"make | less --status-col-width 2",
	"make | less --search-options W",
	"make | less --pat x",
	"make | less --rs x",
	"make | less -x 4",
	"make | less -z -4",
	"make | tail +2",
	"make | sed -n -l 5 '1p'",
	"cat <<EOF | wc -l\nx\nEOF",
	"head -n 5 f.txt | sort",
	"cat f.txt | jq .",
	"cat f.txt | sed 's/a/b/'",
	"make > build.log 2>&1",
	"go test ./... > out.txt",
	"ls 2> errors.txt",
	"echo x > /dev/null",
	"echo x >&2",
	"echo x 2>&1",
	"printf x 1>&2",
	"ls | tee out.txt",
	"echo x | tee out.txt",
	"cat <<EOF | tee /dev/null\nx\nEOF",
	"tee /dev/null <<EOF\nx\nEOF",
	"grep -rn x .",
	"find . -name '*.go'",
	"ls -la",
	"sed 's/a/b/' f.txt",
	"sed -f s.sed f.txt",
	"sed 's/a/b/e' f.txt",
	"cat",
	"cat -",
	"echo hi",
	"x=$(cat f.txt | jq .)",
}

// Under `always`, every covered shape is denied with a reason naming its tool,
// and no uncovered shape is denied by the redirect.
func TestFileWorkAlways(t *testing.T) {
	repo := fileWorkRepo(t)
	fileWorkConfig(t, fileWorkModeConfig("always"))
	t.Chdir(repo)

	tools := map[string]string{
		"bash-file-work:read":  "Read tool",
		"bash-file-work:edit":  "Edit tool",
		"bash-file-work:write": "Write tool",
	}
	for _, c := range coveredShapes {
		d := classifyBash(c.cmd, fileWorkEvent(repo, "main"))
		if d.Bucket != BucketDeny || d.Operation != c.op {
			t.Errorf("%q: got %q/%q (%q), want deny/%q", c.cmd, d.Bucket, d.Operation, d.Reason, c.op)
			continue
		}
		if !strings.Contains(d.Reason, tools[c.op]) {
			t.Errorf("%q: the reason does not name the %s; got %q", c.cmd, tools[c.op], d.Reason)
		}
		if !strings.Contains(d.Reason, redirectBashFileWorkKey) {
			t.Errorf("%q: the reason does not name the setting; got %q", c.cmd, d.Reason)
		}
	}
	for _, cmd := range uncoveredShapes {
		d := classifyBash(cmd, fileWorkEvent(repo, "main"))
		if strings.HasPrefix(d.Operation, "bash-file-work:") {
			t.Errorf("%q: denied by the redirect (%q), want no redirect", cmd, d.Reason)
		}
	}
}

// Under `off`, with the key absent, with the key given an empty value, with the
// file stamped below the pin or not at all, and with no config file, every
// covered shape gets the verdict the line gets with no config file.
func TestFileWorkOffIsTodaysVerdict(t *testing.T) {
	repo := fileWorkRepo(t)
	t.Chdir(repo)
	today := verdictsWithoutConfig(t, repo, "main", coveredCmds())
	for _, cfg := range []struct{ name, body string }{
		{"off", fileWorkModeConfig("off")},
		{"key absent", "schema-version: 2\n"},
		{"empty value", "schema-version: 2\nredirect-bash-file-work:\n"},
		{"below the pin", "schema-version: 1\nredirect-bash-file-work: always\n"},
		{"unstamped", "redirect-bash-file-work: always\n"},
		{"no file", ""},
	} {
		t.Run(cfg.name, func(t *testing.T) {
			fileWorkConfig(t, cfg.body)
			for _, c := range coveredShapes {
				got := classifyBash(c.cmd, fileWorkEvent(repo, "main"))
				if want := today[c.cmd]; got != want {
					t.Errorf("%q: got %+v, want today's %+v", c.cmd, got, want)
				}
				if strings.HasPrefix(got.Operation, "bash-file-work:") {
					t.Errorf("%q: denied by the redirect while it is off", c.cmd)
				}
			}
		})
	}
}

// Under `worktree`, the redirect fires in a linked worktree and not in the
// primary clone, whatever the event's agent type.
func TestFileWorkWorktreeMode(t *testing.T) {
	primary, wt := setupWorktree(t)
	agents := []string{"main", "issue-developer", ""}
	today := map[string]map[string]Decision{}
	for _, agent := range agents {
		today[agent] = verdictsWithoutConfig(t, primary, agent, coveredCmds())
	}
	fileWorkConfig(t, fileWorkModeConfig("worktree"))
	for _, agent := range agents {
		for _, c := range coveredShapes {
			d := classifyBash(c.cmd, fileWorkEvent(wt, agent))
			if d.Bucket != BucketDeny || d.Operation != c.op {
				t.Errorf("worktree, agent %q, %q: got %q/%q, want deny/%q", agent, c.cmd, d.Bucket, d.Operation, c.op)
			}
			got := classifyBash(c.cmd, fileWorkEvent(primary, agent))
			if want := today[agent][c.cmd]; got != want {
				t.Errorf("primary, agent %q, %q: got %+v, want today's %+v", agent, c.cmd, got, want)
			}
		}
	}

	// A cwd that resolves to no repository does not fire.
	d := classifyBash("cat f.txt", fileWorkEvent(t.TempDir(), "issue-developer"))
	if strings.HasPrefix(d.Operation, "bash-file-work:") {
		t.Errorf("no repository: denied by the redirect (%q)", d.Reason)
	}

	// A primary clone whose git directory is elsewhere does not fire; a linked
	// worktree of one does.
	l := primaryCloneLayouts(t)
	for _, cwd := range []string{l.submodule, l.separate} {
		if d := classifyBash("cat f.txt", fileWorkEvent(cwd, "issue-developer")); strings.HasPrefix(d.Operation,
			"bash-file-work:") {
			t.Errorf("primary clone %s: denied by the redirect (%q)", cwd, d.Reason)
		}
	}
	for _, cwd := range []string{l.submoduleWorktree, l.separateWorktree} {
		if d := classifyBash("cat f.txt", fileWorkEvent(cwd, "issue-developer")); d.Operation !=
			"bash-file-work:read" {
			t.Errorf("linked worktree %s: got %q/%q, want deny/bash-file-work:read", cwd, d.Bucket, d.Operation)
		}
	}
}

// A line another rule denies keeps that rule's reason, wherever in the line
// that deny sits relative to the covered command.
func TestFileWorkKeepsOtherDeny(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	root := canonicalize(repo)
	sib := filepath.Join(canonicalize(sibling), "x.txt")
	cmds := []string{
		"cat " + sib,
		"git -C /tmp log; cat f.txt",
		"sed -i 's/a/b/' " + sib,
		"cat f.txt; cat " + sib,
		"echo x > f.txt; gh auth switch",
	}
	t.Chdir(root)
	today := verdictsWithoutConfig(t, root, "main", cmds)
	fileWorkConfig(t, fileWorkModeConfig("always"))

	for _, cmd := range cmds {
		want := today[cmd]
		if want.Bucket != BucketDeny {
			t.Fatalf("%q: the control must be denied by another rule; got %q", cmd, want.Bucket)
		}
		got := classifyBash(cmd, fileWorkEvent(root, "main"))
		if got != want {
			t.Errorf("%q: got %+v, want the other rule's %+v", cmd, got, want)
		}
	}
}

// The redirect's deny outranks an ask and a defer elsewhere in the line.
func TestFileWorkOutranksAskAndDefer(t *testing.T) {
	repo := fileWorkRepo(t)
	t.Chdir(repo)
	cmds := map[string]Bucket{
		"cat f.txt; gh auth token": BucketAsk,
		"cat f.txt; npm test":      BucketDefer,
	}
	list := make([]string, 0, len(cmds))
	for cmd := range cmds {
		list = append(list, cmd)
	}
	today := verdictsWithoutConfig(t, repo, "main", list)
	fileWorkConfig(t, fileWorkModeConfig("always"))
	for cmd, bucket := range cmds {
		if today[cmd].Bucket != bucket {
			t.Fatalf("%q: the control must be %q with the redirect off; got %q", cmd, bucket, today[cmd].Bucket)
		}
		if d := classifyBash(cmd, fileWorkEvent(repo, "main")); d.Operation != "bash-file-work:read" {
			t.Errorf("%q: got %q/%q, want the redirect's deny", cmd, d.Bucket, d.Operation)
		}
	}
}

// A sed that takes a script file, or whose script runs a shell command or
// cannot be read whole, is deferred with the redirect off, and with it on unless
// the redirect covers it, which then denies it with its own redirect; a file it
// names that escapes the repository is still denied by containment either way.
func TestSedOpaqueDefersOnEveryTrack(t *testing.T) {
	repo := fileWorkRepo(t)
	gitInit(t, filepath.Join(filepath.Dir(repo), "sibling"))
	t.Chdir(repo)
	redirected := map[string]string{
		"sed -n -f s.sed f.txt":             "bash-file-work:read",
		"sed -n --fi=s.sed f.txt":           "bash-file-work:read",
		"sed -i -f s.sed f.txt":             "bash-file-work:edit",
		"sed -i --file s.sed f.txt":         "bash-file-work:edit",
		"sed -n '1e date' f.txt":            "bash-file-work:read",
		"sed -i 's/a/b/e' f.txt":            "bash-file-work:edit",
		"sed -i '1e date' f.txt":            "bash-file-work:edit",
		"sed -n 's/a/b/e' f.txt | cat":      "bash-file-work:read",
		"cat f.txt | sed -n -f s.sed":       "bash-file-work:read",
		"sed -n ':a e echo EXECUTED' f.txt": "bash-file-work:read",
		"sed -n 'b a e id' f.txt":           "bash-file-work:read",
		"sed -n 't a e id' f.txt":           "bash-file-work:read",
		"sed -n ':a s/x/y/e' f.txt":         "bash-file-work:read",
		"sed -n ':a e;p' f.txt":             "bash-file-work:read",
	}
	deferred := []string{
		"sed -f s.sed f.txt",
		"sed 's/a/b/e' f.txt",
		"sed ':a e echo EXECUTED' f.txt",
		"sed 'b a e id' f.txt",
	}
	denied := []string{
		"sed -i -f s.sed ../sibling/f.txt",
		"sed -n -f ../sibling/s.sed f.txt",
		"sed -n '1e date' ../sibling/f.txt",
		"sed -i 's/a/b/e' ../sibling/f.txt",
	}
	for _, mode := range []string{"", fileWorkModeConfig("always")} {
		fileWorkConfig(t, mode)
		for _, cmd := range deferred {
			if d := classifyBash(cmd, fileWorkEvent(repo, "main")); d.Bucket != BucketDefer {
				t.Errorf("config %q, %q: got %q/%q (%q), want defer", mode, cmd, d.Bucket, d.Operation, d.Reason)
			}
		}
		for cmd, op := range redirected {
			d := classifyBash(cmd, fileWorkEvent(repo, "main"))
			switch {
			case mode == "" && d.Bucket != BucketDefer:
				t.Errorf("config %q, %q: got %q/%q (%q), want defer", mode, cmd, d.Bucket, d.Operation, d.Reason)
			case mode != "" && (d.Bucket != BucketDeny || d.Operation != op):
				t.Errorf("config %q, %q: got %q/%q (%q), want deny/%q", mode, cmd, d.Bucket, d.Operation, d.Reason,
					op)
			}
		}
		for _, cmd := range denied {
			d := classifyBash(cmd, fileWorkEvent(repo, "main"))
			if d.Bucket != BucketDeny || strings.HasPrefix(d.Operation, "bash-file-work:") {
				t.Errorf("config %q, %q: got %q/%q (%q), want a containment deny", mode, cmd, d.Bucket,
					d.Operation, d.Reason)
			}
		}
	}
}

// runGitT runs git with args and fails the test on an error.
func runGitT(t *testing.T, args ...string) {
	t.Helper()
	if out, err := exec.Command("git", args...).CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// cloneLayouts are the two primary clones whose git directory is not at
// <root>/.git — a submodule checkout, and a clone made with --separate-git-dir
// — and a linked worktree of each, every path canonical.
type cloneLayouts struct {
	submodule, submoduleWorktree, separate, separateWorktree string
	// submoduleGitDir is the submodule's common git directory, and
	// separateGitDir the separate clone's.
	submoduleGitDir, separateGitDir string
}

// primaryCloneLayouts builds the cloneLayouts.
func primaryCloneLayouts(t *testing.T) cloneLayouts {
	t.Helper()
	base := t.TempDir()
	super := filepath.Join(base, "super")
	gitInit(t, super)
	upstream := filepath.Join(base, "upstream")
	gitInit(t, upstream)
	runGitT(t, "-C", super, "-c", "protocol.file.allow=always", "submodule", "add", "-q", upstream, "sub")
	submodule := filepath.Join(super, "sub")
	submoduleWorktree := filepath.Join(base, "sub-wt")
	runGitT(t, "-C", submodule, "worktree", "add", "-q", "--detach", submoduleWorktree)

	separate := filepath.Join(base, "separate")
	separateGitDir := filepath.Join(base, "separate.git")
	runGitT(t, "init", "-q", "--separate-git-dir", separateGitDir, separate)
	runGitT(t, "-C", separate, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
		"commit", "-q", "--allow-empty", "-m", "init")
	separateWorktree := filepath.Join(base, "separate-wt")
	runGitT(t, "-C", separate, "worktree", "add", "-q", "--detach", separateWorktree)
	return cloneLayouts{
		submodule:         canonicalize(submodule),
		submoduleWorktree: canonicalize(submoduleWorktree),
		separate:          canonicalize(separate),
		separateWorktree:  canonicalize(separateWorktree),
		submoduleGitDir:   canonicalize(filepath.Join(super, ".git", "modules", "sub")),
		separateGitDir:    canonicalize(separateGitDir),
	}
}

// isLinkedWorktree tells a linked worktree's context from a primary clone's,
// whether the primary clone keeps its git directory at its root or elsewhere.
func TestRepoContextIsLinkedWorktree(t *testing.T) {
	primary, wt := setupWorktree(t)
	l := primaryCloneLayouts(t)
	for _, c := range []struct {
		cwd  string
		want bool
	}{
		{primary, false},
		{wt, true},
		{l.submodule, false},
		{l.separate, false},
		{l.submoduleWorktree, true},
		{l.separateWorktree, true},
	} {
		rc, err := resolveRepoContext(c.cwd)
		if err != nil {
			t.Fatalf("resolveRepoContext(%s): %v", c.cwd, err)
		}
		if got := rc.isLinkedWorktree(); got != c.want {
			t.Errorf("isLinkedWorktree() at %s = %v, want %v", c.cwd, got, c.want)
		}
	}
}

// primaryClone is the primary clone's root in every layout git records one
// for, and empty for a linked worktree of a --separate-git-dir clone, for which
// git records none.
func TestRepoContextPrimaryClone(t *testing.T) {
	primary, wt := setupWorktree(t)
	primary, wt = canonicalize(primary), canonicalize(wt)
	l := primaryCloneLayouts(t)
	for _, c := range []struct{ cwd, want string }{
		{primary, primary},
		{wt, primary},
		{l.submodule, l.submodule},
		{l.submoduleWorktree, l.submodule},
		{l.separate, l.separate},
		{l.separateWorktree, ""},
	} {
		rc, err := resolveRepoContext(c.cwd)
		if err != nil {
			t.Fatalf("resolveRepoContext(%s): %v", c.cwd, err)
		}
		if rc.primaryClone != c.want {
			t.Errorf("primaryClone at %s = %q, want %q", c.cwd, rc.primaryClone, c.want)
		}
	}
}

// From a linked worktree of a submodule or a --separate-git-dir clone, the
// worktree-escape check holds the primary clone and the common git directory,
// and nothing beside them: a path next to the common git directory is another
// repository.
func TestWorktreeEscapeInPrimaryCloneLayouts(t *testing.T) {
	fileWorkConfig(t, "")
	l := primaryCloneLayouts(t)
	for _, c := range []struct {
		cwd, target string
		want        containmentResult
	}{
		{l.submoduleWorktree, filepath.Join(l.submodule, "f.txt"), escapeWorktree},
		{l.submoduleWorktree, filepath.Join(l.submoduleGitDir, "config"), escapeWorktree},
		{l.submoduleWorktree, filepath.Join(filepath.Dir(l.submoduleGitDir), "other", "config"), escapeRepo},
		{l.separateWorktree, filepath.Join(l.separateGitDir, "config"), escapeWorktree},
		{l.separateWorktree, filepath.Join(filepath.Dir(l.separateGitDir), "other", "f.txt"), escapeRepo},
		{l.submodule, filepath.Join(filepath.Dir(l.submoduleGitDir), "other", "config"), escapeRepo},
		{l.separate, filepath.Join(filepath.Dir(l.separateGitDir), "other", "f.txt"), escapeRepo},
	} {
		rc, err := resolveRepoContext(c.cwd)
		if err != nil {
			t.Fatalf("resolveRepoContext(%s): %v", c.cwd, err)
		}
		if got, _, _ := testContainmentFrom(c.target, c.cwd, rc, true, false, false, nil); got != c.want {
			t.Errorf("from %s, %s: got %v, want %v", c.cwd, c.target, got, c.want)
		}
	}
}

// The loader reads each mode, treats everything else as off, and has a warning
// only for a value that is present and not a mode.
func TestLoadRedirectBashFileWork(t *testing.T) {
	fileWorkConfig(t, "")
	dir := t.TempDir()
	for _, c := range []struct {
		name string
		body string
		want fileWorkMode
		warn bool
	}{
		{"always", fileWorkModeConfig("always"), fileWorkAlways, false},
		{"worktree", fileWorkModeConfig("worktree"), fileWorkWorktree, false},
		{"off", fileWorkModeConfig("off"), fileWorkOff, false},
		{"quoted off", fileWorkModeConfig(`"off"`), fileWorkOff, false},
		{"null", fileWorkModeConfig(""), fileWorkOff, false},
		{"absent", "schema-version: 2\n", fileWorkOff, false},
		{"below the pin", "schema-version: 1\nredirect-bash-file-work: sometimes\n", fileWorkOff, false},
		{"unknown", fileWorkModeConfig("sometimes"), fileWorkOff, true},
		{"wrong case", fileWorkModeConfig("Always"), fileWorkOff, true},
		{"boolean", fileWorkModeConfig("true"), fileWorkOff, true},
		{"sequence", fileWorkModeConfig("[always]"), fileWorkOff, true},
	} {
		path := filepath.Join(dir, c.name+".yml")
		if err := os.WriteFile(path, []byte(c.body), 0o644); err != nil {
			t.Fatal(err)
		}
		cfg, err := loadOperatorConfigFrom(path)
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		if cfg.fileWork != c.want {
			t.Errorf("%s: got %q, want %q", c.name, cfg.fileWork, c.want)
		}
		if gotWarn := cfg.fileWorkWarning != ""; gotWarn != c.warn {
			t.Errorf("%s: warned %v (%q), want %v", c.name, gotWarn, cfg.fileWorkWarning, c.warn)
		}
		if c.warn && !strings.Contains(cfg.fileWorkWarning, redirectBashFileWorkKey) {
			t.Errorf("%s: the warning does not name the key; got %q", c.name, cfg.fileWorkWarning)
		}
	}

	cfg, err := loadOperatorConfigFrom(filepath.Join(dir, "missing.yml"))
	if err != nil || cfg.fileWork != fileWorkOff || cfg.fileWorkWarning != "" {
		t.Errorf("missing file: got %q with warning %q and error %v, want off, no warning and no error",
			cfg.fileWork, cfg.fileWorkWarning, err)
	}
}

// An unknown value leaves every covered shape at the verdict it gets with no
// config file, and the warning lands in the gate's own log.
func TestFileWorkUnknownValueIsOff(t *testing.T) {
	repo := fileWorkRepo(t)
	t.Chdir(repo)
	today := verdictsWithoutConfig(t, repo, "main", coveredCmds())
	fileWorkConfig(t, fileWorkModeConfig("sometimes"))
	logFile := filepath.Join(t.TempDir(), "gate.jsonl")
	t.Setenv(logEnvVar, logFile)
	for _, c := range coveredShapes {
		got := classifyBash(c.cmd, fileWorkEvent(repo, "main"))
		if want := today[c.cmd]; got != want {
			t.Errorf("%q: got %+v, want today's %+v", c.cmd, got, want)
		}
	}
	raw, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("the warning was not logged: %v", err)
	}
	if !strings.Contains(string(raw), `"bucket":"warning"`) || !strings.Contains(string(raw), "sometimes") {
		t.Errorf("the log carries no warning naming the value; got %s", raw)
	}
}

// The carve-out keeps loading when the redirect's value is malformed.
func TestFileWorkBadValueKeepsCarveOut(t *testing.T) {
	base := t.TempDir()
	home := carveOutFixture(t, base, "plain")
	writeCarveOutConfig(t, home, carveOutConfig+"redirect-bash-file-work: [always]\n")
	cfg, err := loadOperatorConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.carveOut.empty() {
		t.Error("a malformed redirect-bash-file-work value withdrew the carve-out")
	}
}

// A config file that exists but cannot be parsed denies every gated tool call,
// whatever the tool, naming the file from the home directory rather than by
// its absolute path.
func TestUnusableConfigDeniesEveryCall(t *testing.T) {
	repo := fileWorkRepo(t)
	home := fileWorkConfig(t, "redirect-bash-file-work: [\n")
	for _, ev := range []*Event{
		fileWorkEvent(repo, "main"),
		{HookEventName: "PreToolUse", ToolName: "Bash", CWD: repo, ToolInput: []byte(`{"command":"ls"}`)},
		{HookEventName: "PreToolUse", ToolName: "Read", CWD: repo,
			ToolInput: []byte(`{"file_path":"` + filepath.Join(repo, "f.txt") + `"}`)},
		{HookEventName: "PreToolUse", ToolName: "mcp__x__y", CWD: repo},
	} {
		d := classify(ev)
		if d.Bucket != BucketDeny || d.Operation != "config:unusable" {
			t.Errorf("%s: got %q/%q, want deny/config:unusable", ev.ToolName, d.Bucket, d.Operation)
			continue
		}
		if !strings.Contains(d.Reason, "~/.config/guardrails/config.yml") {
			t.Errorf("%s: the reason does not name ~/.config/guardrails/config.yml; got %q", ev.ToolName, d.Reason)
		}
		if strings.Contains(d.Reason, home) {
			t.Errorf("%s: the reason carries the home directory %s; got %q", ev.ToolName, home, d.Reason)
		}
	}
}

// A config path that exists but cannot be read is an error that names no
// path, so the deny it becomes carries none either.
func TestUnreadableConfigErrorNamesNoPath(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "config.yml")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	_, err := loadOperatorConfigFrom(dir)
	if err == nil {
		t.Fatal("a directory at the config path loaded without an error")
	}
	if strings.Contains(err.Error(), dir) {
		t.Errorf("the error names the path; got %q", err)
	}
}
