package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// gitRevParseTimeout bounds the git subprocess so a hung git cannot wedge the
// hook (a wedged required hook MUST NOT fail open).
const gitRevParseTimeout = 5 * time.Second

// repoContext is the resolved git context for the event's cwd. All paths are
// already symlink-canonicalized (real-path) so containment comparisons are
// not symlink-escapable.
type repoContext struct {
	insideWorkTree bool
	// topLevel is THIS working tree's root (correct for linked worktrees).
	// It is the containment root for "is the target in this worktree."
	topLevel string
	// commonDir is the SHARED .git directory; used to detect targets that
	// resolve into the primary clone / common dir rather than this worktree
	// (the worktree-escape discrimination).
	commonDir string
	// primaryClone is the primary clone root derived from commonDir
	// (commonDir is <primary-clone>/.git for a normal clone). Empty if it
	// cannot be derived.
	primaryClone string
}

// resolveRepoContext shells out to `git rev-parse` against the event's cwd. On
// ANY subprocess trouble (non-zero exit, empty output, timeout) it returns an
// error; the caller treats that as fail-closed (block, or a defer carrying the
// resolution failure as its analysis — never allow).
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

	// Canonicalize the git-derived roots (canonicalize BOTH sides).
	rc.topLevel = canonicalize(top)
	if common != "" {
		rc.commonDir = canonicalize(common)
		// commonDir is typically <primary-clone>/.git; the primary clone is
		// its parent. For a bare/linked layout this still yields the dir that
		// owns the shared object store, which is what the worktree guard protects.
		rc.primaryClone = canonicalize(filepath.Dir(rc.commonDir))
	}
	return rc, nil
}

// runGit executes `git -C <cwd> <args...>` with a timeout. Empty stdout or a
// non-zero exit is an error (fail-closed). We intentionally do NOT use the
// forbidden `git -C` *command-line* shape the gate denies — that deny is about
// the model generating Bash; here we are a compiled hook forking git directly,
// which is exactly what the existing shell hooks already do.
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

// sessionOriginRepo returns the `owner/repo` slug of the event repo's `origin`
// remote, lowercased, or "" when it cannot be determined (no repo, no origin,
// git failure, unparseable URL). It is used by the foreign-target write
// scoping: an otherwise-ALLOWed gh write aimed at a repo OTHER than this one is
// an exfil-by-write channel (`gh issue comment -R attacker/repo …`) the egress
// proxy cannot see, so it DEFERS with the target named.
//
// A "" result deliberately makes the scoping fail OPEN (the write keeps its
// ALLOW): the scoping is a refinement on top of an already-ALLOWed own-repo
// write, and a git failure here is the same "git cannot answer" case
// isAppManagedRepo already treats as non-blocking. The write still had to pass
// the enumerated-recoverable-verb allowlist to reach the scoping check, so the
// floor when origin is unknown is the prior behavior, not a silent bypass of
// the deny tier.
func sessionOriginRepo(eventCWD string) string {
	if eventCWD == "" {
		return ""
	}
	out, err := runGit(eventCWD, "remote", "get-url", "origin")
	if err != nil {
		return ""
	}
	return parseOwnerRepoFromRemote(strings.TrimSpace(out))
}

