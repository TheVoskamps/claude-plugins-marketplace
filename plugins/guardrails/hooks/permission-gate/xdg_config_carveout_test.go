package main

import (
	"os"
	"path/filepath"
	"testing"
)

// xdgFixture is a machine layout for the ~/.config carve-out: a session repo to
// use as the event cwd, a fake $HOME, and a ~/.config that is one of the three
// shapes the acceptance criteria distinguish. It returns the fake home.
//
// configTarget selects the shape:
//
//	"plain"    — ~/.config is an ordinary directory
//	"repo"     — ~/.config is a symlink into a directory that IS a git repo
//	             (the reported machine, and the only shape that reproduces)
//	"non-repo" — ~/.config is a symlink into a directory that is not a repo
//
// The verdict must not depend on which one is in play, which is exactly what
// pinning all three establishes.
func xdgFixture(t *testing.T, base string, configTarget string) string {
	t.Helper()
	home := filepath.Join(base, "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(home, ".config")

	switch configTarget {
	case "plain":
		if err := os.MkdirAll(cfg, 0o755); err != nil {
			t.Fatal(err)
		}
	case "repo", "non-repo":
		dotfiles := filepath.Join(base, "dotfiles")
		target := filepath.Join(dotfiles, "config")
		if err := os.MkdirAll(target, 0o755); err != nil {
			t.Fatal(err)
		}
		if configTarget == "repo" {
			gitInit(t, dotfiles)
		}
		if err := os.Symlink(target, cfg); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("unknown configTarget %q", configTarget)
	}

	t.Setenv("HOME", home)
	return home
}

// writeXDGCarveOutConfig writes ~/.config/guardrails/config.yml verbatim.
func writeXDGCarveOutConfig(t *testing.T, home string, body string) {
	t.Helper()
	dir := filepath.Join(home, ".config", "guardrails")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "config.yml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// carveOutConfig exercises each entry shape the grammar offers: one read-only
// entry spelled as an exact file, one read-only subtree, and one writable
// subtree.
const carveOutConfig = `schema-version: 1
allow-read:
  - macos-setup/**
  - gh/config.yml
allow-write:
  - cc-tools/**
`

// fileToolVerdict runs the file-tool classifier for one tool and one path.
func fileToolVerdict(t *testing.T, tool string, cwd string, path string) Decision {
	t.Helper()
	return classifyFileTool(&Event{
		ToolName:  tool,
		CWD:       cwd,
		ToolInput: []byte(`{"file_path":"` + path + `"}`),
	})
}

// The reported bug and its fix, across all three ~/.config shapes. Without the
// config file the read DENIES (that is the bug, and the negative control that
// proves the allow below comes from the carve-out); with cc-tools/** listed it
// ALLOWS, and the verdict does not depend on the git state of whatever
// ~/.config resolves to.
func TestXDGConfigCarveOutAllowsListedRead(t *testing.T) {
	for _, shape := range []string{"plain", "repo", "non-repo"} {
		t.Run(shape, func(t *testing.T) {
			base := t.TempDir()
			repo := filepath.Join(base, "repo")
			gitInit(t, repo)
			home := xdgFixture(t, base, shape)
			target := filepath.Join(home, ".config", "cc-tools", "whats-new.md")

			d := fileToolVerdict(t, "Read", repo, target)
			wantBucket(t, d, BucketDeny, "read of a ~/.config file with no carve-out configured")

			writeXDGCarveOutConfig(t, home, carveOutConfig)
			d = fileToolVerdict(t, "Read", repo, target)
			wantBucket(t, d, BucketAllow, "read of a listed ~/.config file")
			if !containsSubstr(d.Reason, filepath.Join(home, ".config", "guardrails", "config.yml")) {
				t.Errorf("allow reason should name the operator's config file; got %q", d.Reason)
			}
		})
	}
}

// allow-write implies allow-read, and allow-read alone does not imply write.
// The read half is what /issues:global-user-config needs to merge-update its
// own file; the write half is the limit that keeps a read-only entry meaningful.
func TestXDGConfigCarveOutWriteImpliesRead(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := xdgFixture(t, base, "repo")
	writeXDGCarveOutConfig(t, home, carveOutConfig)

	writable := filepath.Join(home, ".config", "cc-tools", "whats-new.md")
	readable := filepath.Join(home, ".config", "gh", "config.yml")

	for _, tool := range []string{"Read", "Write", "Edit"} {
		d := fileToolVerdict(t, tool, repo, writable)
		wantBucket(t, d, BucketAllow, tool+" of an allow-write path")
	}

	d := fileToolVerdict(t, "Read", repo, readable)
	wantBucket(t, d, BucketAllow, "Read of an allow-read path")
	d = fileToolVerdict(t, "Write", repo, readable)
	if d.Bucket == BucketAllow {
		t.Errorf("Write to an allow-read-only path must not ALLOW; got %q (%s)", d.Bucket, d.Reason)
	}
}

// A path under ~/.config that matches neither list keeps the verdict it has
// today, and so does every path once the config file is absent or malformed.
// The carve-out fails closed on each of those.
func TestXDGConfigCarveOutFailsClosed(t *testing.T) {
	cases := []struct {
		name   string
		config string
		rel    string
	}{
		{"unlisted path", carveOutConfig, "issues/user-config.md"},
		{"malformed yaml", "schema-version: 1\nallow-read: [unclosed\n", "cc-tools/whats-new.md"},
		{"no schema stamp", "allow-write:\n  - cc-tools/**\n", "cc-tools/whats-new.md"},
		{"older schema stamp", "schema-version: 0\nallow-write:\n  - cc-tools/**\n", "cc-tools/whats-new.md"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			base := t.TempDir()
			repo := filepath.Join(base, "repo")
			gitInit(t, repo)
			home := xdgFixture(t, base, "repo")
			writeXDGCarveOutConfig(t, home, tc.config)

			d := fileToolVerdict(t, "Read", repo, filepath.Join(home, ".config", tc.rel))
			wantBucket(t, d, BucketDeny, tc.name)
		})
	}

	t.Run("absent config file", func(t *testing.T) {
		base := t.TempDir()
		repo := filepath.Join(base, "repo")
		gitInit(t, repo)
		home := xdgFixture(t, base, "repo")

		d := fileToolVerdict(t, "Read", repo, filepath.Join(home, ".config", "cc-tools", "whats-new.md"))
		wantBucket(t, d, BucketDeny, "absent config file")
	})
}

// A `..` walk out of ~/.config cannot match, whatever the globs say: the
// remainder is taken from a lexically-cleaned path, so a target that climbs out
// of the root no longer carries the root prefix. The sibling repo it climbs
// into is the negative control — reading it still denies.
func TestXDGConfigCarveOutDotDotEscape(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	home := xdgFixture(t, base, "repo")
	// A glob wide enough to match anything the walk could produce, so the deny
	// below is the cleaning and not a narrow list.
	writeXDGCarveOutConfig(t, home, "schema-version: 1\nallow-read:\n  - '**'\n")

	escaping := filepath.Join(home, ".config", "..", "..", "sibling", ".env")
	d := fileToolVerdict(t, "Read", repo, escaping)
	wantBucket(t, d, BucketDeny, "a ..-walk out of ~/.config")

	d = fileToolVerdict(t, "Read", repo, filepath.Join(sibling, ".env"))
	wantBucket(t, d, BucketDeny, "read of a sibling repo (negative control)")
}

// A call mixing a listed ~/.config target with an ordinary in-repo one falls
// back to the ordinary defer rather than letting the carve-out's ALLOW ride
// along with a path the gate has not blessed on its own terms.
func TestXDGConfigCarveOutDoesNotRideAlong(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := xdgFixture(t, base, "repo")
	writeXDGCarveOutConfig(t, home, carveOutConfig)

	d := classifyFileTool(&Event{
		ToolName: "Read",
		CWD:      repo,
		ToolInput: []byte(`{"file_path":"` + filepath.Join(home, ".config", "cc-tools", "x.md") + `",` +
			`"notebook_path":"` + filepath.Join(repo, "a.md") + `"}`),
	})
	if d.Bucket == BucketAllow {
		t.Errorf("a mixed call must not ALLOW; got %q (%s)", d.Bucket, d.Reason)
	}
}

// A `.git/` segment under a listed path denies for every file tool, so no
// listing hands out a git internals tree. The glob is deliberately wide enough
// to match anything under the root, and the sibling non-`.git/` read is the
// negative control that the deny is the `.git/` rule rather than a missing
// listing.
func TestXDGConfigCarveOutDoesNotOpenGitTree(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := xdgFixture(t, base, "repo")
	writeXDGCarveOutConfig(t, home, "schema-version: 1\nallow-write:\n  - '**'\n")

	target := filepath.Join(home, ".config", "cc-tools", ".git", "config")
	for _, tc := range []struct{ tool, op string }{
		{"Read", "read:.git tree"},
		{"Write", "write:.git tree"},
	} {
		d := fileToolVerdict(t, tc.tool, repo, target)
		wantBucket(t, d, BucketDeny, tc.tool+" of a listed path under .git/")
		if !containsSubstr(d.Operation, tc.op) {
			t.Errorf("%s under .git/ should deny as %q; got op %q (%s)", tc.tool, tc.op, d.Operation, d.Reason)
		}
	}

	d := fileToolVerdict(t, "Read", repo, filepath.Join(home, ".config", "cc-tools", "whats-new.md"))
	wantBucket(t, d, BucketAllow, "read of a listed path with no .git/ segment")
}

// The glob grammar: `**` spans whole segments, a plain `*` does not cross a
// separator, and an exact entry matches only itself.
func TestMatchConfigGlob(t *testing.T) {
	cases := []struct {
		glob string
		rem  string
		want bool
	}{
		{"cc-tools/**", "cc-tools/whats-new.md", true},
		{"cc-tools/**", "cc-tools/a/b/c.md", true},
		{"cc-tools/**", "cc-tools", true},
		{"cc-tools/**", "cc-toolsx/a.md", false},
		{"cc-tools/**", "issues/a.md", false},
		{"gh/config.yml", "gh/config.yml", true},
		{"gh/config.yml", "gh/config.yml.bak", false},
		{"gh/config.yml", "gh/hosts/config.yml", false},
		{"gh/*", "gh/config.yml", true},
		{"gh/*", "gh/hosts/config.yml", false},
		{"**", "anything/at/all", true},
		{"../**", "cc-tools/a.md", false},
	}
	for _, tc := range cases {
		if got := matchConfigGlob(tc.glob, tc.rem); got != tc.want {
			t.Errorf("matchConfigGlob(%q, %q) = %v, want %v", tc.glob, tc.rem, got, tc.want)
		}
	}
}

// The reader's own contract, exercised directly so a failure names the parse
// rather than a downstream verdict.
func TestLoadXDGConfigCarveOutFrom(t *testing.T) {
	base := t.TempDir()
	path := filepath.Join(base, "config.yml")

	c := loadXDGConfigCarveOutFrom(base, path)
	if !c.empty() {
		t.Errorf("an absent config file must yield empty lists; got %+v", c)
	}

	if err := os.WriteFile(path, []byte(carveOutConfig), 0o644); err != nil {
		t.Fatal(err)
	}
	c = loadXDGConfigCarveOutFrom(base, path)
	if len(c.allowRead) != 2 || len(c.allowWrite) != 1 {
		t.Errorf("expected 2 read globs and 1 write glob; got %+v", c)
	}

	// A stamp ABOVE the pin is read for the keys this version documents, per
	// docs/config-file-conventions.md: newer versions are additive.
	if err := os.WriteFile(path, []byte("schema-version: 99\nallow-write:\n  - cc-tools/**\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	c = loadXDGConfigCarveOutFrom(base, path)
	if len(c.allowWrite) != 1 {
		t.Errorf("a higher schema-version must still be read; got %+v", c)
	}
}
