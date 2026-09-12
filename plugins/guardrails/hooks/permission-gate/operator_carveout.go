package main

import (
	"os"
	"path"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// The operator-configured carve-out, rooted at the XDG config home, the XDG
// state home, and the home directory.
//
// Every per-user config a plugin in this marketplace writes lives under
// `${XDG_CONFIG_HOME:-$HOME/.config}/<plugin>/` and every per-user state file
// under `${XDG_STATE_HOME:-$HOME/.local/state}/<plugin>/`, and containment
// resolves symlinks on both sides before it decides. On a machine whose
// ~/.config is a symlink into a dotfiles repo, that resolution lands every such
// config inside ANOTHER git repo, so the cross-repo deny fired on the whole
// convention this marketplace documents — `/cc-tools:cc-whats-new` could not
// read its own watermark, and `/issues:global-user-config` could not write its
// own file. A `permissions.allow` entry cannot repair that: a PreToolUse deny
// outranks settings.json, so the fix has to be here.
//
// The carve-out is driven entirely by a file the OPERATOR writes
// (~/.config/guardrails/config.yml). The gate ships no default entries and
// carries no knowledge of which plugins exist: absent, unreadable or malformed
// means no usable entry anywhere, which means today's behaviour. It fails
// closed.
//
// The two XDG roots are opt-in: `resolve-xdg-environment-variables: yes` makes
// them follow $XDG_CONFIG_HOME / $XDG_STATE_HOME, and without it they follow
// only the `config-home-default` / `state-home-default` spellings the file
// gives. Reading an environment variable lets whatever set that variable
// relocate a root, so the opt-in is bounded by the denies below rather
// than by refusing to read the variable at all: nothing under a `.git/`
// segment is ever handed out, and no write to this config file itself is ever
// allowed. In practice the hook inherits the launcher's environment, so the
// only same-session route to a relocated root is a nested `claude` launch from
// the Bash tool with an XDG assignment in front of it.
//
// The listing is consulted in exactly one place, testContainmentFrom
// (engine_b_containment.go), which reports a match as the operatorListed
// region; every containment caller — the file tools and each bash track —
// grades that region through scratchAllowEligible, so which tool an agent
// holds is decided by its own `tools:` frontmatter and not by this gate.

// operatorCarveOutSchemaVersion is the minimum `schema-version` this reader
// understands, pinned here as a literal rather than derived. A higher stamp is
// read for the keys documented here and nothing else; a lower or absent one
// yields no entries rather than an abort, because a security hook has no
// channel to abort into. A file still spelling the schema-1 `allow-read` /
// `allow-write` keys is stamped 1 and so lands on that path — one hand edit per
// machine migrates it.
const operatorCarveOutSchemaVersion = 2

// operatorCarveOutConfigDirName is the LITERAL directory name this plugin's own
// config file is found under. The config file's location cannot come from the
// config: it stays at `$HOME/.config/guardrails/config.yml` whatever
// `config-home` resolves to, because the gate has to know where to read before
// it knows what the file says.
const operatorCarveOutConfigDirName = ".config"

// operatorCarveOutPluginDir and operatorCarveOutFileName spell this plugin's
// own config under that directory: a directory named for the plugin, holding a
// YAML file.
const (
	operatorCarveOutPluginDir = "guardrails"
	operatorCarveOutFileName  = "config.yml"
)

// The XDG environment variables the two non-home roots follow when the
// operator opts in. Named here rather than at the use site so the pair the
// README documents and the pair the code reads are one list.
const (
	xdgConfigHomeEnv = "XDG_CONFIG_HOME"
	xdgStateHomeEnv  = "XDG_STATE_HOME"
)

// operatorCarveOutConfigPath is the operator-written config file's path, for
// the allow reason and for the self-write deny. Returns "" when the process
// home is unusable.
func operatorCarveOutConfigPath() string {
	home, ok := processHome()
	if !ok {
		return ""
	}
	return filepath.Join(home, operatorCarveOutConfigDirName, operatorCarveOutPluginDir, operatorCarveOutFileName)
}

// carveOutRoot is one resolved root and the two glob lists relative to it. A
// root the file gave no usable spelling for is never built, so every root that
// reaches the matcher has an absolute path.
type carveOutRoot struct {
	path  string
	read  []string
	write []string
}

// operatorCarveOut is the resolved carve-out: the roots the globs are relative
// to, and the config file's own paths, which no write may target. A zero value
// allows nothing, which is what every failure path returns.
type operatorCarveOut struct {
	roots []carveOutRoot
	// selfWritePaths are the spellings of this config file — its literal load
	// path, and the one under the resolved config-home when that differs. A
	// write to either is refused whatever the globs say, compared by filesystem
	// identity so a symlinked copy and a case-varied spelling are covered too.
	selfWritePaths []string
}

// operatorCarveOutLists is one root's pair of lists in the on-disk shape.
type operatorCarveOutLists struct {
	Read  []string `yaml:"read"`
	Write []string `yaml:"write"`
}

// operatorCarveOutDocument is the on-disk shape. Unknown keys are tolerated:
// the unmarshal ignores every key this struct does not declare, so a config
// carrying keys a later schema adds still parses here — and a config still
// spelling the schema-1 `allow-read` / `allow-write` keys parses as no entries
// at all.
type operatorCarveOutDocument struct {
	SchemaVersion     int                   `yaml:"schema-version"`
	ResolveXDGEnvVars bool                  `yaml:"resolve-xdg-environment-variables"`
	ConfigHomeDefault string                `yaml:"config-home-default"`
	StateHomeDefault  string                `yaml:"state-home-default"`
	ConfigHome        operatorCarveOutLists `yaml:"config-home"`
	StateHome         operatorCarveOutLists `yaml:"state-home"`
	Home              operatorCarveOutLists `yaml:"home"`
}

// loadOperatorCarveOut reads the operator's config for this event. The gate
// process is fresh per hook invocation, so there is nothing to cache and no
// staleness to manage; and this read is an os.ReadFile rather than a tool call,
// so the carve-out does not gate its own config.
func loadOperatorCarveOut() operatorCarveOut {
	return loadOperatorCarveOutFrom(operatorCarveOutConfigPath())
}

// loadOperatorCarveOutFrom is loadOperatorCarveOut's body with the config
// path passed in, so tests can exercise the absent, malformed, wrong-stamp and
// populated cases against a fixture tree rather than the developer's own
// ~/.config.
//
// Every failure — the file is absent, unreadable, not YAML, not a mapping, or
// stamped below the pin — returns no entries, i.e. today's behaviour.
func loadOperatorCarveOutFrom(configPath string) operatorCarveOut {
	if configPath == "" {
		return operatorCarveOut{}
	}
	raw, err := os.ReadFile(configPath)
	if err != nil {
		return operatorCarveOut{}
	}
	var doc operatorCarveOutDocument
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return operatorCarveOut{}
	}
	if doc.SchemaVersion < operatorCarveOutSchemaVersion {
		return operatorCarveOut{}
	}
	home, ok := processHome()
	if !ok {
		return operatorCarveOut{}
	}
	home = filepath.Clean(home)

	configHome := carveOutRootPath(xdgConfigHomeEnv, doc.ResolveXDGEnvVars, doc.ConfigHomeDefault, home)
	stateHome := carveOutRootPath(xdgStateHomeEnv, doc.ResolveXDGEnvVars, doc.StateHomeDefault, home)

	c := operatorCarveOut{selfWritePaths: []string{configPath}}
	if configHome != "" {
		c.selfWritePaths = append(c.selfWritePaths,
			filepath.Join(configHome, operatorCarveOutPluginDir, operatorCarveOutFileName))
	}
	for _, r := range []carveOutRoot{
		{path: configHome, read: doc.ConfigHome.Read, write: doc.ConfigHome.Write},
		{path: stateHome, read: doc.StateHome.Read, write: doc.StateHome.Write},
		{path: home, read: doc.Home.Read, write: doc.Home.Write},
	} {
		// A root with no usable spelling, or with nothing listed under it, can
		// never match. Dropping it here is what makes empty() a question about
		// the whole carve-out rather than about each root in turn.
		if r.path == "" || (len(r.read) == 0 && len(r.write) == 0) {
			continue
		}
		c.roots = append(c.roots, r)
	}
	return c
}

