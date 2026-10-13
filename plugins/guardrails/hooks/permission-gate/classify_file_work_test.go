package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fileWorkConfig installs a fixture home for the test and, unless body is
// empty, writes body as its ~/.config/guardrails/config.yml. Git is detached
// from the driving machine's global and system config, which a relocated home
// would otherwise make it read through.
func fileWorkConfig(t *testing.T, body string) {
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
}

// fileWorkRepo builds a plain repository to run events in.
func fileWorkRepo(t *testing.T) string {
	t.Helper()
	repo := filepath.Join(t.TempDir(), "repo")
	gitInit(t, repo)
	return canonicalize(repo)
}

func fileWorkEvent(cwd, agentType string) *Event {
	return &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: cwd, AgentType: agentType}
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
	{"cat f.txt && make", "bash-file-work:read"},
	{"cat a.txt; cat b.txt", "bash-file-work:read"},
	{"cat f.txt | cat", "bash-file-work:read"},
	{"cat f.txt | head", "bash-file-work:read"},
	{"sed -i 's/a/b/' f.txt", "bash-file-work:edit"},
	{"sed -i.bak -e 's/a/b/' f.txt", "bash-file-work:edit"},
	{"sed --in-place 's/a/b/' f.txt", "bash-file-work:edit"},
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
}

// uncoveredShapes are lines the redirect never denies.
var uncoveredShapes = []string{
	"make 2>&1 | tail -20",
	"ls | head",
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
	"tee /dev/null <<EOF\nx\nEOF",
	"grep -rn x .",
	"find . -name '*.go'",
	"ls -la",
	"sed 's/a/b/' f.txt",
	"cat",
	"cat -",
	"echo hi",
	"x=$(cat f.txt | jq .)",
}

