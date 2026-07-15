package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// gitRevParseTimeout bounds the git subprocess so a hung git cannot wedge the
// hook (§8: a wedged required hook MUST NOT fail open).
const gitRevParseTimeout = 5 * time.Second

// repoContext is the resolved git context for the event's cwd. All paths are
// already symlink-canonicalized (real-path) so containment comparisons are
// not symlink-escapable (#12).
type repoContext struct {
	insideWorkTree bool
	// topLevel is THIS working tree's root (correct for linked worktrees).
	// It is the containment root for "is the target in this worktree."
	topLevel string
	// commonDir is the SHARED .git directory; used to detect targets that
	// resolve into the primary clone / common dir rather than this worktree
	// (the #127 discrimination).
	commonDir string
	// primaryClone is the primary clone root derived from commonDir
	// (commonDir is <primary-clone>/.git for a normal clone). Empty if it
	// cannot be derived.
	primaryClone string
}

// resolveRepoContext shells out to `git rev-parse` against the event's cwd
// (§8). On ANY subprocess trouble (non-zero exit, empty output, timeout) it
// returns an error; the caller treats that as fail-closed (block/ask, never
// allow).
func resolveRepoContext(eventCWD string) (*repoContext, error) {
	if eventCWD == "" {
		return nil, fmt.Errorf("event has no cwd; cannot resolve git context (fail-closed)")
	}

	// One combined rev-parse call returns all three flags, newline-separated,
	// in order. Running them together keeps it to a single fork.
	out, err := runGit(eventCWD,
		"rev-parse",
		"--is-inside-work-tree",
		"--show-toplevel",
		"--git-common-dir",
	)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) < 3 {
		return nil, fmt.Errorf("git rev-parse returned %d lines, expected 3 (fail-closed): %q", len(lines), out)
	}

	rc := &repoContext{
		insideWorkTree: strings.TrimSpace(lines[0]) == "true",
	}
	if !rc.insideWorkTree {
		return nil, fmt.Errorf("event cwd %q is not inside a git work tree (fail-closed)", eventCWD)
	}

	top := strings.TrimSpace(lines[1])
	common := strings.TrimSpace(lines[2])
	if top == "" {
		return nil, fmt.Errorf("git rev-parse --show-toplevel returned empty (fail-closed)")
	}

	// `--git-common-dir` may be relative to the event cwd; make it absolute.
	if common != "" && !filepath.IsAbs(common) {
		common = filepath.Join(eventCWD, common)
	}

	// Canonicalize the git-derived roots (#12: canonicalize BOTH sides).
	rc.topLevel = canonicalize(top)
	if common != "" {
		rc.commonDir = canonicalize(common)
		// commonDir is typically <primary-clone>/.git; the primary clone is
		// its parent. For a bare/linked layout this still yields the dir that
		// owns the shared object store, which is what #127 guards against.
		rc.primaryClone = canonicalize(filepath.Dir(rc.commonDir))
	}
	return rc, nil
}

// runGit executes `git -C <cwd> <args...>` with a timeout. Empty stdout or a
// non-zero exit is an error (fail-closed). We intentionally do NOT use the
// forbidden `git -C` *command-line* shape that the harness gates — that gate
// is about the model generating Bash; here we are a compiled hook forking git
// directly, which is exactly what the existing shell hooks already do.
func runGit(cwd string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), gitRevParseTimeout)
	defer cancel()

	full := append([]string{"-C", cwd}, args...)
	cmd := exec.CommandContext(ctx, "git", full...)
	// WaitDelay bounds how long Wait/Output blocks after the context is
	// cancelled. Without it, a child that has spawned a grandchild holding the
	// stdout pipe open (e.g. a wrapper script that execs a slow git) can wedge
	// Output() past the deadline. With it, the I/O copy is abandoned shortly
	// after the timeout kill and runGit returns its fail-closed error.
	cmd.WaitDelay = time.Second
	out, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("git %s timed out after %s (fail-closed)", strings.Join(args, " "), gitRevParseTimeout)
	}
	if err != nil {
		return "", fmt.Errorf("git %s failed (fail-closed): %w", strings.Join(args, " "), err)
	}
	if strings.TrimSpace(string(out)) == "" {
		return "", fmt.Errorf("git %s produced empty output (fail-closed)", strings.Join(args, " "))
	}
	return string(out), nil
}

// isAppManagedRepo reports whether the event repo's LOCAL git user.email is
// the App bot address (*[bot]@users.noreply.github.com). Used by the naked-gh
// deny rule. A git failure (no repo, no local config) returns false — the
// gate must not block normal gh usage just because git cannot answer.
func isAppManagedRepo(eventCWD string) bool {
	if eventCWD == "" {
		return false
	}
	out, err := runGit(eventCWD, "config", "--local", "user.email")
	if err != nil {
		return false
	}
	email := strings.TrimSpace(out)
	return strings.HasSuffix(email, "[bot]@users.noreply.github.com")
}