// carveOutRootPath resolves one of the two XDG roots. The environment variable
// is consulted only when the operator opted in AND it is set and non-empty —
// the same test the plugins apply to those variables, so the gate and the
// plugins agree in the empty case too. Otherwise the file's own
// `<root>-default` spelling decides, and when the file gives none the root is
// unusable and its entries are dead: there are no hidden built-in defaults, so
// no root exists that the operator did not spell out somewhere.
func carveOutRootPath(envName string, resolveEnvVars bool, defaultSpelling string, home string) string {
	if resolveEnvVars {
		if v := os.Getenv(envName); v != "" {
			return absoluteRootPath(v, home)
		}
	}
	return absoluteRootPath(defaultSpelling, home)
}

// absoluteRootPath expands a leading `~` against home and Cleans the result,
// returning "" for anything that is not then absolute. A relative root would
// make every remainder depend on the gate process's cwd, which is the calling
// session's and not the operator's to predict.
func absoluteRootPath(spelling string, home string) string {
	if spelling == "" {
		return ""
	}
	spelling, ok := expandLeadingTilde(spelling, home)
	if !ok || !filepath.IsAbs(spelling) {
		return ""
	}
	return filepath.Clean(spelling)
}

// empty reports whether the carve-out can allow nothing at all — no root with
// anything listed under it. Callers use it to skip the match entirely, which is
// the common case on a machine with no config file.
func (c operatorCarveOut) empty() bool {
	return len(c.roots) == 0
}