// parseOwnerRepoFromRemote extracts a lowercased `owner/repo` from a git remote
// URL in either SSH (`git@github.com:owner/repo.git`,
// `ssh://git@github.com/owner/repo.git`) or HTTPS
// (`https://github.com/owner/repo.git`) form. A trailing `.git` and any
// trailing slash are stripped. Returns "" when the URL does not yield a
// two-segment `owner/repo` tail.
func parseOwnerRepoFromRemote(url string) string {
	if url == "" {
		return ""
	}
	s := url
	// Strip the scheme / host prefix to leave the path.
	switch {
	case strings.Contains(s, "://"):
		// scheme://[user@]host/owner/repo
		if idx := strings.Index(s, "://"); idx >= 0 {
			s = s[idx+3:]
		}
		if slash := strings.IndexByte(s, '/'); slash >= 0 {
			s = s[slash+1:] // drop host
		} else {
			return ""
		}
	case strings.Contains(s, "@") && strings.Contains(s, ":"):
		// scp-like: [user@]host:owner/repo
		if colon := strings.LastIndexByte(s, ':'); colon >= 0 {
			s = s[colon+1:]
		}
	default:
		// A bare path or unrecognized form; try to use the tail below.
	}
	s = strings.TrimSuffix(strings.TrimSuffix(s, "/"), ".git")
	s = strings.TrimSuffix(s, ".git")
	s = strings.Trim(s, "/")
	parts := strings.Split(s, "/")
	if len(parts) < 2 {
		return ""
	}
	owner := parts[len(parts)-2]
	repo := parts[len(parts)-1]
	if owner == "" || repo == "" {
		return ""
	}
	return strings.ToLower(owner + "/" + repo)
}

// canonicalize resolves symlinks and `..` to an absolute real path. If the
// path does not exist, it canonicalizes the longest existing ancestor and
// re-appends the non-existent tail, so a not-yet-created file still resolves
// through any symlinked ancestor — a one-sided canonicalization is defeatable,
// so both sides of every containment comparison are resolved. Returns a
// best-effort absolute path; never errors (the comparison itself is the gate).
//
// A relative p is joined onto the HOOK PROCESS's own cwd via filepath.Abs.
// Most callers have an explicit base directory to resolve against instead
// (the event cwd, or — for a Bash command — the running cwd tracked through
// any preceding `cd`) and should call canonicalizeFrom instead.
func canonicalize(p string) string {
	return canonicalizeFrom(p, "")
}

// canonicalizeFrom is canonicalize with an explicit base directory for the
// relative-join step. A relative p is joined onto base (via
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
// be inside the repo, escapeRepo/escapeWorktree/claudeConfig/harnessScratch
// otherwise).
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
// an unresolvable `~` must fail closed (deny, or a defer that withholds the
// allow), mirroring applyCd's own
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
	escapeWorktree                          // target is in the primary clone / common dir
	escapeRepo                              // target is outside the current repo entirely
	// claudeConfig: target is under ~/.claude. NOT an escape — the caller falls
	// through to its own terminal for a contained target, which is a DEFER (to
	// the settings.json allow-list) on the file-tool and path-reader tracks and
	// the curated read-utility track's ordinary ALLOW.
	claudeConfig
	// harnessScratch: target is under <system-tmp>/claude-<uid> but the
	// remainder matches neither harness shape. Like claudeConfig it is neither an
	// escape nor grounds for the carve-out's own ALLOW, so the caller's terminal
	// for a contained target governs: DEFER on the file-tool, path-reader and
	// write tracks, and the curated read-utility track's ordinary ALLOW.
	harnessScratch
	// harnessScratchSession: target is under <system-tmp>/claude-<uid> AND the
	// remainder matches the per-session shape → ALLOW on every track,
	// reads and writes alike — bar a target under a `.git/` segment, which the
	// file-tool track denies. This is the one carve-out verdict that outranks
	// settings.json, which is deliberate: the harness directs the model to this
	// exact tree, and a defer would leave the feature dead until every /tmp entry
	// is removed from settings.json.
	harnessScratchSession
	// harnessScratchBundled: target is under <system-tmp>/claude-<uid> AND the
	// remainder matches the bundled-skills shape. Unlike every other
	// containmentResult this one is NOT a verdict on its own — it is
	// read/write-GRADED by the caller, which already knows the call's class:
	// a read is ALLOW (reading a bundled skill is exactly what that tree is
	// for), a write is DEFER (the content is harness-installed and the model
	// has no business rewriting it, but the classifier, not this gate, decides
	// if some case ever needs to). The grading predicate is the one each caller
	// already has — isMutatingFileTool on the file-tool track, operand position
	// (containPathOperands vs. containWriteOperands) on the bash track — so no
	// new classification concept is introduced here.
	harnessScratchBundled
	// harnessScratchBadRoot: the target resolves through a <system-tmp>/
	// claude-<uid> root that is not a plain directory owned by this uid (it is
	// a symlink, a non-directory, or another user's) → DEFER, with an analysis
	// naming the defect so the failure is not mistaken for the containment bug
	// reappearing.
	harnessScratchBadRoot
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