// canonicalize resolves symlinks and `..` to an absolute real path. If the
// path does not exist, it canonicalizes the longest existing ancestor and
// re-appends the non-existent tail, so a not-yet-created file still resolves
// through any symlinked ancestor (a one-sided canonicalization is defeatable
// — #12). Returns a best-effort absolute path; never errors (the containment
// comparison itself is the gate).
//
// A relative p is joined onto the HOOK PROCESS's own cwd via filepath.Abs.
// Most callers have an explicit base directory to resolve against instead
// (the event cwd, or — for a Bash command — the running cwd tracked through
// any preceding `cd`, #129) and should call canonicalizeFrom instead.
func canonicalize(p string) string {
	return canonicalizeFrom(p, "")
}

// canonicalizeFrom is canonicalize with an explicit base directory for the
// relative-join step (#129). A relative p is joined onto base (via
// filepath.Join, so base need not itself be absolute — canonicalizeFrom
// falls back to filepath.Abs's process-cwd behavior when base is empty).
// This changes ONLY the base for the initial relative→absolute step; the
// symlink/`..` resolution semantics below are unchanged.
//
// A leading `~` or `~/...` is expanded against the real home directory
// BEFORE the relative-join step (mirroring the tilde handling applyCd
// already does for `cd ~`, engine_a_bash.go). Without this, `~/.ssh/id_rsa`
// is not absolute (filepath.IsAbs("~...") is false), so it would silently
// fall through to the relative-join branch and resolve as `<base>/~/.ssh/
// id_rsa` — a literal, in-repo-looking child path — masking a genuine
// escape to the user's home directory as `contained`. Expanding first makes
// the path absolute, so it takes the correct branch below and earns
// whatever verdict its real location deserves (contained if home happens to
// be inside the repo, escapeRepo/escapeWorktree/claudeConfig otherwise).
//
// If the home directory cannot be determined, canonicalizeFrom discards the
// unresolved-tilde signal from canonicalizeFromResolver (see there) and
// returns the best-effort (still-literal-`~`) string. This is safe here
// ONLY because canonicalizeFrom's own callers never treat that string as a
// containment verdict by itself: they use it purely for `.git`-tree
// detection (isUnderGitDir), and every one of them re-checks the SAME
// operand through testContainmentFrom immediately afterward, which DOES
// consult the fail-closed signal (see below). A caller that needs the
// fail-closed signal directly — i.e. any caller doing full containment
// classification, not just a `.git`-tree pre-check — must call
// canonicalizeFromResolver itself instead of this convenience wrapper.
func canonicalizeFrom(p string, base string) string {
	real, _ := canonicalizeFromResolver(p, base, os.UserHomeDir)
	return real
}

// canonicalizeFromResolver is canonicalizeFrom with the home-directory
// lookup injected as homeDir, so callers (and tests) can force the
// "home directory unresolvable" branch deterministically without depending
// on the real environment having (or lacking) $HOME.
//
// It returns (real, unresolvedTilde). unresolvedTilde is true exactly when p
// has a leading `~`/`~/...` AND homeDir() failed (non-nil error, or an empty
// home string) — i.e. the tilde could NOT be expanded against a real home
// directory. In that case real is still populated (best-effort, p with `~`
// left as a literal segment) for callers that only want a display string,
// but the caller MUST NOT treat real as eligible for a `contained` verdict:
// an unresolvable `~` must fail closed (deny/ask), mirroring applyCd's own
// posture for `cd ~` when the home directory can't be resolved (engine_a_
// bash.go: applyCd sets runningCWDInvalid = true rather than guessing). A
// literal `~/.ssh/id_rsa` segment left unexpanded would otherwise fall
// through to the ordinary relative-join branch below and resolve as
// `<base>/~/.ssh/id_rsa` — an in-repo-looking child path that silently
// disguises a genuine (would-be) escape to the real home directory as
// `contained`. testContainmentFrom uses unresolvedTilde to force a non-
// contained (escapeRepo) verdict instead of running the normal pathUnder
// checks against this best-effort string.
func canonicalizeFromResolver(p string, base string, homeDir func() (string, error)) (real string, unresolvedTilde bool) {
	if p == "" {
		return p, false
	}
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := homeDir(); err == nil && home != "" {
			p = filepath.Join(home, strings.TrimPrefix(p, "~"))
		} else {
			unresolvedTilde = true
		}
	}
	if !filepath.IsAbs(p) {
		if base != "" {
			p = filepath.Join(base, p)
		} else if abs, err := filepath.Abs(p); err == nil {
			p = abs
		}
	}
	if real, err := filepath.EvalSymlinks(p); err == nil {
		return real, unresolvedTilde
	}
	// Path (or a tail segment) does not exist. Walk up to the longest
	// existing ancestor, canonicalize that, then re-attach the tail.
	dir := p
	var tail []string
	for {
		parent := filepath.Dir(dir)
		if parent == dir {
			break // reached root
		}
		tail = append([]string{filepath.Base(dir)}, tail...)
		dir = parent
		if real, err := filepath.EvalSymlinks(dir); err == nil {
			return filepath.Join(append([]string{real}, tail...)...), unresolvedTilde
		}
	}
	return filepath.Clean(p), unresolvedTilde
}

