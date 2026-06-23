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
func canonicalize(p string) string {
	if p == "" {
		return p
	}
	if !filepath.IsAbs(p) {
		if abs, err := filepath.Abs(p); err == nil {
			p = abs
		}
	}
	if real, err := filepath.EvalSymlinks(p); err == nil {
		return real
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
			return filepath.Join(append([]string{real}, tail...)...)
		}
	}
	return filepath.Clean(p)
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
func testContainment(target string, rc *repoContext) (containmentResult, string) {
	real := canonicalize(target)

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