// allows reports whether target is covered by the carve-out for a call of this
// class. base is the directory a relative target resolves against.
//
// `write` implies `read`, per root: a path that is writable but not readable is
// a half-configured state rather than an intent — /issues:global-user-config
// merge-updates its file and so must read before it writes. A read-only entry
// stays expressible by listing it under `read` alone, which is why the read
// list is consulted only for a read-class call.
//
// A target under more than one root — every path under a config-home that sits
// inside the home directory is — is allowed when ANY of those roots lists it.
func (c operatorCarveOut) allows(target string, base string, readClass bool) bool {
	if c.empty() {
		return false
	}
	if !readClass && c.isSelfWrite(target, base) {
		return false
	}
	for _, r := range c.roots {
		rem, ok := r.remainder(target, base)
		if !ok {
			continue
		}
		if matchAnyCarveOutGlob(r.write, rem) {
			return true
		}
		if readClass && matchAnyCarveOutGlob(r.read, rem) {
			return true
		}
	}
	return false
}

// isSelfWrite reports whether target is this carve-out's own config file. It is
// the one comparison in this file that canonicalizes both sides: the globs are
// matched lexically because a listed path is allowed wherever it lands, but a
// deny protecting one specific file has the opposite requirement — a symlink to
// it, or a symlinked ancestor, must not route around it. A `home: write: ['**']`
// entry would otherwise let the gate's own policy be rewritten by the calls it
// is adjudicating.
//
// The comparison asks the FILESYSTEM whether two spellings name one file
// (sameSelfWriteTarget), which a comparison of canonical strings cannot do: on
// a case-insensitive filesystem — the macOS default — `CONFIG.YML` names the
// same file as `config.yml`, and filepath.EvalSymlinks hands back the caller's
// own casing rather than the name on disk, so the two canonicalize to strings
// that differ. That question is asked whether or not the target exists yet, and
// the not-yet-created case is the one that matters most here: the config-home
// copy of this config is normally absent, so a deny that fell back to bare
// string equality there was bypassable by letter case on exactly the spelling
// a `home: write: ['**']` entry hands out.
//
// TWO spellings of the target are canonicalized and a match on either denies.
//
// The RAW spelling is the load-bearing one, and it is handed to
// canonicalizeFrom uncleaned on purpose: that resolves segment by segment
// (resolvePathSegments, engine_b_containment.go), so a `..` behind a symlinked
// directory — a spelling that names a different file to the kernel than it does
// lexically — climbs out of the directory the link points AT and lands on the
// config file the write really reaches. It does so whether or not that file
// exists yet, which is what the config-home copy usually does not: a machine
// with one config file has it at the literal load path. A trailing separator
// resolves through the same walk, the empty final segment being skipped.
//
// The LEXICALLY-cleaned spelling — the one `remainder` matches the globs
// against — is compared beside it so the deny is never read off a different
// path than the glob match that would otherwise hand the write out. Comparing
// both can only widen the deny, and a widened deny inside the carve-out arm
// hands the call back to the verdict it would have had without the carve-out
// anyway.
//
// Both sides also pass through selfWriteResolveLink, so a spelling whose final
// segment is a symlink at a file that does not exist yet is compared as the
// file the write creates rather than as the link (see there).
func (c operatorCarveOut) isSelfWrite(target string, base string) bool {
	lexical := lexicalAbs(target, base)
	if lexical == "" {
		return false
	}
	for _, real := range []string{
		selfWriteResolveLink(canonicalizeFrom(lexical, "")),
		selfWriteResolveLink(canonicalizeFrom(target, base)),
	} {
		if real == "" {
			continue
		}
		for _, p := range c.selfWritePaths {
			if sameSelfWriteTarget(real, selfWriteResolveLink(canonicalizeFrom(p, ""))) {
				return true
			}
		}
	}
	return false
}