// containmentResult is the outcome of testing a target path against the repo
// context.
type containmentResult int

const (
	contained      containmentResult = iota // target is under this worktree → ok
	escapeWorktree                          // target is in the primary clone / common dir (#127)
	escapeRepo                              // target is outside the current repo entirely (#148)
	claudeConfig                            // target is under ~/.claude → defer to settings.json allow-list
)

// claudeConfigRoot returns the canonicalized $HOME/.claude directory, or "" if
// the home directory cannot be determined. The path is symlink-resolved the
// same way Engine B canonicalizes every other path so the carve-out below
// cannot be symlink-escaped (a target whose canonical real path lands under
// the real ~/.claude is the one that matters, not its un-canonicalized spelling).
func claudeConfigRoot() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return canonicalize(filepath.Join(home, ".claude"))
}

// testContainment canonicalizes the target and tests it against the resolved
// worktree root. The target is canonicalized BEFORE comparison (#12, both
// sides). Returns one of the containmentResult values.
//
// testContainment resolves a relative target against the process/event cwd
// (via canonicalize). Use testContainmentFrom when the caller has tracked a
// different base cwd for this specific target (#129 — a Bash command whose
// relative operand must resolve against a preceding `cd`, not ev.CWD).
func testContainment(target string, rc *repoContext) (containmentResult, string) {
	return testContainmentFrom(target, "", rc)
}

// testContainmentFrom is testContainment with an explicit base directory for
// the relative-join step (#129). An empty base preserves testContainment's
// existing behavior (process/event cwd).
//
// It calls canonicalizeFromResolver (not the canonicalizeFrom convenience
// wrapper) so it can see the unresolvedTilde signal: a leading `~`/`~/...`
// operand whose home directory could not be resolved (os.UserHomeDir
// failing — HOME unset/empty, a stripped/minimal environment) must fail
// CLOSED rather than fall through to the ordinary pathUnder checks against
// the best-effort (still-literal-`~`) string, which would otherwise resolve
// as an in-repo child path and read as `contained` — masking a real escape
// to the (unresolvable) home directory as safe. This mirrors applyCd's own
// posture for `cd ~` with no resolvable home (engine_a_bash.go: it sets
// runningCWDInvalid = true rather than guessing) — escapeRepo is
// testContainmentFrom's equivalent "invalidate rather than guess" verdict:
// every caller (classifyFileTool, containPathOperands, containWriteOperands)
// treats escapeRepo as deny, never allow.
func testContainmentFrom(target string, base string, rc *repoContext) (containmentResult, string) {
	real, unresolvedTilde := canonicalizeFromResolver(target, base, os.UserHomeDir)
	if unresolvedTilde {
		return escapeRepo, real
	}

	if pathUnder(real, rc.topLevel) {
		return contained, real
	}
	// Carve-out (#247): the agent's own global config tree (~/.claude/CLAUDE.md,
	// ~/.claude/rules/**, etc.) lives outside every repo, yet every subagent and
	// the main session is REQUIRED to read it at startup and settings.json
	// allow-lists exactly those reads. A hard cross-repo deny here would override
	// that allow-list and break the /issue-address workflow this repo depends on.
	// So a target whose canonical path lands under the real ~/.claude is reported
	// as claudeConfig → the caller DEFERS, letting the normal settings.json
	// allow-list govern it. The #148 protection for genuine sibling repos is
	// unaffected (this is checked BEFORE the escapeRepo classification, and only
	// matches the ~/.claude subtree). Both sides are canonicalized so the
	// carve-out cannot be symlink-escaped.
	if cc := claudeConfigRoot(); cc != "" && pathUnder(real, cc) {
		return claudeConfig, real
	}
	// Not under this worktree. Is it in the primary clone / common dir? That
	// is the #127 cross-worktree write into the shared clone.
	if rc.primaryClone != "" && pathUnder(real, rc.primaryClone) {
		return escapeWorktree, real
	}
	if rc.commonDir != "" && pathUnder(real, rc.commonDir) {
		return escapeWorktree, real
	}
	// Outside this worktree and not the primary clone → a different repo /
	// the wider filesystem (#148).
	return escapeRepo, real
}

// pathUnder reports whether child is equal to or nested under parent, using
// path-segment boundaries (so /a/bc is NOT under /a/b). Both inputs are
// expected to be canonicalized absolute paths.
func pathUnder(child, parent string) bool {
	if parent == "" {
		return false
	}
	if child == parent {
		return true
	}
	withSep := parent
	if !strings.HasSuffix(withSep, string(filepath.Separator)) {
		withSep += string(filepath.Separator)
	}
	return strings.HasPrefix(child, withSep)
}
