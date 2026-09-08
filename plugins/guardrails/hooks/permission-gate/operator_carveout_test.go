package main

import (
	"os"
	"path/filepath"
	"testing"
)

// carveOutFixture is a machine layout for the operator carve-out: a fake $HOME
// whose ~/.config is one of the three shapes the acceptance criteria
// distinguish. It returns the fake home.
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
//
// Both XDG variables are cleared, so a test that does not set one exercises the
// unset-or-empty case whatever the developer's own environment says. A test
// that wants a relocated root sets the variable itself.
func carveOutFixture(t *testing.T, base string, configTarget string) string {
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
	t.Setenv(xdgConfigHomeEnv, "")
	t.Setenv(xdgStateHomeEnv, "")
	return home
}

// writeCarveOutConfig writes ~/.config/guardrails/config.yml verbatim — the
// literal load path, which is the same on every machine whatever `config-home`
// resolves to.
func writeCarveOutConfig(t *testing.T, home string, body string) {
	t.Helper()
	dir := filepath.Join(home, ".config", "guardrails")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "config.yml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// carveOutConfig exercises each entry shape the grammar offers, on each of the
// three roots: read-only exact files and subtrees, and writable subtrees. The
// XDG variables are left unresolved, so `config-home-default` and
// `state-home-default` are what the two non-home roots follow.
const carveOutConfig = `schema-version: 2
config-home-default: ~/.config
state-home-default: ~/.local/state
config-home:
  read:
    - macos-setup/**
    - gh/config.yml
  write:
    - cc-tools/**
state-home:
  write:
    - sdlc/**
home:
  read:
    - .ssh/config
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
func TestOperatorCarveOutAllowsListedRead(t *testing.T) {
	for _, shape := range []string{"plain", "repo", "non-repo"} {
		t.Run(shape, func(t *testing.T) {
			base := t.TempDir()
			repo := filepath.Join(base, "repo")
			gitInit(t, repo)
			home := carveOutFixture(t, base, shape)
			target := filepath.Join(home, ".config", "cc-tools", "whats-new.md")

			d := fileToolVerdict(t, "Read", repo, target)
			wantBucket(t, d, BucketDeny, "read of a ~/.config file with no carve-out configured")

			writeCarveOutConfig(t, home, carveOutConfig)
			d = fileToolVerdict(t, "Read", repo, target)
			wantBucket(t, d, BucketAllow, "read of a listed ~/.config file")
			if !containsSubstr(d.Reason, filepath.Join(home, ".config", "guardrails", "config.yml")) {
				t.Errorf("allow reason should name the operator's config file; got %q", d.Reason)
			}
		})
	}
}

// The two roots the literal ~/.config pin could never reach: the XDG state home
// and the home directory itself. Each is its own root with its own lists, and
// each denies before the config file names it — the negative control that the
// allow comes from that root's entry and not from the config-home one.
func TestOperatorCarveOutStateAndHomeRoots(t *testing.T) {
	cases := map[string]struct {
		rel  string
		tool string
	}{
		"state-home write": {filepath.Join(".local", "state", "sdlc", "round.log"), "Write"},
		"home read":        {filepath.Join(".ssh", "config"), "Read"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			base := t.TempDir()
			repo := filepath.Join(base, "repo")
			gitInit(t, repo)
			home := carveOutFixture(t, base, "repo")
			target := filepath.Join(home, tc.rel)

			d := fileToolVerdict(t, tc.tool, repo, target)
			wantBucket(t, d, BucketDeny, tc.tool+" of "+tc.rel+" with no carve-out configured")

			writeCarveOutConfig(t, home, carveOutConfig)
			d = fileToolVerdict(t, tc.tool, repo, target)
			wantBucket(t, d, BucketAllow, tc.tool+" of the listed "+tc.rel)
		})
	}
}

// `write` implies `read`, and `read` alone does not imply write. The read half
// is what /issues:global-user-config needs to merge-update its own file; the
// write half is the limit that keeps a read-only entry meaningful.
func TestOperatorCarveOutWriteImpliesRead(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")
	writeCarveOutConfig(t, home, carveOutConfig)

	writable := filepath.Join(home, ".config", "cc-tools", "whats-new.md")
	readable := filepath.Join(home, ".config", "gh", "config.yml")

	for _, tool := range []string{"Read", "Write", "Edit"} {
		d := fileToolVerdict(t, tool, repo, writable)
		wantBucket(t, d, BucketAllow, tool+" of a write-listed path")
	}

	d := fileToolVerdict(t, "Read", repo, readable)
	wantBucket(t, d, BucketAllow, "Read of a read-listed path")
	d = fileToolVerdict(t, "Write", repo, readable)
	if d.Bucket == BucketAllow {
		t.Errorf("Write to a read-only-listed path must not ALLOW; got %q (%s)", d.Bucket, d.Reason)
	}
}

// A path under a carve-out root that matches neither list keeps the verdict it
// has today, and so does every path once the config file is absent or
// malformed. The carve-out fails closed on each of those, for a WRITE as much
// as for a read. Both classes are pinned because they reach the allow by
// different routes — a read can ride either list, a write only `write` — so a
// config state that yields no entries has to be shown to close both. The
// states that spell a `write` list are exactly the ones that would hand out the
// write if the state were honoured, which is what makes them the write half's
// negative controls rather than a duplicate of the read half.
//
// The schema-1 row is the migration case: a file still spelling `allow-read` /
// `allow-write` is stamped below the pin, so it yields no entries and the
// machine has today's behaviour until the operator hand-edits it once.
func TestOperatorCarveOutFailsClosed(t *testing.T) {
	cases := []struct {
		name string
		// config is the operator file's body; "" writes no file at all.
		config string
		rel    string
	}{
		{"unlisted path", carveOutConfig, filepath.Join(".config", "issues", "user-config.md")},
		{"malformed yaml", "schema-version: 2\nconfig-home:\n  read: [unclosed\n",
			filepath.Join(".config", "cc-tools", "whats-new.md")},
		{"no schema stamp", "config-home-default: ~/.config\nconfig-home:\n  write:\n    - cc-tools/**\n",
			filepath.Join(".config", "cc-tools", "whats-new.md")},
		{"schema-1 allow-read/allow-write", "schema-version: 1\nallow-write:\n  - cc-tools/**\n",
			filepath.Join(".config", "cc-tools", "whats-new.md")},
		{"schema-2 keys under a schema-1 stamp",
			"schema-version: 1\nconfig-home-default: ~/.config\nconfig-home:\n  write:\n    - cc-tools/**\n",
			filepath.Join(".config", "cc-tools", "whats-new.md")},
		{"absent config file", "", filepath.Join(".config", "cc-tools", "whats-new.md")},
		// No `config-home-default` and no opt-in leaves the root with no usable
		// spelling, so its entries are dead: there is no built-in default to
		// fall back on.
		{"config-home root unspelled", "schema-version: 2\nconfig-home:\n  write:\n    - cc-tools/**\n",
			filepath.Join(".config", "cc-tools", "whats-new.md")},
		{"state-home root unspelled", "schema-version: 2\nstate-home:\n  write:\n    - sdlc/**\n",
			filepath.Join(".local", "state", "sdlc", "round.log")},
	}
	for _, tc := range cases {
		for _, tool := range []string{"Read", "Write"} {
			t.Run(tc.name+"/"+tool, func(t *testing.T) {
				base := t.TempDir()
				repo := filepath.Join(base, "repo")
				gitInit(t, repo)
				home := carveOutFixture(t, base, "repo")
				if tc.config != "" {
					writeCarveOutConfig(t, home, tc.config)
				}

				d := fileToolVerdict(t, tool, repo, filepath.Join(home, tc.rel))
				wantBucket(t, d, BucketDeny, tool+" — "+tc.name)
			})
		}
	}
}

// The XDG variables are read only on the opt-in, and only when set and
// non-empty — the same test docs/config-file-conventions.md gives the plugins,
// so the gate and the plugins agree on every machine. The relocated directory
// is outside the fake home entirely, so the allow can only come from the
// variable having been followed.
func TestOperatorCarveOutXDGEnvironmentOptIn(t *testing.T) {
	const optIn = `schema-version: 2
resolve-xdg-environment-variables: yes
config-home-default: ~/.config
config-home:
  write:
    - cc-tools/**
`
	const optOut = `schema-version: 2
config-home-default: ~/.config
config-home:
  write:
    - cc-tools/**
`
	cases := map[string]struct {
		config string
		// env is the $XDG_CONFIG_HOME value; "" is the unset-or-empty case.
		env          string
		relocated    Bucket
		underDefault Bucket
	}{
		// Opted in with the variable set: the relocated root is live and the
		// `config-home-default` spelling is not.
		"opt-in, variable set": {optIn, "relocated", BucketAllow, BucketDeny},
		// Opted in with the variable empty: the default spelling decides.
		"opt-in, variable empty": {optIn, "", BucketDeny, BucketAllow},
		// Not opted in: the variable is ignored even when set.
		"opt-out, variable set": {optOut, "relocated", BucketDeny, BucketAllow},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			base := t.TempDir()
			repo := filepath.Join(base, "repo")
			gitInit(t, repo)
			home := carveOutFixture(t, base, "repo")
			writeCarveOutConfig(t, home, tc.config)

			relocated := filepath.Join(base, "relocated")
			if err := os.MkdirAll(filepath.Join(relocated, "cc-tools"), 0o755); err != nil {
				t.Fatal(err)
			}
			if tc.env != "" {
				t.Setenv(xdgConfigHomeEnv, relocated)
			}

			d := fileToolVerdict(t, "Write", repo, filepath.Join(relocated, "cc-tools", "x.md"))
			wantBucket(t, d, tc.relocated, "write under the relocated config home")

			d = fileToolVerdict(t, "Write", repo, filepath.Join(home, ".config", "cc-tools", "x.md"))
			wantBucket(t, d, tc.underDefault, "write under the default config home")
		})
	}
}

// The carve-out never hands out a write to its own config file, whatever the
// globs say — the deny that bounds the environment-variable opt-in. It holds at
// the literal load path, at the resolved config-home spelling when the two
// differ, and through a symlink to either, because this is the one comparison in
// the carve-out that canonicalizes both sides. A READ of the file is untouched:
// only the write is refused.
func TestOperatorCarveOutRefusesSelfWrite(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")

	relocated := filepath.Join(base, "relocated")
	if err := os.MkdirAll(filepath.Join(relocated, "guardrails"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv(xdgConfigHomeEnv, relocated)
	writeCarveOutConfig(t, home, `schema-version: 2
resolve-xdg-environment-variables: yes
config-home-default: ~/.config
home:
  write:
    - '**'
config-home:
  write:
    - '**'
`)
	// The relocated config-home copy has to exist for the canonical comparison
	// to have anything to resolve, and a symlink to the literal one covers the
	// symlinked-copy case the lexical glob match would otherwise walk straight
	// past.
	literal := filepath.Join(home, ".config", "guardrails", "config.yml")
	relocatedCopy := filepath.Join(relocated, "guardrails", "config.yml")
	if err := os.WriteFile(relocatedCopy, []byte("schema-version: 2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, "link-to-config.yml")
	if err := os.Symlink(literal, link); err != nil {
		t.Fatal(err)
	}

	for name, target := range map[string]string{
		"the literal load path":        literal,
		"the resolved config-home one": relocatedCopy,
		"a symlink to the load path":   link,
	} {
		d := fileToolVerdict(t, "Write", repo, target)
		if d.Bucket == BucketAllow {
			t.Errorf("a write to the carve-out's own config file via %s must not ALLOW; got %q (%s)",
				name, d.Bucket, d.Reason)
		}
	}

	// The negative control on both halves: a write elsewhere under the same
	// `**` entry allows, and a READ of the config file itself allows.
	d := fileToolVerdict(t, "Write", repo, filepath.Join(home, ".config", "cc-tools", "x.md"))
	wantBucket(t, d, BucketAllow, "a write elsewhere under the same '**' entry")
	d = fileToolVerdict(t, "Read", repo, literal)
	wantBucket(t, d, BucketAllow, "a read of the carve-out's own config file")
}

// A `..` walk out of a carve-out root cannot match, whatever the globs say: the
// remainder is taken from a lexically-cleaned path, so a target that climbs out
// of the root no longer carries the root prefix. The sibling repo it climbs
// into is the negative control — reading it still denies.
func TestOperatorCarveOutDotDotEscape(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	sibling := filepath.Join(base, "sibling")
	gitInit(t, sibling)
	home := carveOutFixture(t, base, "repo")
	// A glob wide enough to match anything the walk could produce, so the deny
	// below is the cleaning and not a narrow list. The root is config-home
	// rather than home, whose prefix the walk would still carry.
	writeCarveOutConfig(t, home, "schema-version: 2\nconfig-home-default: ~/.config\nconfig-home:\n  read:\n    - '**'\n")

	escaping := filepath.Join(home, ".config", "..", "..", "sibling", ".env")
	d := fileToolVerdict(t, "Read", repo, escaping)
	wantBucket(t, d, BucketDeny, "a ..-walk out of the config-home root")

	d = fileToolVerdict(t, "Read", repo, filepath.Join(sibling, ".env"))
	wantBucket(t, d, BucketDeny, "read of a sibling repo (negative control)")
}

// A call mixing a listed target with an ordinary in-repo one falls back to the
// ordinary defer rather than letting the carve-out's ALLOW ride along with a
// path the gate has not blessed on its own terms.
func TestOperatorCarveOutDoesNotRideAlong(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")
	writeCarveOutConfig(t, home, carveOutConfig)

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

// A `.git/` segment under a listed path denies for read and write alike, so no
// listing hands out a git internals tree — the write on the top-of-walk rule,
// the read inside the carve-out arm, which is the only place a listed path
// could otherwise reach an ALLOW. The fixture lists the widest thing the schema
// can express — `**` on the HOME root, which now covers everything the other
// two roots do — and the sibling non-`.git/` read is the negative control that
// the deny is the `.git/` rule rather than a missing listing.
func TestOperatorCarveOutDoesNotOpenGitTree(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")
	writeCarveOutConfig(t, home, "schema-version: 2\nhome:\n  write:\n    - '**'\n")

	for _, rel := range []string{
		filepath.Join(".config", "cc-tools", ".git", "config"),
		filepath.Join(".local", "state", "sdlc", ".git", "config"),
	} {
		target := filepath.Join(home, rel)
		for _, tc := range []struct{ tool, op string }{
			{"Read", "read:.git tree"},
			{"Write", "write:.git tree"},
		} {
			d := fileToolVerdict(t, tc.tool, repo, target)
			wantBucket(t, d, BucketDeny, tc.tool+" of a listed path under .git/ ("+rel+")")
			if !containsSubstr(d.Operation, tc.op) {
				t.Errorf("%s under .git/ should deny as %q; got op %q (%s)", tc.tool, tc.op, d.Operation, d.Reason)
			}
		}
	}

	d := fileToolVerdict(t, "Read", repo, filepath.Join(home, ".config", "cc-tools", "whats-new.md"))
	wantBucket(t, d, BucketAllow, "read of a listed path with no .git/ segment")
}

// The glob grammar: `**` spans whole segments, a plain `*` does not cross a
// separator, and an exact entry matches only itself.
func TestMatchCarveOutGlob(t *testing.T) {
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
		if got := matchCarveOutGlob(tc.glob, tc.rem); got != tc.want {
			t.Errorf("matchCarveOutGlob(%q, %q) = %v, want %v", tc.glob, tc.rem, got, tc.want)
		}
	}
}

// The reader's own contract, exercised directly so a failure names the parse
// rather than a downstream verdict.
func TestLoadOperatorCarveOutFrom(t *testing.T) {
	base := t.TempDir()
	home := carveOutFixture(t, base, "plain")
	path := filepath.Join(base, "config.yml")

	c := loadOperatorCarveOutFrom(path)
	if !c.empty() {
		t.Errorf("an absent config file must yield no roots; got %+v", c)
	}

	if err := os.WriteFile(path, []byte(carveOutConfig), 0o644); err != nil {
		t.Fatal(err)
	}
	c = loadOperatorCarveOutFrom(path)
	if len(c.roots) != 3 {
		t.Errorf("expected all three roots to resolve; got %+v", c)
	}
	// The self-write paths are the literal load path (here the fixture's own,
	// since that is what was passed in) plus the resolved config-home spelling.
	wantSelf := []string{path, filepath.Join(home, ".config", "guardrails", "config.yml")}
	if len(c.selfWritePaths) != len(wantSelf) {
		t.Fatalf("expected %d self-write paths; got %+v", len(wantSelf), c.selfWritePaths)
	}
	for i, want := range wantSelf {
		if c.selfWritePaths[i] != want {
			t.Errorf("self-write path %d = %q, want %q", i, c.selfWritePaths[i], want)
		}
	}

	// A root the file lists nothing under is not built at all, so `empty()` is a
	// question about the whole carve-out rather than about each root in turn.
	if err := os.WriteFile(path, []byte("schema-version: 2\nconfig-home-default: ~/.config\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if c = loadOperatorCarveOutFrom(path); !c.empty() {
		t.Errorf("a file listing nothing must yield no roots; got %+v", c)
	}

	// A stamp ABOVE the pin is read for the keys this version documents, per
	// docs/config-file-conventions.md: newer versions are additive.
	if err := os.WriteFile(path, []byte(
		"schema-version: 99\nconfig-home-default: ~/.config\nconfig-home:\n  write:\n    - cc-tools/**\n"),
		0o644); err != nil {
		t.Fatal(err)
	}
	c = loadOperatorCarveOutFrom(path)
	if len(c.roots) != 1 || len(c.roots[0].write) != 1 {
		t.Errorf("a higher schema-version must still be read; got %+v", c)
	}
}