// sameSelfWriteTarget reports whether two canonical spellings name one file,
// asking the filesystem rather than comparing strings wherever it can answer.
//
// Three answers, in order. Identical strings name one file. Two spellings that
// both EXIST are settled by os.SameFile, which covers whatever normalization
// the filesystem applies — case folding, and the Unicode forms a case-folding
// comparison would still miss. When at least one side does NOT exist, os.Stat
// has no inode to offer and the question moves down to the deepest ancestor
// each spelling does have on disk: those two are compared by identity, and the
// segments hanging below them by name, under the case rule probed off the
// ancestor itself (dirFoldsCase).
//
// The residual bound is that third answer's: a segment naming nothing on disk
// is compared as text, so a filesystem that equates two spellings by something
// other than letter case is not covered for the absent segments. os.SameFile
// covers exactly that the moment the file exists.
func sameSelfWriteTarget(a string, b string) bool {
	if a == b {
		return true
	}
	aInfo, aErr := os.Stat(a)
	bInfo, bErr := os.Stat(b)
	if aErr == nil && bErr == nil {
		return os.SameFile(aInfo, bInfo)
	}
	aAnchor, aRest := deepestExistingAncestor(a)
	bAnchor, bRest := deepestExistingAncestor(b)
	if aAnchor == "" || bAnchor == "" || len(aRest) != len(bRest) {
		return false
	}
	aAnchorInfo, err := os.Stat(aAnchor)
	if err != nil {
		return false
	}
	bAnchorInfo, err := os.Stat(bAnchor)
	if err != nil {
		return false
	}
	if !os.SameFile(aAnchorInfo, bAnchorInfo) {
		return false
	}
	folds := dirFoldsCase(aAnchor)
	for i := range aRest {
		if aRest[i] == bRest[i] {
			continue
		}
		if !folds || !strings.EqualFold(aRest[i], bRest[i]) {
			return false
		}
	}
	return true
}

