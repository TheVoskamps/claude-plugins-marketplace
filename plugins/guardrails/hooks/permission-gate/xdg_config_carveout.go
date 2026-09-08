package main

import (
	"os"
	"path"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// The operator-configured ~/.config carve-out.
//
// Every per-user config a plugin in this marketplace writes lives under
// `${XDG_CONFIG_HOME:-$HOME/.config}/<plugin>/`, and containment resolves
// symlinks on both sides before it decides. On a machine whose ~/.config is a
// symlink into a dotfiles repo, that resolution lands every such config inside
// ANOTHER git repo, so the cross-repo deny fired on the whole convention this
// marketplace documents — `/cc-tools:cc-whats-new` could not read its own
// watermark, and `/issues:global-user-config` could not write its own file. A
// `permissions.allow` entry cannot repair that: a PreToolUse deny outranks
// settings.json, so the fix has to be here.
//
// The carve-out is driven entirely by a file the OPERATOR writes
// (~/.config/guardrails/config.yml). The gate ships no default entries and
// carries no knowledge of which plugins exist: absent, unreadable or malformed
// means two empty lists, which means today's behaviour. It fails closed.
//
// Scope: the file-tool track only (classify_files.go's classifyFileTool). The
// bash engine is deliberately untouched, so `cat ~/.config/cc-tools/x.md` is
// still denied — see the README's carve-out section for why that asymmetry is
// left standing rather than papered over here.

// xdgConfigCarveOutSchemaVersion is the minimum `schema-version` this reader
// understands, pinned here as a literal rather than derived. A higher stamp is
// read for the keys documented here and nothing else; a lower or absent one
// yields empty lists rather than an abort, because a security hook has no
// channel to abort into.
const xdgConfigCarveOutSchemaVersion = 1

// xdgConfigDirName is the LITERAL directory name the carve-out root is built
// from. The root is `$HOME/.config` and nothing else: $XDG_CONFIG_HOME is not
// consulted, for the same reason harnessScratchDir is not os.TempDir() —
// deriving a security carve-out from an environment variable lets whatever set
// that variable relocate the carve-out. A machine that relocates
// $XDG_CONFIG_HOME therefore gets no carve-out at all, which is the fail-closed
// direction.
const xdgConfigDirName = ".config"

// xdgCarveOutPluginDir and xdgCarveOutFileName spell this plugin's own config
// under that root: a directory named for the plugin, holding a YAML file.
const (
	xdgCarveOutPluginDir = "guardrails"
	xdgCarveOutFileName  = "config.yml"
)

// xdgConfigRoot returns the lexically-cleaned $HOME/.config, or "" when the
// home directory cannot be determined.
//
// It is deliberately NOT symlink-resolved. Every other root in this package is
// canonicalized on both sides so the comparison cannot be symlink-escaped; here
// the symlink IS the case being served, so the check runs on the path as
// written. A listed path is allowed wherever it lands, including inside another
// git repo. The accepted consequence is stated in the README: a symlink under a
// listed path that points into a sibling repo is allowed.
func xdgConfigRoot() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Clean(filepath.Join(home, xdgConfigDirName))
}

// xdgCarveOutConfigPath is the operator-written config file's path, for the
// allow reason. Returns "" when the home directory cannot be determined.
func xdgCarveOutConfigPath() string {
	root := xdgConfigRoot()
	if root == "" {
		return ""
	}
	return filepath.Join(root, xdgCarveOutPluginDir, xdgCarveOutFileName)
}

// xdgConfigCarveOut is the resolved carve-out: the root the globs are relative
// to, and the two lists. A zero value (or one with both lists empty) allows
// nothing, which is what every failure path returns.
type xdgConfigCarveOut struct {
	root       string
	allowRead  []string
	allowWrite []string
}

// xdgCarveOutDocument is the on-disk shape. Unknown keys are tolerated: the
// unmarshal ignores every key this struct does not declare, so a config
// carrying keys a later schema adds still parses here.
type xdgCarveOutDocument struct {
	SchemaVersion int      `yaml:"schema-version"`
	AllowRead     []string `yaml:"allow-read"`
	AllowWrite    []string `yaml:"allow-write"`
}

// loadXDGConfigCarveOut reads the operator's config for this event. The gate
// process is fresh per hook invocation, so there is nothing to cache and no
// staleness to manage; and this read is an os.ReadFile rather than a tool call,
// so the carve-out does not gate its own config.
func loadXDGConfigCarveOut() xdgConfigCarveOut {
	root := xdgConfigRoot()
	if root == "" {
		return xdgConfigCarveOut{}
	}
	return loadXDGConfigCarveOutFrom(root, filepath.Join(root, xdgCarveOutPluginDir, xdgCarveOutFileName))
}

