package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// carveOutFixture is a machine layout for the operator carve-out: a fake $HOME
// whose ~/.config is one of the shapes the acceptance criteria distinguish. It
// returns the fake home.
//
// configTarget selects the shape:
//
//	"plain"    — ~/.config is an ordinary directory
//	"repo"     — ~/.config is a symlink into a directory that IS a git repo
//	             (the reported machine, and the only shape that reproduces)
//	"non-repo" — ~/.config is a symlink into a directory that is not a repo
//
// The verdict must not depend on which one is in play, which is exactly what
// pinning every shape above establishes.
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

// carveOutConfig exercises each entry shape the grammar offers, on every root
// it offers: read-only exact files and subtrees, and writable subtrees. The
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

// The reported bug and its fix, across every ~/.config shape carveOutFixture
// offers. Without the config file the read DENIES (that is the bug, and the
// negative control that proves the allow below comes from the carve-out); with
// cc-tools/** listed it ALLOWS, and the verdict does not depend on the git
// state of whatever ~/.config resolves to.
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
// non-empty — the same test the plugins apply to those variables, so the gate
// and the plugins agree on every machine. The relocated directory
// is outside the fake home entirely, so the allow can only come from the
// variable having been followed.
//
// Both relocatable roots run the whole matrix. The config home and the state
// home carry their own variable, their own `<root>-default` spelling and their
// own glob list, and only the config home also feeds the self-write deny — so
// a pass on one establishes nothing about the other, and the state home is the
// root the literal ~/.config pin could not reach at all.
func TestOperatorCarveOutXDGEnvironmentOptIn(t *testing.T) {
	roots := map[string]struct {
		envName string
		// key is the root's block in the config file; its `<root>-default`
		// spelling is key+"-default".
		key string
		// defaultSpelling is that spelling as the file gives it, and defaultRel
		// is where it lands under the fake home.
		defaultSpelling string
		defaultRel      string
		// listed is the subtree listed under the root, named for the plugin
		// whose files actually live there.
		listed string
	}{
		"config home": {xdgConfigHomeEnv, "config-home", "~/.config", ".config", "cc-tools"},
		"state home":  {xdgStateHomeEnv, "state-home", "~/.local/state", filepath.Join(".local", "state"), "sdlc"},
	}
	cases := map[string]struct {
		optIn bool
		// setEnv sets the root's variable to the relocated directory; without
		// it the variable stays as carveOutFixture left it, i.e. empty.
		setEnv       bool
		relocated    Bucket
		underDefault Bucket
	}{
		// Opted in with the variable set: the relocated root is live and the
		// `<root>-default` spelling is not.
		"opt-in, variable set": {true, true, BucketAllow, BucketDeny},
		// Opted in with the variable empty: the default spelling decides.
		"opt-in, variable empty": {true, false, BucketDeny, BucketAllow},
		// Not opted in: the variable is ignored even when set.
		"opt-out, variable set": {false, true, BucketDeny, BucketAllow},
	}
	for rootName, root := range roots {
		for name, tc := range cases {
			t.Run(rootName+", "+name, func(t *testing.T) {
				config := "schema-version: 2\n"
				if tc.optIn {
					config += "resolve-xdg-environment-variables: yes\n"
				}
				config += fmt.Sprintf("%s-default: %s\n%s:\n  write:\n    - %s/**\n",
					root.key, root.defaultSpelling, root.key, root.listed)

				base := t.TempDir()
				repo := filepath.Join(base, "repo")
				gitInit(t, repo)
				home := carveOutFixture(t, base, "repo")
				writeCarveOutConfig(t, home, config)

				relocated := filepath.Join(base, "relocated")
				if err := os.MkdirAll(filepath.Join(relocated, root.listed), 0o755); err != nil {
					t.Fatal(err)
				}
				if tc.setEnv {
					t.Setenv(root.envName, relocated)
				}

				d := fileToolVerdict(t, "Write", repo, filepath.Join(relocated, root.listed, "x.md"))
				wantBucket(t, d, tc.relocated, "write under the relocated "+rootName)

				d = fileToolVerdict(t, "Write", repo, filepath.Join(home, root.defaultRel, root.listed, "x.md"))
				wantBucket(t, d, tc.underDefault, "write under the default "+rootName)
			})
		}
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
	// A symlink to a DIRECTORY inside the config directory, so a `..` segment
	// behind it climbs to the config directory for the kernel and to the home
	// directory lexically. The two spellings name different files, which is what
	// makes one canonicalization of the target insufficient.
	nested := filepath.Join(home, ".config", "guardrails", "nested")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	dirLink := filepath.Join(home, "link-to-config-dir")
	if err := os.Symlink(nested, dirLink); err != nil {
		t.Fatal(err)
	}
	sep := string(filepath.Separator)
	// Assembled by concatenation, not filepath.Join, which would Clean the `..`
	// away and destroy the very spelling under test.
	throughDirLink := dirLink + sep + ".." + sep + "config.yml"

	// The trailing-separator rows and the `..`-behind-a-symlink row are the two
	// directions in which a spelling's lexical reading and its kernel reading
	// name different files, which is why the deny canonicalizes BOTH the cleaned
	// and the raw spelling and matches on either. A trailing separator Cleans
	// away lexically, so `remainder` matches the `**` entry on the path without
	// it, while the raw spelling reaches the same file through the segment walk
	// with its empty final segment skipped. A `..` behind a symlinked directory
	// runs the other way: cleaned first it names a nonexistent
	// `<home>/config.yml` that matches no self path, while the kernel delivers
	// the write to the real config file. One trailing-separator row per self
	// path, because the two self paths are reached by different halves of the
	// deny.
	for name, target := range map[string]string{
		"the literal load path":                                  literal,
		"the resolved config-home one":                           relocatedCopy,
		"a symlink to the load path":                             link,
		"the literal load path with a trailing separator":        literal + string(filepath.Separator),
		"the resolved config-home one with a trailing separator": relocatedCopy + string(filepath.Separator),
		"a `..` behind a symlink into the config directory":      throughDirLink,
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

// TestOperatorCarveOutRefusesSelfWriteNotYetCreated aims a `..` behind a
// symlinked directory at the config-home copy of the config file on a machine
// that has no such copy yet — the state that copy is normally in, since a
// machine with one config file has it at the literal load path.
//
// The existing symlinked-directory row aims at a file that EXISTS, where one
// filepath.EvalSymlinks call over the whole path resolves the spelling. With
// the file absent that call fails, so only the segment-by-segment resolution
// (resolvePathSegments, engine_b_containment.go) reaches it: a resolution that
// Cleans the `..` away before following the link lands on a nonexistent
// `<home>/config.yml` and matches no self path, while the kernel follows the
// link and delivers the write to the real config-home copy. All three rows
// below turn on that one property.
//
// Every row resolves to the same not-yet-created config-home copy and differs
// only in how it is spelled, and every row is a path the `**` entries on both
// roots would otherwise hand out on the lexically-cleaned spelling.
func TestOperatorCarveOutRefusesSelfWriteNotYetCreated(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")

	relocated := filepath.Join(base, "relocated")
	nested := filepath.Join(relocated, "guardrails", "nested")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv(xdgConfigHomeEnv, relocated)
	// The literal load path exists — the carve-out has to be able to read its
	// own config to have any entry at all. What deliberately does not exist is
	// <relocated>/guardrails/config.yml, the spelling every row resolves to.
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
	selfCopy := filepath.Join(relocated, "guardrails", "config.yml")
	if _, err := os.Lstat(selfCopy); err == nil {
		t.Fatalf("%s must not exist: the not-yet-created case is what is under test", selfCopy)
	}
	// A symlink to a DIRECTORY inside the relocated config directory, so a `..`
	// segment behind it climbs to that directory for the kernel and to the
	// link's own lexical parent for a Clean. One under home and one under the
	// relocated root, so neither the target's own prefix nor the root it is
	// spelled against is what the deny turns on.
	homeLink := filepath.Join(home, "link-to-relocated-config-dir")
	if err := os.Symlink(nested, homeLink); err != nil {
		t.Fatal(err)
	}
	rootLink := filepath.Join(relocated, "link-to-config-dir")
	if err := os.Symlink(nested, rootLink); err != nil {
		t.Fatal(err)
	}
	// Assembled by concatenation, not filepath.Join, which would Clean the `..`
	// away and destroy the very spelling under test.
	sep := string(filepath.Separator)
	for name, target := range map[string]string{
		"an absolute spelling through a symlink under home":         homeLink + sep + ".." + sep + "config.yml",
		"the `~` spelling of that same symlink":                     "~" + sep + filepath.Base(homeLink) + sep + ".." + sep + "config.yml",
		"an absolute spelling through a symlink under the XDG root": rootLink + sep + ".." + sep + "config.yml",
	} {
		d := fileToolVerdict(t, "Write", repo, target)
		if d.Bucket == BucketAllow {
			t.Errorf("a write reaching the not-yet-created config-home copy via %s must not ALLOW; got %q (%s)",
				name, d.Bucket, d.Reason)
		}
	}

	// The negative control: the same spelling with one segment changed, naming a
	// file that is not this config and does not exist either. It stays an ALLOW,
	// so the rows above are the self-write deny firing on the file they reach
	// and not the `..`-behind-a-symlink shape being refused wholesale.
	d := fileToolVerdict(t, "Write", repo, homeLink+sep+".."+sep+"other.yml")
	wantBucket(t, d, BucketAllow, "a write to a non-config file behind the same symlink")
}

// TestOperatorCarveOutRefusesSelfWriteThroughDanglingLink aims a symlink
// DIRECTLY at the config-home copy of the config file on a machine that has no
// such copy yet, so the FINAL segment of the target is a link whose destination
// does not exist.
//
// That dangling final segment defeats both halves of the identity comparison
// unless the link is read: filepath.EvalSymlinks fails on it, so the canonical
// path is the link's own spelling, which matches no self path as a string — and
// os.Stat of it fails too, which leaves os.SameFile nothing to compare. The
// write nevertheless creates the config file the link points at, so it must not
// ALLOW. The `..`-behind-a-symlinked-directory rows above never exercise this:
// there the link is an interior segment resolving to a directory that exists.
func TestOperatorCarveOutRefusesSelfWriteThroughDanglingLink(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")

	relocated := filepath.Join(base, "relocated")
	if err := os.MkdirAll(filepath.Join(relocated, "guardrails"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv(xdgConfigHomeEnv, relocated)
	// The literal load path exists — the carve-out has to read its own config to
	// have any entry at all. What deliberately does not exist is the config-home
	// copy every link below points at.
	writeCarveOutConfig(t, home, `schema-version: 2
resolve-xdg-environment-variables: yes
config-home-default: ~/.config
home:
  write:
    - '**'
`)
	selfCopy := filepath.Join(relocated, "guardrails", "config.yml")
	if _, err := os.Lstat(selfCopy); err == nil {
		t.Fatalf("%s must not exist: the dangling-destination case is what is under test", selfCopy)
	}

	direct := filepath.Join(home, "link-to-config")
	if err := os.Symlink(selfCopy, direct); err != nil {
		t.Fatal(err)
	}
	// A second hop, so a chain is followed and not merely the first link.
	chained := filepath.Join(home, "link-to-link")
	if err := os.Symlink(direct, chained); err != nil {
		t.Fatal(err)
	}
	// A RELATIVE destination, which is resolved against the directory holding
	// the link rather than against the cwd of whoever is reading it.
	relative := filepath.Join(home, "link-relative")
	if err := os.Symlink(filepath.Join("..", "relocated", "guardrails", "config.yml"), relative); err != nil {
		t.Fatal(err)
	}
	for name, target := range map[string]string{
		"a symlink aimed straight at the config-home copy": direct,
		"a two-hop symlink chain":                          chained,
		"a symlink with a relative destination":            relative,
	} {
		if d := fileToolVerdict(t, "Write", repo, target); d.Bucket == BucketAllow {
			t.Errorf("a write reaching the not-yet-created config-home copy via %s must not ALLOW; got %q (%s)",
				name, d.Bucket, d.Reason)
		}
	}

	// The negative control: a link of the same shape aimed one segment over, at
	// a file that is not this config and does not exist either. It stays an
	// ALLOW, so the rows above are the deny firing on the file each link reaches
	// and not on links being refused wholesale.
	other := filepath.Join(home, "link-to-other")
	if err := os.Symlink(filepath.Join(relocated, "guardrails", "other.yml"), other); err != nil {
		t.Fatal(err)
	}
	wantBucket(t, fileToolVerdict(t, "Write", repo, other), BucketAllow,
		"a write through a symlink aimed at a non-config file")
}

// TestOperatorCarveOutRefusesSelfWriteByCase varies LETTER CASE and nothing
// else. On a case-insensitive filesystem — the macOS default, so the default
// posture for this marketplace's own machines — `CONFIG.YML` names the very
// file `config.yml` does, and a comparison of canonicalized strings misses it
// (filepath.EvalSymlinks returns the caller's casing, not the name on disk), so
// the widest possible `**` entry handed out a write to the gate's own policy.
//
// The filesystem, not the test's guess about the platform, decides which
// assertion applies: an os.Stat of the varied spelling answers whether the two
// name one file here. Both branches assert, so neither platform is left
// unmeasured — and the case-sensitive branch is what pins that the fix did not
// widen the deny onto a genuinely different file.
func TestOperatorCarveOutRefusesSelfWriteByCase(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")
	writeCarveOutConfig(t, home, `schema-version: 2
config-home-default: ~/.config
home:
  write:
    - '**'
`)
	literal := filepath.Join(home, ".config", "guardrails", "config.yml")
	varied := filepath.Join(filepath.Dir(literal), "CONFIG.YML")

	// The baseline the varied spelling is measured against: the exact spelling
	// denies on every filesystem, so a deny below is about case and not about
	// the entry failing to cover the path at all.
	if d := fileToolVerdict(t, "Write", repo, literal); d.Bucket == BucketAllow {
		t.Fatalf("a write to the config file's own spelling must not ALLOW; got %q (%s)", d.Bucket, d.Reason)
	}

	d := fileToolVerdict(t, "Write", repo, varied)
	if _, err := os.Stat(varied); err == nil {
		if d.Bucket == BucketAllow {
			t.Errorf("a write to %q, which names the same file as %q on this filesystem, must not ALLOW; got %q (%s)",
				varied, literal, d.Bucket, d.Reason)
		}
		return
	}
	// Case-sensitive: the varied spelling names a file that does not exist and
	// is not this config, so the `**` entry covers it as it covers any other
	// path under home.
	wantBucket(t, d, BucketAllow, "a write to a case-varied name on a case-sensitive filesystem")
}

// TestOperatorCarveOutRefusesSelfWriteByCaseWhenAbsent is the case test above
// aimed at the config-home copy, which on a normal machine does NOT exist: one
// config file lives at the literal load path, and the copy under a relocated
// `config-home` is the spelling nothing has created.
//
// That absence is what made the case bypass reachable in the first place. An
// identity comparison that ran only when os.Stat of the target succeeded had
// nothing to say here, so the deny fell back to bare string equality — and a
// `home: write: ['**']` entry then handed out a write CREATING the gate's own
// policy file under a case-varied spelling. The exists-side test above cannot
// reach this: its target is the literal load path, which the carve-out has to
// have read to hold any entry at all.
//
// The filesystem decides which assertion applies, as above, but the probe has
// to be indirect: the varied spelling names nothing either way, so os.Stat of
// it answers nothing. The DIRECTORY holding it does exist, so a case-varied
// spelling of that directory is what reports the rule this volume applies.
func TestOperatorCarveOutRefusesSelfWriteByCaseWhenAbsent(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")

	relocated := filepath.Join(base, "relocated")
	selfDir := filepath.Join(relocated, "guardrails")
	if err := os.MkdirAll(selfDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv(xdgConfigHomeEnv, relocated)
	// The widest entry on the CONFIG-HOME root, so every spelling below sits
	// inside a root whose glob covers it. A `home` entry would not: the
	// relocated root is outside the fake home, so a deny there would be the
	// ordinary cross-repo one and would measure nothing about this deny.
	writeCarveOutConfig(t, home, `schema-version: 2
resolve-xdg-environment-variables: yes
config-home-default: ~/.config
config-home:
  write:
    - '**'
`)
	selfCopy := filepath.Join(selfDir, "config.yml")
	if _, err := os.Lstat(selfCopy); err == nil {
		t.Fatalf("%s must not exist: the ABSENT config-home copy is what is under test", selfCopy)
	}

	// The baseline: the exact spelling of the absent copy denies on every
	// filesystem, so a deny below is about case and not about the entry failing
	// to cover the path at all.
	if d := fileToolVerdict(t, "Write", repo, selfCopy); d.Bucket == BucketAllow {
		t.Fatalf("a write creating the config-home copy at its own spelling must not ALLOW; got %q (%s)",
			d.Bucket, d.Reason)
	}

	for _, varied := range []string{
		filepath.Join(selfDir, "CONFIG.YML"),                 // final segment only
		filepath.Join(relocated, "GUARDRAILS", "config.yml"), // the directory segment
		filepath.Join(relocated, "GuardRails", "Config.Yml"), // both, mixed
	} {
		d := fileToolVerdict(t, "Write", repo, varied)
		if caseFoldingFilesystem(t, selfDir) {
			if d.Bucket == BucketAllow {
				t.Errorf("a write to %q, which creates the same file as %q on this filesystem, must not ALLOW; got %q (%s)",
					varied, selfCopy, d.Bucket, d.Reason)
			}
			continue
		}
		// Case-sensitive: the varied spelling creates a file that is not this
		// config, so the `**` entry covers it as it covers any other path.
		wantBucket(t, d, BucketAllow, "a write to a case-varied name on a case-sensitive filesystem")
	}

	// The negative control, on both kinds of filesystem: a sibling name that
	// differs by more than case still ALLOWs, so the rows above are the deny
	// firing on the file each spelling creates and not on absent targets under
	// this directory being refused wholesale.
	wantBucket(t, fileToolVerdict(t, "Write", repo, filepath.Join(selfDir, "other.yml")), BucketAllow,
		"a write creating a non-config file beside the absent copy")
}

// caseFoldingFilesystem reports whether the volume holding dir folds letter
// case. The test needs the answer because the paths it varies do not exist, so
// the os.Stat the exists-side test uses to pick a branch answers nothing there.
//
// It asks dirFoldsCase — the production predicate the deny itself branches on
// — rather than probing again here. A second probe would let the test agree
// with the gate on this machine and disagree on the next, which is the one
// thing a case-sensitivity fixture must not do.
//
// The stat is the fixture's own precondition, not part of the question:
// dirFoldsCase answers true for a directory it cannot reach, which would make
// the rows below pass for the wrong reason.
func caseFoldingFilesystem(t *testing.T, dir string) bool {
	t.Helper()
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("stat %s: %v", dir, err)
	}
	return dirFoldsCase(dir)
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
// the read on the listed result testContainmentFrom returns beside the region,
// which is how the read keeps its `.git`-tree deny although the region never
// reports a `.git/` target as operatorListed. Each fixture lists the widest
// thing the schema can express — `**` on the HOME root, which now covers
// everything the other two roots do — and the non-`.git/` read at the end is
// the negative control that the deny is the `.git/` rule rather than a missing
// listing.
//
// The `.GIT` spelling runs beside `.git` on every platform: a case-folding
// volume resolves it to the same directory while the canonical path keeps the
// spelling as written, so a case-sensitive segment match would let the listing
// hand out the tree there. The paths do not exist, so the rows measure the
// match and not the filesystem.
//
// Both listing keys are run. `read` is the one that puts the read deny
// against a listing that names it directly, and `write` reaches the same read
// deny only through write-implies-read while being the only key that lists
// the write rule's target at all — so neither key on its own covers both.
func TestOperatorCarveOutDoesNotOpenGitTree(t *testing.T) {
	for _, listing := range []string{"read", "write"} {
		t.Run(listing, func(t *testing.T) {
			base := t.TempDir()
			repo := filepath.Join(base, "repo")
			gitInit(t, repo)
			home := carveOutFixture(t, base, "repo")
			writeCarveOutConfig(t, home, "schema-version: 2\nhome:\n  "+listing+":\n    - '**'\n")

			for _, rel := range []string{
				filepath.Join(".config", "cc-tools", ".git", "config"),
				filepath.Join(".local", "state", "sdlc", ".git", "config"),
				filepath.Join(".config", "cc-tools", ".GIT", "config"),
				filepath.Join(".local", "state", "sdlc", ".GIT", "config"),
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
		})
	}
}

// The glob grammar: `**` spans whole segments, a plain `*` does not cross a
// separator, and an exact entry matches only itself. shell marks a remainder
// read as a Bash operand, where a metacharacter is a pattern the shell will
// expand; a file-tool path carries the same characters as a literal filename.
func TestMatchCarveOutGlob(t *testing.T) {
	cases := []struct {
		glob  string
		rem   string
		shell bool
		want  bool
	}{
		{"cc-tools/**", "cc-tools/whats-new.md", false, true},
		{"cc-tools/**", "cc-tools/a/b/c.md", false, true},
		{"cc-tools/**", "cc-tools", false, true},
		{"cc-tools/**", "cc-toolsx/a.md", false, false},
		{"cc-tools/**", "issues/a.md", false, false},
		{"gh/config.yml", "gh/config.yml", false, true},
		{"gh/config.yml", "gh/config.yml.bak", false, false},
		{"gh/config.yml", "gh/hosts/config.yml", false, false},
		{"gh/*", "gh/config.yml", false, true},
		{"gh/*", "gh/hosts/config.yml", false, false},
		{"**", "anything/at/all", false, true},
		{"../**", "cc-tools/a.md", false, false},
		// A Bash remainder segment that is a bare `*` is covered only by `*` or
		// a spanning `**`, never by a narrower glob or its own text.
		{"cc-tools/*", "cc-tools/sub/*", true, false},
		{"cc-tools/**", "cc-tools/sub/*", true, true},
		{"cc-tools/sub/*", "cc-tools/sub/*", true, true},
		{"cc-tools/sub/*.md", "cc-tools/sub/*", true, false},
		{"cc-tools/sub/?", "cc-tools/sub/*", true, false},
		{"cc-tools/**/x.md", "cc-tools/sub/*", true, false},
		{"cc-tools/*/*", "cc-tools/*/x.md", true, true},
		// Any other metacharacter segment fails closed against every entry
		// segment; shellOperandListable keeps such an operand from reaching the
		// matcher at all, and the matcher does not model it either.
		{"cc-tools/sub/*", "cc-tools/sub/*.md", true, false},
		{"cc-tools/sub/*.md", "cc-tools/sub/*.md", true, false},
		{"cc-tools/sub/*", "cc-tools/sub/?.md", true, false},
		{"cc-tools/*/x.md", "cc-tools/**/x.md", true, false},
		{"cc-tools/*", "cc-tools/a**", true, false},
		{"sdlc/pr*/notes.md", "sdlc/pr[1]/notes.md", true, false},
		// The same remainders as file-tool paths are literal filenames, and the
		// entry covers each or not on its text alone.
		{"sdlc/pr*/notes.md", "sdlc/pr[1]/notes.md", false, true},
		{"cc-tools/sub/*.md", "cc-tools/sub/*.md", false, true},
		{"cc-tools/*/x.md", "cc-tools/**/x.md", false, true},
	}
	for _, tc := range cases {
		if got := matchCarveOutGlob(tc.glob, tc.rem, tc.shell); got != tc.want {
			t.Errorf("matchCarveOutGlob(%q, %q, %v) = %v, want %v", tc.glob, tc.rem, tc.shell, got, tc.want)
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
		t.Errorf("expected every root this config spells to resolve; got %+v", c)
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

	// A relative `<root>-default` is not a usable spelling: the remainder would
	// otherwise depend on the calling session's cwd. The root is dropped rather
	// than resolved against anything, which the state-home root — spelled
	// absolutely in the same file — separates from a whole-file failure.
	if err := os.WriteFile(path, []byte(
		"schema-version: 2\nconfig-home-default: .config\nstate-home-default: ~/.local/state\n"+
			"config-home:\n  write:\n    - cc-tools/**\nstate-home:\n  write:\n    - sdlc/**\n"),
		0o644); err != nil {
		t.Fatal(err)
	}
	c = loadOperatorCarveOutFrom(path)
	if len(c.roots) != 1 {
		t.Fatalf("a relative config-home-default must drop that root; got %+v", c)
	}
	if want := filepath.Join(home, ".local", "state"); c.roots[0].path != want {
		t.Errorf("the surviving root = %q, want the state home %q", c.roots[0].path, want)
	}
	// Dropping the root also drops its config-file spelling from the self-write
	// list, leaving only the literal load path.
	if len(c.selfWritePaths) != 1 || c.selfWritePaths[0] != path {
		t.Errorf("expected only the literal load path as a self-write path; got %+v", c.selfWritePaths)
	}

	// `~someone/config` is a username reference this gate does not resolve, so
	// it is still relative when the absolute test runs and the root drops on
	// exactly the same terms as `.config` above. Only `~` and `~/` expand, and
	// the README says so where it says a default spelling may start with `~`.
	if err := os.WriteFile(path, []byte(
		"schema-version: 2\nconfig-home-default: ~someone/config\nstate-home-default: ~/.local/state\n"+
			"config-home:\n  write:\n    - cc-tools/**\nstate-home:\n  write:\n    - sdlc/**\n"),
		0o644); err != nil {
		t.Fatal(err)
	}
	c = loadOperatorCarveOutFrom(path)
	if len(c.roots) != 1 {
		t.Fatalf("a `~someone`-spelled config-home-default must drop that root; got %+v", c)
	}
	if want := filepath.Join(home, ".local", "state"); c.roots[0].path != want {
		t.Errorf("the surviving root = %q, want the state home %q", c.roots[0].path, want)
	}

	// A stamp ABOVE the pin is read for the keys this version documents:
	// newer schema versions are additive.
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

// bashCarveOutSpellings are the Bash spellings of one read or write, chosen so
// that every Bash containment caller is reached: `cat`, `ls` and `less` reach
// containPathOperands (the read-only-utility and path-reader tracks), `tee`
// and `cp` reach containWriteOperands, a plain redirect reaches
// redirectVetoesAllow, the `git`, `gh` and `aws` redirects reach
// credentialedRedirectVerdict from each program that calls it — `gh` calls it
// from every arm of its own that allows, and one row reaches each: the
// read-only subcommand, `auth status`, a recoverable own-repo write, a
// query-only `api graphql` document, an allow-listed `api graphql` mutation
// and an allow-listed `api` REST GET — an
// input redirect on a construct that runs no program reaches
// classifyRedirectOnly's own direct call into containPathOperands, an input
// redirect on a write-class program reaches containReadSources' walk into
// containPathOperands — the read-source grading of the write track, which the
// `tee` and `cp` rows reach with no source to grade because they hand the path
// over as the write target — an input redirect on `tee /dev/null` reaches the
// branch of classifyReadOnlyUtility for a utility that is not pathBearing,
// whose read list is the input redirects alone, and a `for` loop reaches
// containPathOperands through the loop variable rather than as an operand
// written out. write says whether the spelling writes the path, which is what
// decides its verdict against a `read`-only entry.
//
// One containment caller is absent by design: a `gh` publish verb's body file
// (ghPublishedFileEscalates, classify_gh_files.go) also reaches
// containReadSources, but that site discards the listing's ALLOW and keeps
// only an escape, so a listed body file removes the cross-repo deny and leaves
// the verb's own tier to decide — a verdict shape neither table here asserts.
// TestOperatorCarveOutGhPublishBodyFile pins it.
var bashCarveOutSpellings = []struct {
	name  string
	cmd   func(p string) string
	write bool
}{
	{"cat", func(p string) string { return "cat " + p }, false},
	{"ls", func(p string) string { return "ls " + filepath.Dir(p) }, false},
	{"less", func(p string) string { return "less " + p }, false},
	{"tee", func(p string) string { return "tee " + p }, true},
	{"cp", func(p string) string { return "cp README.md " + p }, true},
	{"redirect", func(p string) string { return "echo x > " + p }, true},
	{"git redirect", func(p string) string { return "git log > " + p }, true},
	{"gh redirect", func(p string) string { return "gh pr diff 224 > " + p }, true},
	{"gh auth status redirect", func(p string) string { return "gh auth status > " + p }, true},
	{"gh write redirect", func(p string) string { return "gh issue comment 5 --body hi > " + p }, true},
	{"gh graphql query redirect", func(p string) string {
		return "gh api graphql -f query='query { viewer { login } }' > " + p
	}, true},
	{"gh graphql mutation redirect", func(p string) string {
		return "gh api graphql -f query='mutation { addSubIssue(input: {}) { clientMutationId } }' > " + p
	}, true},
	{"gh api GET redirect", func(p string) string { return "gh api repos/o/r > " + p }, true},
	{"aws redirect", func(p string) string { return "aws s3 ls > " + p }, true},
	{"redirect-only", func(p string) string { return "[[ -f x ]] < " + p }, false},
	{"write-track source", func(p string) string { return "tee README.md < " + p }, false},
	{"non-path-bearing source", func(p string) string { return "tee /dev/null < " + p }, false},
	{"for loop", func(p string) string { return "for f in " + p + `; do cat "$f"; done` }, false},
}

// listedCarveOutPaths are the listed paths the Bash tables run: one under the
// state home and one under the config home, both under a `write` entry.
func listedCarveOutPaths(home string) []string {
	return []string{
		filepath.Join(home, ".local", "state", "sdlc", "round.log"),
		filepath.Join(home, ".config", "cc-tools", "whats-new.md"),
	}
}

// The Bash half of the listing: a path the operator listed is reachable from
// every Bash spelling that grades it, from the repo root and from a linked
// worktree alike, and the allow reason names the listing. Each spelling runs
// first with no config file, which must not allow — the negative control that
// the allow comes from the listing and not from the track's own terminal.
func TestOperatorCarveOutReachesBashTracks(t *testing.T) {
	for _, cwdShape := range []string{"repo root", "worktree"} {
		t.Run(cwdShape, func(t *testing.T) {
			base := t.TempDir()
			var cwd string
			if cwdShape == "worktree" {
				_, cwd = setupWorktree(t)
			} else {
				repo := filepath.Join(base, "repo")
				gitInit(t, repo)
				cwd = canonicalize(repo)
			}
			home := carveOutFixture(t, base, "repo")
			ev := bashEvIn(t, cwd, "issue-developer")

			for _, target := range listedCarveOutPaths(home) {
				for _, sp := range bashCarveOutSpellings {
					cmd := sp.cmd(target)
					if d := classifyBash(cmd, ev); d.Bucket == BucketAllow {
						t.Errorf("%s with no carve-out configured must not ALLOW; got %q (%s)", cmd, d.Bucket, d.Reason)
					}
				}
			}

			writeCarveOutConfig(t, home, carveOutConfig)
			for _, target := range listedCarveOutPaths(home) {
				for _, sp := range bashCarveOutSpellings {
					cmd := sp.cmd(target)
					d := classifyBash(cmd, ev)
					wantBucket(t, d, BucketAllow, cmd+" of a listed path")
					if !containsSubstr(d.Reason, filepath.Join(home, ".config", "guardrails", "config.yml")) {
						t.Errorf("%s: the allow reason should name the operator's config file; got %q", cmd, d.Reason)
					}
				}
			}
		})
	}
}

// The listing's bounds hold on the Bash tracks exactly as on the file-tool
// one: an unlisted sibling under a listed root, a write against a `read`-only
// entry, a listed path with a `.git/` segment, and a write to the config file
// itself each keep the verdict the same spelling has with no config file. The
// Bash tracks add the operand rule (shellOperandListable): a bare `*` segment
// withholds the listing wherever it sits, since `dotglob` lets it expand to
// `.git`, and every other expansion syntax — a `?`, a bracket expression, a
// POSIX class, a brace group, a `**` — withholds it whether or not the shell
// would reach `.git` through it, as does a `..` segment in the operand as
// written, which filepath.Clean would otherwise fold into a listed name the
// shell never opens. The read of the `read`-only entry and of the config file
// are the negative controls that the listing is in force and the denies are
// its bounds.
func TestOperatorCarveOutBashBounds(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")
	ev := bashEvIn(t, canonicalize(repo), "issue-developer")

	// `guardrails/**` under config-home `write` is what puts the config file
	// itself inside a listing, which is the only way the self-write deny is
	// reached; `gh/config.yml` stays under `read` alone. `cc-tools/x.md` is the
	// exact entry the `..` rows fold onto once cleaned.
	const config = `schema-version: 2
config-home-default: ~/.config
state-home-default: ~/.local/state
config-home:
  read:
    - gh/config.yml
  write:
    - guardrails/**
    - cc-tools/x.md
state-home:
  write:
    - sdlc/**
`
	rows := []struct {
		label string
		path  string
		// writeOnly marks a row that bounds the write spellings only: its
		// read spellings must ALLOW, which is the negative control.
		writeOnly bool
	}{
		{"unlisted sibling", filepath.Join(home, ".local", "state", "other", "x"), false},
		{"read-only entry", filepath.Join(home, ".config", "gh", "config.yml"), true},
		{".git segment", filepath.Join(home, ".local", "state", "sdlc", ".git", "config"), false},
		{".g*t segment", filepath.Join(home, ".local", "state", "sdlc", ".g*t", "config"), false},
		{".g?t segment", filepath.Join(home, ".local", "state", "sdlc", ".g?t", "config"), false},
		{".[g]it segment", filepath.Join(home, ".local", "state", "sdlc", ".[g]it", "config"), false},
		{".G*T segment", filepath.Join(home, ".local", "state", "sdlc", ".G*T", "config"), false},
		{"bare * segment", filepath.Join(home, ".local", "state", "sdlc", "*", "config"), false},
		{".[[:alpha:]]it segment", filepath.Join(home, ".local", "state", "sdlc", ".[[:alpha:]]it", "config"), false},
		{".g[[:alpha:]]t segment", filepath.Join(home, ".local", "state", "sdlc", ".g[[:alpha:]]t", "config"), false},
		{".{git,x} segment", filepath.Join(home, ".local", "state", "sdlc", ".{git,x}", "config"), false},
		{"{.git,x} segment", filepath.Join(home, ".local", "state", "sdlc", "{.git,x}", "config"), false},
		// Spelled by concatenation: filepath.Join would fold the `..` away
		// before the gate ever saw it.
		{"** then ..", home + "/.config/cc-tools/**/../x.md", false},
		{"literal then ..", home + "/.config/cc-tools/sub/../x.md", false},
		{"config file itself", filepath.Join(home, ".config", "guardrails", "config.yml"), true},
	}

	// Today's verdicts, taken before any config exists.
	today := map[string]Decision{}
	for _, r := range rows {
		for _, sp := range bashCarveOutSpellings {
			cmd := sp.cmd(r.path)
			today[cmd] = classifyBash(cmd, ev)
		}
	}

	writeCarveOutConfig(t, home, config)
	for _, r := range rows {
		for _, sp := range bashCarveOutSpellings {
			cmd := sp.cmd(r.path)
			d := classifyBash(cmd, ev)
			if r.writeOnly && !sp.write {
				// `ls` reads the parent directory, which an exact entry such as
				// `gh/config.yml` does not list, so it is no control here.
				if sp.name != "ls" {
					wantBucket(t, d, BucketAllow, cmd+" (read of a listed path, negative control)")
				}
				continue
			}
			if d.Bucket == BucketAllow {
				t.Errorf("%s (%s) must not ALLOW; got %q (%s)", cmd, r.label, d.Bucket, d.Reason)
			}
			if want := today[cmd]; d.Bucket != want.Bucket || d.Operation != want.Operation {
				t.Errorf("%s (%s) must keep today's verdict %q/%q; got %q/%q (%s)",
					cmd, r.label, want.Bucket, want.Operation, d.Bucket, d.Operation, d.Reason)
			}
		}
	}
}

// A tilde the gate does not expand rides no listing. expand.Literal expands
// `~` and `~/…` and hands `~+`, `~-`, `~user` and `~N` back untouched, so the
// operand the gate holds is the literal spelling, and lexicalAbs joins it onto
// the cwd as a literal segment — `<cwd>/~+/…` — where bash and zsh both open
// `$PWD/…`, `$OLDPWD/…` or the named user's home. Under `home: write: ['**']`
// from a cwd of `$HOME`, `cat malicious.yml > ~+/.config/guardrails/config.yml`
// is the config file itself to the shell, while the literal
// `<home>/~+/.config/guardrails/config.yml` matches the `**` entry and slips
// the self-write deny, which compares the same literal. Every write spelling of
// each such target keeps the verdict it has with no config file. The home is a
// git repository because the whole-line classifier reaches the listing only
// with a repo context, which also makes the literal `<home>/~+/…` an in-repo
// write: the operand tracks allow it with no config file, so the plain
// redirect — which in-repo defers until a listing lifts the veto — is the
// spelling whose no-config verdict the listing alone can move, and the test
// checks that it starts out withheld. The `~/`-spelled write beside the rows is
// the negative control that the listing is in force.
func TestOperatorCarveOutWithholdsOtherTildeForms(t *testing.T) {
	base := t.TempDir()
	home := carveOutFixture(t, base, "plain")
	gitInit(t, home)
	// The cwd is the home as $HOME spells it, not canonicalized: a relative
	// operand is joined onto the cwd lexically, and the home root is matched
	// as a prefix of that spelling.
	ev := bashEvIn(t, home, "issue-developer")

	rows := []string{
		"~+/.config/guardrails/config.yml",
		"~-/.config/guardrails/config.yml",
		"~someone/.config/guardrails/config.yml",
	}
	today := map[string]Decision{}
	for _, p := range rows {
		for _, sp := range bashCarveOutSpellings {
			if !sp.write {
				continue
			}
			cmd := sp.cmd(p)
			today[cmd] = classifyBash(cmd, ev)
			if sp.name == "redirect" && today[cmd].Bucket == BucketAllow {
				t.Fatalf("%s with no carve-out configured must not ALLOW, or the row proves nothing; got %q (%s)",
					cmd, today[cmd].Bucket, today[cmd].Reason)
			}
		}
	}

	writeCarveOutConfig(t, home, "schema-version: 2\nhome:\n  write:\n    - '**'\n")
	control := "echo x > ~/.config/other/x.yml"
	wantBucket(t, classifyBash(control, ev), BucketAllow, control+" (negative control)")
	for _, p := range rows {
		for _, sp := range bashCarveOutSpellings {
			if !sp.write {
				continue
			}
			cmd := sp.cmd(p)
			d := classifyBash(cmd, ev)
			if want := today[cmd]; d.Bucket != want.Bucket || d.Operation != want.Operation {
				t.Errorf("%s must keep today's verdict %q/%q; got %q/%q (%s)",
					cmd, want.Bucket, want.Operation, d.Bucket, d.Operation, d.Reason)
			}
		}
	}
}

// An operand rides the listing only when it opens as a plain literal path,
// and any other opening is withheld without being named
// (shellOperandListable). `=ls` is the case that fixed the rule's direction:
// it carries no metacharacter, no `..` and no tilde, so a rule that named
// what it withholds admitted it as the literal `<cwd>/=ls`, while zsh's
// equals expansion opens `/bin/ls` — a file outside every root the listing
// has. `%x` and `!x` are two more openings the rule never names, and every
// spelling of each keeps the verdict it has with no config file. The cwd is
// the home, as $HOME spells it, because the operand has to be relative for
// its first character to be the word's, and the home is a git repository
// because the whole-line classifier reaches the listing only with a repo
// context. That makes most spellings in-repo reads and writes the tracks
// allow with no config file; the two that in-repo defer until a listing
// lifts them — the plain redirect (redirectVetoesAllow) and the `less` pager
// (classifyPathReader), one write-class and one read-class — are the
// whole-line spellings whose verdict the listing alone can move, and the test
// checks that each starts out withheld. Both classes are pinned at the
// listing itself as well, where a `*` entry that covers every bare filename
// still answers no for each row. The `-` and `.` openings beside them are
// the negative control that a filename character zsh gives no meaning to
// still rides, and that the listing is in force.
func TestOperatorCarveOutWithholdsNonPathOpening(t *testing.T) {
	base := t.TempDir()
	home := carveOutFixture(t, base, "plain")
	gitInit(t, home)
	ev := bashEvIn(t, home, "issue-developer")

	rows := []string{"=ls", "%x", "!x"}
	controls := []string{"-x", ".x"}
	movable := map[string]bool{"redirect": true, "less": true}
	today := map[string]Decision{}
	for _, p := range rows {
		for _, sp := range bashCarveOutSpellings {
			cmd := sp.cmd(p)
			today[cmd] = classifyBash(cmd, ev)
			if movable[sp.name] && today[cmd].Bucket == BucketAllow {
				t.Fatalf("%s with no carve-out configured must not ALLOW, or the row proves nothing; got %q (%s)",
					cmd, today[cmd].Bucket, today[cmd].Reason)
			}
		}
	}
	// `less -x` hands the pager an option rather than an operand, so that
	// spelling is no control for the `-` opening.
	isControl := func(sp string, p string) bool {
		return movable[sp] && !(sp == "less" && p == "-x")
	}
	for _, p := range controls {
		for _, sp := range bashCarveOutSpellings {
			if !isControl(sp.name, p) {
				continue
			}
			cmd := sp.cmd(p)
			if d := classifyBash(cmd, ev); d.Bucket == BucketAllow {
				t.Fatalf("%s with no carve-out configured must not ALLOW, or the control proves nothing; got %q (%s)",
					cmd, d.Bucket, d.Reason)
			}
		}
	}

	writeCarveOutConfig(t, home, "schema-version: 2\nhome:\n  read:\n    - '*'\n  write:\n    - '*'\n")
	for _, p := range controls {
		for _, sp := range bashCarveOutSpellings {
			if !isControl(sp.name, p) {
				continue
			}
			cmd := sp.cmd(p)
			wantBucket(t, classifyBash(cmd, ev), BucketAllow, cmd+" (negative control)")
		}
	}
	for _, p := range rows {
		for _, sp := range bashCarveOutSpellings {
			cmd := sp.cmd(p)
			d := classifyBash(cmd, ev)
			if want := today[cmd]; d.Bucket != want.Bucket || d.Operation != want.Operation {
				t.Errorf("%s must keep today's verdict %q/%q; got %q/%q (%s)",
					cmd, want.Bucket, want.Operation, d.Bucket, d.Operation, d.Reason)
			}
		}
	}

	c := loadOperatorCarveOut()
	for _, p := range controls {
		if !c.allows(p, home, true, true, false) {
			t.Errorf("read of %s must ride the `*` entry (negative control)", p)
		}
	}
	for _, p := range rows {
		for _, readClass := range []bool{true, false} {
			if c.allows(p, home, readClass, true, false) {
				t.Errorf("%s (readClass=%v) must ride no listing", p, readClass)
			}
		}
	}
}

// The plain-path rule reads every segment, not only the word's opening
// (shellOperandListable): a segment rides the listing only when it is `*`
// alone or spelled in letters, digits, `.`, `_` and `-`, and any other
// character in it is withheld without being named. `ab#` and `a^b` are the
// rows that hold the rule to every character: each opens with a letter and
// carries none of the glob metacharacters `*?[{`, so a rule that named those
// would admit both as one literal file each, while zsh under `extendedglob`
// reads `#` as zero-or-more repetition and `^` as not-match — with `a`,
// `ab`, `abb`, `abbb` and `b` on disk, `echo ab#` prints `a ab abb abbb`
// and `echo a^b` prints `a abb abbb`. `a~b` is a tilde past
// the opening, and `x/a^b` carries its operator in a second segment. Every
// spelling of each keeps the verdict it has with no config file, under the
// same fixture and for the same reasons as
// TestOperatorCarveOutWithholdsNonPathOpening. The `-`- and `.`-bearing
// literals beside them, one and two segments deep, are the negative control
// that a filename character zsh gives no meaning to still rides, and that
// the listing is in force.
func TestOperatorCarveOutWithholdsNonPlainSegment(t *testing.T) {
	base := t.TempDir()
	home := carveOutFixture(t, base, "plain")
	gitInit(t, home)
	ev := bashEvIn(t, home, "issue-developer")

	rows := []string{"ab#", "a^b", "a~b", "x/a^b"}
	controls := []string{"a-b.c", "x/a-b.c"}
	movable := map[string]bool{"redirect": true, "less": true}
	today := map[string]Decision{}
	for _, p := range rows {
		for _, sp := range bashCarveOutSpellings {
			cmd := sp.cmd(p)
			today[cmd] = classifyBash(cmd, ev)
			if movable[sp.name] && today[cmd].Bucket == BucketAllow {
				t.Fatalf("%s with no carve-out configured must not ALLOW, or the row proves nothing; got %q (%s)",
					cmd, today[cmd].Bucket, today[cmd].Reason)
			}
		}
	}
	for _, p := range controls {
		for _, sp := range bashCarveOutSpellings {
			if !movable[sp.name] {
				continue
			}
			cmd := sp.cmd(p)
			if d := classifyBash(cmd, ev); d.Bucket == BucketAllow {
				t.Fatalf("%s with no carve-out configured must not ALLOW, or the control proves nothing; got %q (%s)",
					cmd, d.Bucket, d.Reason)
			}
		}
	}

	writeCarveOutConfig(t, home, "schema-version: 2\nhome:\n  read:\n    - '**'\n  write:\n    - '**'\n")
	for _, p := range controls {
		for _, sp := range bashCarveOutSpellings {
			if !movable[sp.name] {
				continue
			}
			cmd := sp.cmd(p)
			wantBucket(t, classifyBash(cmd, ev), BucketAllow, cmd+" (negative control)")
		}
	}
	for _, p := range rows {
		for _, sp := range bashCarveOutSpellings {
			cmd := sp.cmd(p)
			d := classifyBash(cmd, ev)
			if want := today[cmd]; d.Bucket != want.Bucket || d.Operation != want.Operation {
				t.Errorf("%s must keep today's verdict %q/%q; got %q/%q (%s)",
					cmd, want.Bucket, want.Operation, d.Bucket, d.Operation, d.Reason)
			}
		}
	}

	c := loadOperatorCarveOut()
	for _, p := range controls {
		if !c.allows(p, home, true, true, false) {
			t.Errorf("read of %s must ride the `**` entry (negative control)", p)
		}
	}
	for _, p := range rows {
		for _, readClass := range []bool{true, false} {
			if c.allows(p, home, readClass, true, false) {
				t.Errorf("%s (readClass=%v) must ride no listing", p, readClass)
			}
		}
	}
}

// patternMayNameGitDir holds a metacharacter segment to every expansion any
// shell can give it, on its own and not by way of shellOperandListable having
// screened the operand: the canonical path it reads can carry a segment the
// operand as written never had, a symlink's target name among them. A bracket
// expression is counted whatever it spells, since path.Match reads
// `.[[:alpha:]]it` as a set that misses `g` while bash expands it to `.git`.
// The segments that cannot reach `.git` under any setting are the negative
// control that the predicate reads the pattern rather than the metacharacter.
func TestPatternMayNameGitDir(t *testing.T) {
	for _, r := range []struct {
		seg  string
		want bool
	}{
		{".git", false},
		{".g*t", true},
		{".g?t", true},
		{".G*T", true},
		{"*", true},
		{".[g]it", true},
		{".[[:alpha:]]it", true},
		{".g[[:alpha:]]t", true},
		{"[x]", true},
		{"x*", false},
		{"a?c", false},
	} {
		p := filepath.Join(string(filepath.Separator), "home", "sdlc", r.seg, "config")
		if got := patternMayNameGitDir(p); got != r.want {
			t.Errorf("patternMayNameGitDir(%q) = %v, want %v", p, got, r.want)
		}
	}
}

// The `gh` publish-file site: a listed body file is no longer the cross-repo
// escape it is with no config, and it is not an ALLOW on the listing's account
// either — containReadSources discards that, and the verb's own tier decides.
// The negative control is the same command with no config file, which the
// escape deny takes. A classifier test only: no `gh` verb runs.
func TestOperatorCarveOutGhPublishBodyFile(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")
	ev := bashEvIn(t, canonicalize(repo), "issue-developer")

	cmd := "gh pr create --title x --body-file " + filepath.Join(home, ".local", "state", "sdlc", "body.md")

	d := classifyBash(cmd, ev)
	if d.Bucket != BucketDeny || d.Operation != "bash-read:cross-repo" {
		t.Errorf("%s with no carve-out configured must deny as a cross-repo read; got %q/%q (%s)",
			cmd, d.Bucket, d.Operation, d.Reason)
	}

	writeCarveOutConfig(t, home, carveOutConfig)
	d = classifyBash(cmd, ev)
	if d.Bucket == BucketDeny && d.Operation == "bash-read:cross-repo" {
		t.Errorf("%s of a listed body file must not deny as a cross-repo read; got %q/%q (%s)",
			cmd, d.Bucket, d.Operation, d.Reason)
	}
}

// The in-repo half of the `.git/` rule: a listing wide enough to cover the
// repository itself — `**` on the HOME root, with the repo under $HOME — must
// not carry a `Read` of the repo's own `.git/` tree, and it must deny it
// outright rather than leave it on the defer an unlisted in-repo `.git/` read
// keeps. The `.git/` target resolves as contained, so this is the row the
// listed result exists for: the region alone would report nothing to deny on.
// The `.GIT` spelling runs beside it, on the same grounds as above. The read of
// a working file in the same repo is the negative control that the listing is
// in force and the deny is the `.git/` rule.
func TestOperatorCarveOutDoesNotOpenInRepoGitTree(t *testing.T) {
	base := t.TempDir()
	home := carveOutFixture(t, base, "plain")
	repo := filepath.Join(home, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeCarveOutConfig(t, home, "schema-version: 2\nhome:\n  write:\n    - '**'\n")

	for _, rel := range []string{
		filepath.Join(".git", "config"),
		filepath.Join(".GIT", "config"),
	} {
		d := fileToolVerdict(t, "Read", repo, filepath.Join(repo, rel))
		wantBucket(t, d, BucketDeny, "Read of the listed repo's own "+rel)
		if !containsSubstr(d.Operation, "read:.git tree") {
			t.Errorf("Read of %s should deny as the .git-tree rule; got op %q (%s)", rel, d.Operation, d.Reason)
		}
	}

	d := fileToolVerdict(t, "Read", repo, filepath.Join(repo, "README.md"))
	wantBucket(t, d, BucketAllow, "read of a working file in the listed repo (negative control)")
}

// The Bash-track allow reasons name the operator listing exactly as the
// file-tool one does: only when a target of the command rode it. A command
// that never touched a listed path — a write to a fresh in-repo file, and a
// line of such parts — must not carry the listing in its reason, with the
// config file present and every listing in force; the same spellings against a
// listed path are the negative control that the wording is gated and not
// dropped. Both terminals are covered, and separately: the whole-line reason
// is classifyBash's own, built after the per-part reasons are discarded, so
// the in-repo write terminal (classifyInRepoWrite) is called directly for its
// own wording, as the aggregate never surfaces it.
func TestOperatorCarveOutNamedOnlyWhenRidden(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	home := carveOutFixture(t, base, "repo")
	writeCarveOutConfig(t, home, carveOutConfig)
	ev := bashEvIn(t, canonicalize(repo), "issue-developer")
	configPath := filepath.Join(home, ".config", "guardrails", "config.yml")

	for _, cmd := range []string{
		"touch newfile.txt",
		"cp README.md copy.md",
		"cat README.md",
		"cat README.md && touch newfile.txt",
	} {
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketAllow, cmd)
		if containsSubstr(d.Reason, configPath) {
			t.Errorf("%s touched no listed path, so its reason must not name the listing; got %q", cmd, d.Reason)
		}
	}

	listed := filepath.Join(home, ".local", "state", "sdlc", "round.log")
	for _, cmd := range []string{
		"touch " + listed,
		"cp README.md " + listed,
		"cat " + listed,
		"cat README.md && touch " + listed,
	} {
		d := classifyBash(cmd, ev)
		wantBucket(t, d, BucketAllow, cmd)
		if !containsSubstr(d.Reason, configPath) {
			t.Errorf("%s rode the listing, so its reason must name it (negative control); got %q", cmd, d.Reason)
		}
	}

	inRepoWrite := func(args ...string) Decision {
		sc := simpleCommand{args: append([]string{"touch"}, args...)}
		return classifyInRepoWrite("touch", args, sc, ev)
	}
	d := inRepoWrite("newfile.txt")
	wantBucket(t, d, BucketAllow, "touch newfile.txt (in-repo write terminal)")
	if containsSubstr(d.Reason, configPath) {
		t.Errorf("the in-repo write terminal must not name a listing no operand rode; got %q", d.Reason)
	}
	d = inRepoWrite(listed)
	wantBucket(t, d, BucketAllow, "touch <listed> (in-repo write terminal)")
	if !containsSubstr(d.Reason, configPath) {
		t.Errorf("the in-repo write terminal must name the listing its operand rode (negative control); got %q",
			d.Reason)
	}
}

// A glob operand under a listed directory, looped over or written directly,
// rides no listing, whatever the entry covers: shellOperandListable admits a
// bare `*` segment alone, and patternMayNameGitDir withholds that one wherever
// it sits, since `dotglob` lets it expand to `.git`. The direct read of a file
// under the same directory runs beside each glob, and allows under every entry
// that lists it — the negative control that the listing is in force and the
// glob's verdict is the rule's. Both run first with no config file, the control
// that the direct allow comes from the listing.
//
// The patterns table spells each expansion syntax the rule withholds — a bare
// `*`, a `*` with a suffix, a `?`, a bracket expression, a `**`, and a `..`
// segment — on the widest entry there is. A brace group runs on its own: a
// `for` list is the one place the gate splits it (staticForItems), into
// literal items the listing grades one by one, so the loop spelling allows and
// only the direct spelling reaches the operand tracks as one unsplit word.
func TestOperatorCarveOutLoopOverListedDirectory(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")
	ev := bashEvIn(t, canonicalize(repo), "issue-developer")

	dir := filepath.Join(home, ".config", "cc-tools", "sub")
	loopOver := func(pattern string) string { return "for f in " + pattern + `; do cat "$f"; done` }
	loop := loopOver(filepath.Join(dir, "*"))
	direct := "cat " + filepath.Join(dir, "a.md")

	for _, cmd := range []string{loop, direct} {
		if d := classifyBash(cmd, ev); d.Bucket == BucketAllow {
			t.Errorf("%s with no carve-out configured must not ALLOW; got %q (%s)", cmd, d.Bucket, d.Reason)
		}
	}

	rows := []struct {
		entry string
		// directAllow is the negative control: every entry that lists the file
		// allows the direct read.
		directAllow bool
	}{
		{"cc-tools/*", false},
		{"cc-tools/**", true},
		{"cc-tools/sub/*", true},
		{"cc-tools/sub/*.md", true},
		{"cc-tools/sub/?.md", true},
	}
	for _, r := range rows {
		writeCarveOutConfig(t, home, "schema-version: 2\nconfig-home-default: ~/.config\nconfig-home:\n  read:\n    - '"+r.entry+"'\n")
		if d := classifyBash(loop, ev); d.Bucket == BucketAllow {
			t.Errorf("%s under %s must not ALLOW; got %q (%s)", loop, r.entry, d.Bucket, d.Reason)
		}
		d := classifyBash(direct, ev)
		if r.directAllow {
			wantBucket(t, d, BucketAllow, direct+" under "+r.entry)
		} else if d.Bucket == BucketAllow {
			t.Errorf("%s under %s must not ALLOW; got %q (%s)", direct, r.entry, d.Bucket, d.Reason)
		}
	}

	writeCarveOutConfig(t, home, "schema-version: 2\nconfig-home-default: ~/.config\nconfig-home:\n  read:\n    - 'cc-tools/**'\n")
	// Spelled by concatenation: filepath.Join would fold the `..` away before
	// the gate ever saw it.
	for _, pattern := range []string{
		dir + "/*",
		dir + "/*.md",
		dir + "/?.md",
		dir + "/[a].md",
		dir + "/**/a.md",
		dir + "/../sub/a.md",
	} {
		for _, cmd := range []string{loopOver(pattern), "cat " + pattern} {
			if d := classifyBash(cmd, ev); d.Bucket == BucketAllow {
				t.Errorf("%s under cc-tools/** carries an expansion the listing does not grade and must not ALLOW; got %q (%s)",
					cmd, d.Bucket, d.Reason)
			}
		}
	}
	brace := "cat " + dir + "/{a,b}.md"
	if d := classifyBash(brace, ev); d.Bucket == BucketAllow {
		t.Errorf("%s under cc-tools/** carries an expansion the listing does not grade and must not ALLOW; got %q (%s)",
			brace, d.Bucket, d.Reason)
	}
	wantBucket(t, classifyBash(loopOver(dir+"/{a,b}.md"), ev), BucketAllow, "a for list splits the brace group into listed literals")
}

// The glob-bearing-segment rule is a rule about Bash operands only. A file-tool
// path is a literal filename whatever characters it carries, so a `Read` of
// `sdlc/pr[1]/notes.md` is covered by `sdlc/pr*/notes.md` exactly as
// `sdlc/pr1/notes.md` would be; the same spelling as a Bash operand is a
// pattern the shell expands, which that entry does not cover. The plain
// spelling runs on both tracks as the negative control that the listing is in
// force and the Bash verdict is the rule's.
func TestOperatorCarveOutGlobRuleIsBashOnly(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")
	cwd := canonicalize(repo)
	ev := bashEvIn(t, cwd, "issue-developer")
	writeCarveOutConfig(t, home, "schema-version: 2\nstate-home-default: ~/.local/state\nstate-home:\n  read:\n    - 'sdlc/pr*/notes.md'\n")

	bracketed := filepath.Join(home, ".local", "state", "sdlc", "pr[1]", "notes.md")
	plain := filepath.Join(home, ".local", "state", "sdlc", "pr1", "notes.md")

	for _, p := range []string{bracketed, plain} {
		d := fileToolVerdict(t, "Read", cwd, p)
		wantBucket(t, d, BucketAllow, "Read of "+p+" under sdlc/pr*/notes.md")
	}
	d := classifyBash("cat "+plain, ev)
	wantBucket(t, d, BucketAllow, "cat "+plain+" under sdlc/pr*/notes.md (negative control)")
	d = classifyBash("cat "+bracketed, ev)
	if d.Bucket == BucketAllow {
		t.Errorf("cat %s is a pattern sdlc/pr*/notes.md does not cover and must not ALLOW; got %q (%s)",
			bracketed, d.Bucket, d.Reason)
	}
}

// A word the line spells glued to a redirect rides no listing. The parser
// reads `sub/<1-3>.md` as the operand `sub/` and two redirects, where zsh —
// the shell the Bash tool runs — reads it as one word carrying a numeric-range
// glob and opens `sub/1.md` through `sub/3.md`, so the listing would grade a
// directory the shell never opens. The rule is checked on each consumer of
// the listing — the read walk, the write walk and the redirect veto — called
// directly on the parsed command, because the whole-line terminal of most of
// these spellings already defers on the redirect the parse invented, which
// hides whether the operand rode the listing. The two spellings whose
// whole-line verdict the listing alone decides run at the terminal as well.
// Every glued spelling keeps the verdict it has with no config file, and the
// same spelling with the range replaced by a literal name runs beside it and
// allows — the negative control that the listing is in force and the glued
// verdict is the rule's.
func TestOperatorCarveOutWithholdsRedirectGluedWord(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	home := carveOutFixture(t, base, "repo")
	cwd := canonicalize(repo)
	ev := bashEvIn(t, cwd, "issue-developer")
	configPath := filepath.Join(home, ".config", "guardrails", "config.yml")

	dir := filepath.Join(home, ".config", "cc-tools", "sub")
	listed := filepath.Join(home, ".config", "cc-tools", "whats-new.md")
	parse := func(cmd string) simpleCommand {
		t.Helper()
		cmds, _, err := extractSimpleCommands(mustParse(t, cmd), cwd, defaultVarResolver(), nil)
		if err != nil || len(cmds) != 1 {
			t.Fatalf("%s: want one simple command, got %d (%v)", cmd, len(cmds), err)
		}
		return cmds[0]
	}
	// Each walk returns its verdict and whether the word rode the listing.
	walks := []struct {
		name    string
		glued   string
		literal string
		walk    func(sc simpleCommand) (Decision, bool)
	}{
		{"read operand", "cat " + dir + "/<1-3>.md", "cat " + dir + "/1.md",
			func(sc simpleCommand) (Decision, bool) {
				d, ok := containPathOperands("cat", readTargets(pathOperands(sc.args[1:]), sc), sc, ev)
				return d, !ok && d.Bucket == BucketAllow
			}},
		{"input-redirect source", "cat < " + dir + "/<1-3>.md", "cat < " + dir + "/1.md",
			func(sc simpleCommand) (Decision, bool) {
				d, ok := containPathOperands("cat", readTargets(pathOperands(sc.args[1:]), sc), sc, ev)
				return d, !ok && d.Bucket == BucketAllow
			}},
		{"write operand", "tee " + dir + "/<1-3>.md", "tee " + dir + "/1.md",
			func(sc simpleCommand) (Decision, bool) {
				d, ok, sawOperator := containWriteOperands("tee", sc.args[1:], sc, ev)
				return d, ok && sawOperator
			}},
		{"redirect destination", "echo x <1-3>" + listed, "echo x > " + listed,
			func(sc simpleCommand) (Decision, bool) {
				return Decision{}, !redirectVetoesAllow(sc, ev)
			}},
		// The argument glued to the operator is the shell's problem, not the
		// spaced target's: `x` is withheld and `listed` rides.
		{"redirect destination after a glued argument", "echo x<1-3>" + listed, "echo x> " + listed,
			func(sc simpleCommand) (Decision, bool) {
				return Decision{}, !redirectVetoesAllow(sc, ev)
			}},
	}
	lines := []struct {
		glued, literal string
	}{
		{"cat <1-3>" + listed, "cat README.md > " + listed},
		{"tee /dev/null <1-3>" + listed, "tee /dev/null < README.md > " + listed},
	}

	// Today's verdicts, taken before any config exists: nothing rides a
	// listing there is not.
	today := map[string]Decision{}
	for _, w := range walks {
		d, rode := w.walk(parse(w.glued))
		if rode {
			t.Errorf("%s (%s) with no carve-out configured must not ride the listing; got %q (%s)",
				w.glued, w.name, d.Bucket, d.Reason)
		}
		today[w.glued] = d
	}
	for _, l := range lines {
		d := classifyBash(l.glued, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("%s with no carve-out configured must not ALLOW; got %q (%s)", l.glued, d.Bucket, d.Reason)
		}
		today[l.glued] = d
	}

	writeCarveOutConfig(t, home, carveOutConfig)
	for _, w := range walks {
		d, rode := w.walk(parse(w.literal))
		if !rode {
			t.Errorf("%s (%s, negative control) must ride the listing; got %q (%s)", w.literal, w.name, d.Bucket, d.Reason)
		}
		d, rode = w.walk(parse(w.glued))
		if rode {
			t.Errorf("%s (%s) is glued to a redirect and must not ride the listing; got %q (%s)",
				w.glued, w.name, d.Bucket, d.Reason)
		}
		if want := today[w.glued]; d.Bucket != want.Bucket || d.Operation != want.Operation {
			t.Errorf("%s (%s) must keep today's verdict %q/%q; got %q/%q (%s)",
				w.glued, w.name, want.Bucket, want.Operation, d.Bucket, d.Operation, d.Reason)
		}
	}
	for _, l := range lines {
		d := classifyBash(l.literal, ev)
		wantBucket(t, d, BucketAllow, l.literal+" (negative control)")
		if !containsSubstr(d.Reason, configPath) {
			t.Errorf("%s rode the listing, so its reason must name it; got %q", l.literal, d.Reason)
		}
		d = classifyBash(l.glued, ev)
		if d.Bucket == BucketAllow {
			t.Errorf("%s is glued to a redirect and must not ALLOW; got %q (%s)", l.glued, d.Bucket, d.Reason)
		}
		if want := today[l.glued]; d.Bucket != want.Bucket || d.Operation != want.Operation {
			t.Errorf("%s must keep today's verdict %q/%q; got %q/%q (%s)",
				l.glued, want.Bucket, want.Operation, d.Bucket, d.Operation, d.Reason)
		}
	}
}