// harnessScratchDir is the system temp directory the Claude Code harness
// provisions its per-session scratchpad tree under. It is deliberately the
// LITERAL "/tmp" and not os.TempDir():
//
//   - os.TempDir() honours $TMPDIR, which on macOS is a per-user
//     /var/folders/<random>/T path the harness does not use — the scratchpad
//     is at /tmp/claude-<uid> on both macOS and Linux.
//   - More importantly, deriving a security carve-out from an environment
//     variable would let whatever set that variable relocate the carve-out to
//     an arbitrary directory. A fixed path cannot be widened that way.
const harnessScratchDir = "/tmp"

// harnessScratchDisplay returns the un-canonicalized, human-facing spelling of
// the harness scratchpad root (e.g. "/tmp/claude-501"), for use in deny
// messages. The uid comes from os.Getuid() at runtime — never hardcoded — so
// the prescription names the caller's OWN scratchpad and is portable across
// macOS and Linux.
func harnessScratchDisplay() string {
	return filepath.Join(harnessScratchDir, "claude-"+strconv.Itoa(os.Getuid()))
}

// harnessSessionShape matches the per-session REMAINDER of a scratchpad path —
// what is left after the canonical <system-tmp>/claude-<uid> root is stripped,
// in slash form. Matching the remainder rather than the full path makes the
// pattern platform-independent by construction: it never contains "/tmp" or
// "/private/tmp", so the macOS and Linux spellings cannot diverge here.
//
// The observed harness layout (17 projects across two machines) is
// <project-slug>/<session-uuid>/, with scratchpad/ and tasks/ as the only
// session subdirectories.
//
// The project slug is the session's absolute cwd with EVERY non-alphanumeric
// character rewritten to "-" (existing dashes preserved), so the slug alphabet
// is [A-Za-z0-9-] and it always LEADS with a "-" (from the leading "/"). Runs
// of consecutive dashes are NORMAL, not exotic: any hidden directory in the cwd
// produces one, because both the separator and the leading dot become dashes —
//
//	/Users/<u>/.claude              -> -Users-<u>--claude
//	/Users/<u>/.config/macos-setup  -> -Users-<u>--config-macos-setup
//
// both of which are real session directories with the standard scratchpad/
// tasks layout. A pattern admitting only single dashes — `(-[A-Za-z0-9]+)+`,
// which an earlier revision of the carve-out spec prescribed and this code faithfully
// implemented — silently excludes every such session and reintroduces the exact
// symptom the carve-out exists to fix (in a settings.json-has-a-/tmp-deny environment,
// the DEFER lands on that deny). Hence the `-+`. The widening stops there: the
// character class stays [A-Za-z0-9] so the slug alphabet is exactly the one the
// harness produces.
//
// <uuid> is the loose 8-4-4-4-12 hex shape; the v4 version nibble is
// deliberately NOT pinned, so a generator change does not break the match. A
// shape miss costs a DEFER, not a denial, which is what makes a pattern this
// tight affordable.
var harnessSessionShape = regexp.MustCompile(
	`^(?:-+[A-Za-z0-9]+)+/` +
		`[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/` +
		`(?:scratchpad|tasks)(?:/|$)`)