// loadXDGConfigCarveOutFrom is loadXDGConfigCarveOut's body with the root and
// the config path passed in, so tests can exercise the absent, malformed,
// wrong-stamp and populated cases against a fixture tree rather than the
// developer's own ~/.config.
//
// Every failure — the file is absent, unreadable, not YAML, not a mapping, or
// stamped below the pin — returns empty lists, i.e. today's behaviour.
func loadXDGConfigCarveOutFrom(root string, configPath string) xdgConfigCarveOut {
	raw, err := os.ReadFile(configPath)
	if err != nil {
		return xdgConfigCarveOut{root: root}
	}
	var doc xdgCarveOutDocument
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return xdgConfigCarveOut{root: root}
	}
	if doc.SchemaVersion < xdgConfigCarveOutSchemaVersion {
		return xdgConfigCarveOut{root: root}
	}
	return xdgConfigCarveOut{
		root:       root,
		allowRead:  doc.AllowRead,
		allowWrite: doc.AllowWrite,
	}
}

// empty reports whether the carve-out can allow nothing at all — no root, or
// no listed glob. Callers use it to skip the match entirely, which is the
// common case on a machine with no config file.
func (c xdgConfigCarveOut) empty() bool {
	return c.root == "" || (len(c.allowRead) == 0 && len(c.allowWrite) == 0)
}

// allows reports whether target is covered by the carve-out for a call of this
// class. base is the directory a relative target resolves against.
//
// allow-write implies allow-read: a path that is writable but not readable is a
// half-configured state rather than an intent — /issues:global-user-config
// merge-updates its file and so must read before it writes. A read-only entry
// stays expressible by listing it under allow-read alone, which is why the
// read list is consulted only for a read-class call.
func (c xdgConfigCarveOut) allows(target string, base string, readClass bool) bool {
	if c.empty() {
		return false
	}
	rem, ok := c.remainder(target, base)
	if !ok {
		return false
	}
	if matchAnyConfigGlob(c.allowWrite, rem) {
		return true
	}
	return readClass && matchAnyConfigGlob(c.allowRead, rem)
}

// remainder returns target's path relative to the carve-out root, in slash
// form, or ok=false when target does not sit under the root.
//
// The path is made absolute and LEXICALLY cleaned — filepath.Join and
// filepath.Clean remove `..` segments without touching the filesystem — so
// `~/.config/../../Workspaces/other-repo/x` cleans to a path that no longer
// carries the root prefix and cannot match whatever the globs say. It is the
// same property that makes a glob containing `..` dead: a cleaned remainder
// never has a `..` segment for one to match.
//
// The root itself yields ok=false: the carve-out lists files and subtrees, and
// ~/.config as a bare target is neither.
func (c xdgConfigCarveOut) remainder(target string, base string) (string, bool) {
	p := lexicalAbs(target, base)
	if p == "" {
		return "", false
	}
	prefix := c.root + string(filepath.Separator)
	if !strings.HasPrefix(p, prefix) {
		return "", false
	}
	return filepath.ToSlash(strings.TrimPrefix(p, prefix)), true
}

// lexicalAbs expands a leading `~`, makes target absolute against base (or the
// process cwd when base is empty), and Cleans it — with NO symlink resolution,
// which is the whole point of this carve-out. An unresolvable home directory
// yields "", so a `~`-spelled target simply does not match.
func lexicalAbs(target string, base string) string {
	if target == "" {
		return ""
	}
	if target == "~" || strings.HasPrefix(target, "~/") {
		home, err := os.UserHomeDir()
		if err != nil || home == "" {
			return ""
		}
		target = filepath.Join(home, strings.TrimPrefix(target, "~"))
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

// matchAnyConfigGlob reports whether rem matches any glob in globs.
func matchAnyConfigGlob(globs []string, rem string) bool {
	for _, g := range globs {
		if matchConfigGlob(g, rem) {
			return true
		}
	}
	return false
}

// matchConfigGlob matches a slash-separated remainder against one glob.
//
// The grammar is the one the README's carve-out section documents to the
// operator: `**` matches zero or more whole path segments (`cc-tools/**` covers
// `cc-tools/` and everything beneath it), and every other segment is matched by
// path.Match, whose `*` and `?` stop at a separator. Go's standard library has
// no `**`, and filepath.Match on the whole path would let `*` cross separators,
// so the segment walk below is the smallest thing that gives the documented
// grammar.
func matchConfigGlob(glob string, rem string) bool {
	return matchGlobSegments(strings.Split(glob, "/"), strings.Split(rem, "/"))
}

// matchGlobSegments is matchConfigGlob's recursion over already-split segments.
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