// Under `always`, every covered shape is denied with a reason naming its tool,
// and no uncovered shape is denied by the redirect.
func TestFileWorkAlways(t *testing.T) {
	repo := fileWorkRepo(t)
	fileWorkConfig(t, "redirect-bash-file-work: always\n")
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

// Under `off`, with the key absent, and with no config file at all, every
// covered shape gets the verdict the line gets without the redirect.
func TestFileWorkOffIsTodaysVerdict(t *testing.T) {
	repo := fileWorkRepo(t)
	for _, cfg := range []struct{ name, body string }{
		{"off", "redirect-bash-file-work: off\n"},
		{"key absent", "schema-version: 2\n"},
		{"empty value", "redirect-bash-file-work:\n"},
		{"no file", ""},
	} {
		t.Run(cfg.name, func(t *testing.T) {
			fileWorkConfig(t, cfg.body)
			t.Chdir(repo)
			for _, c := range coveredShapes {
				got := classifyBash(c.cmd, fileWorkEvent(repo, "main"))
				want := classifyBashLine(c.cmd, fileWorkEvent(repo, "main"))
				if got != want {
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
	fileWorkConfig(t, "redirect-bash-file-work: worktree\n")
	for _, agent := range []string{"main", "issue-developer", ""} {
		for _, c := range coveredShapes {
			d := classifyBash(c.cmd, fileWorkEvent(wt, agent))
			if d.Bucket != BucketDeny || d.Operation != c.op {
				t.Errorf("worktree, agent %q, %q: got %q/%q, want deny/%q", agent, c.cmd, d.Bucket, d.Operation, c.op)
			}
			got := classifyBash(c.cmd, fileWorkEvent(primary, agent))
			want := classifyBashLine(c.cmd, fileWorkEvent(primary, agent))
			if got != want {
				t.Errorf("primary, agent %q, %q: got %+v, want today's %+v", agent, c.cmd, got, want)
			}
		}
	}

	// A cwd that resolves to no repository does not fire.
	d := classifyBash("cat f.txt", fileWorkEvent(t.TempDir(), "issue-developer"))
	if strings.HasPrefix(d.Operation, "bash-file-work:") {
		t.Errorf("no repository: denied by the redirect (%q)", d.Reason)
	}
}

// A line another rule denies keeps that rule's reason.
func TestFileWorkKeepsOtherDeny(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	root := canonicalize(repo)
	fileWorkConfig(t, "redirect-bash-file-work: always\n")
	t.Chdir(root)

	for _, cmd := range []string{
		"cat " + filepath.Join(canonicalize(sibling), "x.txt"),
		"git -C /tmp log; cat f.txt",
		"sed -i 's/a/b/' " + filepath.Join(canonicalize(sibling), "x.txt"),
	} {
		want := classifyBashLine(cmd, fileWorkEvent(root, "main"))
		if want.Bucket != BucketDeny {
			t.Fatalf("%q: the control must be denied by another rule; got %q", cmd, want.Bucket)
		}
		got := classifyBash(cmd, fileWorkEvent(root, "main"))
		if got != want {
			t.Errorf("%q: got %+v, want the other rule's %+v", cmd, got, want)
		}
	}
}

// isLinkedWorktree tells a linked worktree's context from the primary clone's.
func TestRepoContextIsLinkedWorktree(t *testing.T) {
	primary, wt := setupWorktree(t)
	for _, c := range []struct {
		cwd  string
		want bool
	}{
		{primary, false},
		{wt, true},
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

// The loader reads each mode, treats everything else as off, and warns only on
// a value that is present and not a mode.
func TestLoadRedirectBashFileWork(t *testing.T) {
	dir := t.TempDir()
	for _, c := range []struct {
		name string
		body string
		want fileWorkMode
		warn bool
	}{
		{"always", "redirect-bash-file-work: always\n", fileWorkAlways, false},
		{"worktree", "redirect-bash-file-work: worktree\n", fileWorkWorktree, false},
		{"off", "redirect-bash-file-work: off\n", fileWorkOff, false},
		{"quoted off", "redirect-bash-file-work: \"off\"\n", fileWorkOff, false},
		{"null", "redirect-bash-file-work:\n", fileWorkOff, false},
		{"absent", "schema-version: 2\n", fileWorkOff, false},
		{"not yaml", "redirect-bash-file-work: [\n", fileWorkOff, false},
		{"unknown", "redirect-bash-file-work: sometimes\n", fileWorkOff, true},
		{"wrong case", "redirect-bash-file-work: Always\n", fileWorkOff, true},
		{"boolean", "redirect-bash-file-work: true\n", fileWorkOff, true},
		{"sequence", "redirect-bash-file-work: [always]\n", fileWorkOff, true},
	} {
		path := filepath.Join(dir, c.name+".yml")
		if err := os.WriteFile(path, []byte(c.body), 0o644); err != nil {
			t.Fatal(err)
		}
		var warn bytes.Buffer
		if got := loadRedirectBashFileWork(path, &warn); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
		if gotWarn := warn.Len() > 0; gotWarn != c.warn {
			t.Errorf("%s: warned %v (%q), want %v", c.name, gotWarn, warn.String(), c.warn)
		}
		if c.warn && !strings.Contains(warn.String(), redirectBashFileWorkKey) {
			t.Errorf("%s: the warning does not name the key; got %q", c.name, warn.String())
		}
	}

	var warn bytes.Buffer
	if got := loadRedirectBashFileWork(filepath.Join(dir, "missing.yml"), &warn); got != fileWorkOff || warn.Len() > 0 {
		t.Errorf("missing file: got %q with warning %q, want off and no warning", got, warn.String())
	}
}

// An unknown value leaves every covered shape at today's verdict.
func TestFileWorkUnknownValueIsOff(t *testing.T) {
	repo := fileWorkRepo(t)
	fileWorkConfig(t, "redirect-bash-file-work: sometimes\n")
	t.Chdir(repo)
	for _, c := range coveredShapes {
		got := classifyBash(c.cmd, fileWorkEvent(repo, "main"))
		want := classifyBashLine(c.cmd, fileWorkEvent(repo, "main"))
		if got != want {
			t.Errorf("%q: got %+v, want today's %+v", c.cmd, got, want)
		}
	}
}

// The carve-out keeps loading when the redirect's value is malformed.
func TestFileWorkBadValueKeepsCarveOut(t *testing.T) {
	base := t.TempDir()
	home := carveOutFixture(t, base, "plain")
	writeCarveOutConfig(t, home, carveOutConfig+"redirect-bash-file-work: [always]\n")
	if loadOperatorCarveOut().empty() {
		t.Error("a malformed redirect-bash-file-work value withdrew the carve-out")
	}
}