// deepestExistingAncestor splits p at the deepest prefix that exists on disk,
// returning that prefix and the segments below it, outermost first. A path that
// exists comes back whole with an empty remainder; a path no prefix of which
// can be stat'ed comes back with an empty anchor, which its caller reads as no
// match rather than as a match on nothing.
//
// The walk is what lets an ABSENT target be compared at all: the deepest
// existing prefix is the last thing the filesystem can answer an identity
// question about, so it is where sameSelfWriteTarget anchors.
func deepestExistingAncestor(p string) (string, []string) {
	var rest []string
	for {
		if _, err := os.Stat(p); err == nil {
			return p, rest
		}
		parent := filepath.Dir(p)
		if parent == p {
			return "", nil
		}
		rest = append([]string{filepath.Base(p)}, rest...)
		p = parent
	}
}

// dirFoldsCase reports whether the filesystem holding dir treats two spellings
// differing only in letter case as one name. It PROBES rather than deciding
// from runtime.GOOS: a macOS machine can carry a case-sensitive APFS volume and
// a Linux one a case-insensitive mount, and a deny is only as good as the rule
// the filesystem in front of it actually applies.
//
// The probe re-stats a directory under a case-flipped spelling of its own final
// segment and asks os.SameFile whether that reached the same directory. A
// segment with no ASCII letter to flip answers nothing, so the walk climbs to
// one that has them — case sensitivity is a property of the volume, not of the
// entry. When no ancestor can answer, it reports true, which widens the deny
// rather than narrowing it.
func dirFoldsCase(dir string) bool {
	for p := dir; ; {
		parent := filepath.Dir(p)
		if parent == p {
			return true
		}
		seg := filepath.Base(p)
		if flipped := flipASCIICase(seg); flipped != seg {
			self, err := os.Stat(p)
			if err != nil {
				return true
			}
			other, err := os.Stat(filepath.Join(parent, flipped))
			return err == nil && os.SameFile(self, other)
		}
		p = parent
	}
}

// flipASCIICase returns s with the case of every ASCII letter inverted and
// every other byte untouched, or s itself when there was no ASCII letter to
// flip. Only ASCII is flipped: a rune whose case mapping is not one-to-one
// would make the probe's spelling differ by more than case, which is not the
// question dirFoldsCase asks.
func flipASCIICase(s string) string {
	b := []byte(s)
	flipped := false
	for i, ch := range b {
		switch {
		case ch >= 'a' && ch <= 'z':
			b[i], flipped = ch-('a'-'A'), true
		case ch >= 'A' && ch <= 'Z':
			b[i], flipped = ch+('a'-'A'), true
		}
	}
	if !flipped {
		return s
	}
	return string(b)
}

// selfWriteResolveLink follows a canonical path whose final segment is a
// symlink at a destination that does not exist, and returns the destination —
// the file an open(O_CREAT) through that spelling creates. A path that is not
// such a link comes back unchanged, so the call is a no-op on every ordinary
// spelling.
//
// resolvePathSegments (engine_b_containment.go) leaves a dangling link as the
// link's own path, because filepath.EvalSymlinks fails on one. That is the
// right answer for a containment REGION — the link itself is the thing sitting
// inside or outside the worktree — but the wrong one for a deny protecting one
// specific file: the config-home copy of the config file is normally absent (a
// machine with one config file has it at the literal load path), so a link
// aimed straight at it is dangling by construction, and comparing the link's
// path finds neither a string match nor an inode to hand os.SameFile.
//
// The chain is followed to a bounded depth. A cycle names no file at all, so
// exhausting the bound and comparing whatever spelling it reached is harmless.
func selfWriteResolveLink(real string) string {
	for i := 0; i < 40; i++ {
		dest, err := os.Readlink(real)
		if err != nil {
			return real
		}
		if !filepath.IsAbs(dest) {
			// A relative link destination is relative to the directory holding
			// the link. Concatenated rather than Join'ed so a `..` in the
			// destination survives to resolvePathSegments, which applies it to
			// the directory the preceding segment resolves to.
			dest = filepath.Dir(real) + string(filepath.Separator) + dest
		}
		real = resolvePathSegments(dest)
	}
	return real
}

