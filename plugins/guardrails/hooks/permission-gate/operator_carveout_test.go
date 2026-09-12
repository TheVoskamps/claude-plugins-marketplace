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
// credentialedRedirectVerdict from each program that calls it (`gh` calls it
// from several of its arms, and only the read-only-subcommand arm is run), and
// an input redirect on a construct that runs no program reaches
// classifyRedirectOnly's own direct call into containPathOperands. write says
// whether the spelling writes the path, which is what decides its verdict
// against a `read`-only entry.
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
	{"aws redirect", func(p string) string { return "aws s3 ls > " + p }, true},
	{"redirect-only", func(p string) string { return "[[ -f x ]] < " + p }, false},
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
// read of the `read`-only entry and of the config file are the negative
// controls that the listing is in force and the denies are its bounds.
func TestOperatorCarveOutBashBounds(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "repo")
	gitInit(t, repo)
	home := carveOutFixture(t, base, "repo")
	ev := bashEvIn(t, canonicalize(repo), "issue-developer")

	// `guardrails/**` under config-home `write` is what puts the config file
	// itself inside a listing, which is the only way the self-write deny is
	// reached; `gh/config.yml` stays under `read` alone.
	const config = `schema-version: 2
config-home-default: ~/.config
state-home-default: ~/.local/state
config-home:
  read:
    - gh/config.yml
  write:
    - guardrails/**
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