// harnessBundledSkillsShape matches the OTHER remainder shape living under the
// same <system-tmp>/claude-<uid> prefix: the harness-managed, non-session
// bundled-skills tree,
//
//	bundled-skills/<version>/<32-lowercase-hex>/<skill-name>/...
//
// The model legitimately READS bundled skills from there, so a matching read is
// ALLOWed; a matching WRITE is DEFERred (see harnessScratchBundled). The
// grading is the caller's, not this pattern's.
//
// The version segment is SHAPE-checked (major.minor.patch) and deliberately NOT
// pinned to the running Claude Code version: the hook event carries no version
// field, so the only source would be CLAUDE_CODE_EXECPATH in the environment —
// deriving a carve-out from an environment variable is the same defect that
// rules out os.TempDir()/$TMPDIR for harnessScratchDir above. Shape-checking
// also survives an upgrade, where the previous version's directory lingers
// alongside the new one.
//
// The evidence base here is narrower than for the session shape: one version
// directory, one hash directory, one machine. A channel-tagged version such as
// `2.1.220-beta.1` would miss the shape — costing a read a DEFER, never a
// denial, which is what keeps the strict shape affordable.
//
// The match ends at `(/|$)` right after the 32-hex segment, so an `ls` of the
// hash directory itself is covered, not only files beneath it. That example is
// load-bearing in both directions: `ls` reaches an ALLOW only because it is in
// readOnlyUtilities (it was not, at first — which is how this comment
// was caught claiming something the gate did not do). Removing `ls` from that
// table falsifies this sentence again.
var harnessBundledSkillsShape = regexp.MustCompile(
	`^bundled-skills/[0-9]+\.[0-9]+\.[0-9]+/[0-9a-f]{32}(?:/|$)`)

// harnessScratchRootState is the resolved state of the <system-tmp>/
// claude-<uid> carve-out root.
type harnessScratchRootState struct {
	// root is the path a canonicalized target is compared against with
	// pathUnder. The PARENT is always symlink-resolved (macOS /tmp ->
	// /private/tmp); the final claude-<uid> component is resolved only when it
	// is itself a symlink — see defect.
	root string
	// defect is "" when the root is a plain directory owned by this uid. A
	// non-empty defect names what is wrong ("a symlink", …) and turns every
	// target under root into harnessScratchBadRoot → DEFER.
	defect string
}

// harnessScratchRootResolver is the function testContainmentFrom consults for
// the carve-out root. It is a package var ONLY so tests can force the
// symlinked / non-directory / foreign-owner branches deterministically,
// without mutating the real /tmp/claude-<uid> tree the developer's own live
// session is using. Production code never reassigns it.
var harnessScratchRootResolver = resolveHarnessScratchRoot

// resolveHarnessScratchRoot resolves <system-tmp>/claude-<uid> — the root of
// the harness's per-session scratchpad tree, under which it lays out
// <project-slug>/<session-id>/{scratchpad,tasks}.
//
// The carve-out covers the whole PER-UID prefix rather than just the current
// session's own subdirectory: cross-session, cross-repo handoff (one session
// writes a file, a session in a sibling repo reads it back) requires reading a
// different <project>/<session> subpath than the one the reader owns. It stays
// scoped to this uid, so another user's /tmp/claude-<other-uid> is NOT carved
// out and still earns the ordinary escapeRepo verdict.
//
// Symlink handling. The threat being addressed is Claude Code writing to a
// WRONG PATH, accidentally or otherwise — not a hostile local user contesting
// the region. The root is the unique component that needs its own check, for a
// structural reason: the root is canonicalized too, so a symlink THERE moves
// the comparison root together with the target and pathUnder still matches;
// every other component moves only the target, so the mismatch surfaces on its
// own and canonicalization produces a better verdict than an Lstat refusal
// would (a symlinked scratchpad -> ~/.ssh resolves out of the region and earns
// the ordinary deny). So: resolve the PARENT with EvalSymlinks and Lstat ONLY
// the final claude-<uid> component. Lstat-ing the whole path — or rejecting a
// symlink anywhere in it — would break macOS outright, where /tmp is itself a
// symlink.
//
// When the root IS a symlink, the comparison root becomes its DESTINATION.
// That is required for the bad-root DEFER to fire at all: the target side is fully
// canonicalized, so it lands on the destination, and comparing against the
// un-followed root would miss it entirely — the path would fall through to the
// ordinary /tmp deny and hide the actual cause. The cost is that unrelated
// paths under that destination also become that DEFER instead of a DENY while
// the root is broken. That is a deliberate trade: the defer never allows, and a
// machine whose scratchpad root is a symlink is misconfigured, so a logged
// analysis naming the defect beats a deny message that reads like this bug
// reappearing.
func resolveHarnessScratchRoot() harnessScratchRootState {
	return resolveScratchRootAt(harnessScratchDisplay())
}