// remainder returns target's path relative to this root, in slash form, or
// ok=false when target does not sit under the root.
//
// The path is made absolute and LEXICALLY cleaned — filepath.Join and
// filepath.Clean remove `..` segments without touching the filesystem — so
// `~/.config/../../Workspaces/other-repo/x` cleans to a path that no longer
// carries the root prefix and cannot match whatever the globs say. It is the
// same property that makes a glob containing `..` dead: a cleaned remainder
// never has a `..` segment for one to match.
//
// It is deliberately NOT symlink-resolved. Every other root in this package is
// canonicalized on both sides so the comparison cannot be symlink-escaped; here
// the symlink IS the case being served, so the check runs on the path as
// written. A listed path is allowed wherever it lands, including inside another
// git repo. The accepted consequence is stated in the README: a symlink under a
// listed path that points into a sibling repo is allowed.
//
// The root itself yields ok=false: the carve-out lists files and subtrees, and
// a bare root is neither.
func (r carveOutRoot) remainder(target string, base string) (string, bool) {
	p := lexicalAbs(target, base)
	if p == "" {
		return "", false
	}
	prefix := r.path + string(filepath.Separator)
	if !strings.HasPrefix(p, prefix) {
		return "", false
	}
	return filepath.ToSlash(strings.TrimPrefix(p, prefix)), true
}

// lexicalAbs expands a leading `~`, makes target absolute against base (or the
// process cwd when base is empty), and Cleans it — with NO symlink resolution,
// which is the whole point of this carve-out. An unusable home directory
// yields "", so a `~`-spelled target simply does not match.
func lexicalAbs(target string, base string) string {
	if target == "" {
		return ""
	}
	// An unusable home yields "", which expandLeadingTilde reads as an unknown
	// home.
	home, _ := processHome()
	target, ok := expandLeadingTilde(target, home)
	if !ok {
		return ""
	}
	if !filepath.IsAbs(target) {
		if base != "" {
			target = filepath.Join(base, target)
		} else {
			abs, err := filepath.Abs(target)
			if err != nil {
				return ""
			}
			target = abs
		}
	}
	return filepath.Clean(target)
}

// matchAnyCarveOutGlob reports whether rem matches any glob in globs.
func matchAnyCarveOutGlob(globs []string, rem string) bool {
	for _, g := range globs {
		if matchCarveOutGlob(g, rem) {
			return true
		}
	}
	return false
}

// matchCarveOutGlob matches a slash-separated remainder against one glob.
//
// The grammar is the one the README's carve-out section documents to the
// operator: `**` matches zero or more whole path segments (`cc-tools/**` covers
// `cc-tools/` and everything beneath it), and every other segment is matched by
// path.Match, whose `*` and `?` stop at a separator. Go's standard library has
// no `**`, and filepath.Match on the whole path would let `*` cross separators,
// so the segment walk below is the smallest thing that gives the documented
// grammar.
func matchCarveOutGlob(glob string, rem string) bool {
	return matchGlobSegments(strings.Split(glob, "/"), strings.Split(rem, "/"))
}

// matchGlobSegments is matchCarveOutGlob's recursion over already-split
// segments.
func matchGlobSegments(pat []string, seg []string) bool {
	for len(pat) > 0 {
		if pat[0] == "**" {
			for i := 0; i <= len(seg); i++ {
				if matchGlobSegments(pat[1:], seg[i:]) {
					return true
				}
			}
			return false
		}
		if len(seg) == 0 {
			return false
		}
		ok, err := path.Match(pat[0], seg[0])
		if err != nil || !ok {
			return false
		}
		pat, seg = pat[1:], seg[1:]
	}
	return len(seg) == 0
}