// resolveScratchRootAt is resolveHarnessScratchRoot's body with the root's
// un-canonicalized spelling passed in, so tests can exercise the parent-symlink
// (macOS /tmp), symlinked-root, non-directory and foreign-owner branches against
// a fixture tree instead of the developer's own live /tmp/claude-<uid>.
func resolveScratchRootAt(display string) harnessScratchRootState {
	parent := filepath.Dir(display)
	if realParent, err := filepath.EvalSymlinks(parent); err == nil {
		parent = realParent
	}
	root := filepath.Join(parent, filepath.Base(display))

	fi, err := os.Lstat(root)
	if err != nil {
		// The root does not exist yet (or is unreadable). Nothing can be under
		// it that is not also created by this session, so there is no defect to
		// report; the ordinary pathUnder comparison applies. A not-yet-created
		// root is the normal state on a fresh machine.
		return harnessScratchRootState{root: root}
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		followed := root
		if f, ferr := filepath.EvalSymlinks(root); ferr == nil {
			followed = f
		}
		return harnessScratchRootState{root: followed, defect: "a symlink"}
	}
	if !fi.IsDir() {
		return harnessScratchRootState{root: root, defect: "not a directory"}
	}
	// Ownership is cheap to check and worth checking: the carve-out is per-uid
	// by construction, so a root this uid does not own is not the harness's.
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Getuid() {
		return harnessScratchRootState{
			root:   root,
			defect: fmt.Sprintf("owned by uid %d rather than this process's uid %d", st.Uid, os.Getuid()),
		}
	}
	return harnessScratchRootState{root: root}
}

// harnessScratchRemainder returns real's path relative to root, in slash form,
// or "" when real IS the root. The caller has already established (via
// pathUnder) that root is a path-segment prefix of real.
func harnessScratchRemainder(real, root string) string {
	if real == root {
		return ""
	}
	rem := strings.TrimPrefix(real, root)
	rem = strings.TrimPrefix(rem, string(filepath.Separator))
	return filepath.ToSlash(rem)
}

// testContainment canonicalizes the target and tests it against the resolved
// worktree root. The target is canonicalized BEFORE comparison (both
// sides). Returns one of the containmentResult values.
//
// testContainment resolves a relative target against the process/event cwd
// (via canonicalize). Use testContainmentFrom when the caller has tracked a
// different base cwd for this specific target (a Bash command whose
// relative operand must resolve against a preceding `cd`, not ev.CWD).
func testContainment(target string, rc *repoContext) (containmentResult, string) {
	return testContainmentFrom(target, "", rc)
}

// testContainmentFrom is testContainment with an explicit base directory for
// the relative-join step. An empty base preserves testContainment's
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
	// Carve-out: the agent's own global config tree (~/.claude/CLAUDE.md,
	// ~/.claude/rules/**, etc.) lives outside every repo, so the cross-repo rule
	// reaches it — but what that rule protects is absent there. The tree is no
	// other repo's working state: a read of it cannot come back stale against a
	// worktree, and a write to it cannot land in a checkout another session is
	// holding. A deny is also terminal: it would settle inside the gate a call
	// the layer below it is the one equipped to grade.
	// So a target whose canonical path lands under the real ~/.claude is reported
	// as claudeConfig → the caller DEFERS, letting the normal settings.json
	// allow-list govern it. The protection for genuine sibling repos is
	// unaffected (this is checked BEFORE the escapeRepo classification, and only
	// matches the ~/.claude subtree). Both sides are canonicalized so the
	// carve-out cannot be symlink-escaped.
	if cc := claudeConfigRoot(); cc != "" && pathUnder(real, cc) {
		return claudeConfig, real
	}
	// Carve-out, a cousin of the ~/.claude one above: the harness
	// provisions a per-session scratchpad under <system-tmp>/claude-<uid>/ and
	// actively instructs the model to put temporary files there. Treating that
	// tree as an ordinary /tmp escape made the gate fight the harness — a hook
	// deny beats a settings.json allow, so the scratchpad was unusable from
	// every repo session, and there was no sanctioned home for a cross-repo /
	// cross-session handoff file. Unlike ~/.claude this is not a blanket
	// defer; the verdict is graded on where inside the prefix the target lands.
	// This function's job is only the REGION — the verdict is a function of
	// region × track, and each caller applies its own terminal to the region
	// this returns:
	//
	//	remainder matches the per-session shape → harnessScratchSession
	//	  (ALLOW on every track, read and write alike, bar a `.git/` segment,
	//	  which the file-tool track denies)
	//	remainder matches bundled-skills        → harnessScratchBundled
	//	  (read ALLOW / write DEFER — graded by the caller, see there; the
	//	  same `.git/` deny applies)
	//	remainder does not match                → harnessScratch
	//	  (not an escape and not carve-out grounds for an ALLOW: the caller's
	//	  terminal for a contained target governs, which is a DEFER on the
	//	  file-tool, path-reader and write tracks and the curated read-utility
	//	  track's ordinary ALLOW)
	//	the claude-<uid> root is not a plain,
	//	  this-uid-owned directory              → harnessScratchBadRoot (DEFER)
	//	anything else under /tmp                → escapeRepo            (DENY)
	//
	// ALLOW rather than DEFER for the session shape is deliberate: writing to
	// the scratchpad is precisely what we want to permit, and a defer would
	// leave the feature dead until every /tmp entry is removed from
	// settings.json (a hook allow outranks that list; a defer does not).
	//
	// BOTH the /tmp and /private/tmp spellings are handled by canonicalization
	// of both sides, with no literal enumeration of either: on macOS the root
	// and a target spelled either way resolve through the same /tmp ->
	// /private/tmp symlink. Enumerating the two literals would be actively
	// wrong on Linux, where there is no such symlink and /private/tmp is a
	// genuinely different directory a literal allow-list would wrongly match.
	// Targets that do not exist yet (a Write to a new file) unify too, via
	// canonicalizeFromResolver's longest-existing-ancestor walk-up.
	//
	// Everything else under /tmp — including another uid's prefix — still
	// falls through to the escapeRepo deny below.
	if hs := harnessScratchRootResolver(); hs.root != "" && pathUnder(real, hs.root) {
		if hs.defect != "" {
			return harnessScratchBadRoot, real
		}
		rem := harnessScratchRemainder(real, hs.root)
		if harnessSessionShape.MatchString(rem) {
			return harnessScratchSession, real
		}
		if harnessBundledSkillsShape.MatchString(rem) {
			return harnessScratchBundled, real
		}
		return harnessScratch, real
	}
	// Not under this worktree. Is it in the primary clone / common dir? That
	// is the cross-worktree escape: a write corrupts state another worktree
	// depends on, and a read returns the primary clone's working file.
	if rc.primaryClone != "" && pathUnder(real, rc.primaryClone) {
		return escapeWorktree, real
	}
	if rc.commonDir != "" && pathUnder(real, rc.commonDir) {
		return escapeWorktree, real
	}
	// Outside this worktree and not the primary clone → a different repo /
	// the wider filesystem.
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
