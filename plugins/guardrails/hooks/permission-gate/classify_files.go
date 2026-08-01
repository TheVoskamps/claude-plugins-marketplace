package main

import (
	"fmt"
	"path/filepath"
	"strings"
)

// classifyFileTool runs Engine B containment for a Read/Write/Edit/
// MultiEdit/NotebookEdit call. Every path-bearing field in tool_input is
// tested; the worst result wins (escape → deny, contained → defer to the
// normal pipeline).
//
// Writes and reads diverge on a primary-clone-escape target (#130): a
// mutating tool DENIES a target that resolves into the primary clone /
// shared git dir (#127 — a write there corrupts state another worktree
// depends on), while a non-mutating (read) tool is CONTAINED there instead —
// a linked worktree shares tracked content with the primary clone, so a read
// discloses nothing new — except a target under `.git/`, which stays denied
// for reads too (#125). Cross-repo escapes (#148, a genuine sibling repo)
// are still denied for both reads and writes. The hook only DENIES on a
// proven escape; an in-worktree (or now, primary-clone-read) path defers
// (the normal pipeline / settings.json denyRead etc. still apply).
//
// The one path to an outright ALLOW here is the #193 harness scratchpad
// carve-out: when EVERY target of the call lands in a session-shaped
// scratchpad directory, the call is allowed rather than deferred, because a
// defer would still lose to a `/tmp` deny entry in settings.json. A call that
// mixes a scratchpad target with any other kind falls back to the ordinary
// defer, so the allow never rides along with a path the gate has not blessed
// on its own terms.
func classifyFileTool(ev *Event) Decision {
	paths, err := ev.filePaths()
	if err != nil {
		return ask("file:unreadable-input", fmt.Sprintf(
			"Blocked: could not read the file path from this %s event (%v); escalating to a human (fail-closed).",
			ev.ToolName, err))
	}
	if len(paths) == 0 {
		// Nothing to guard (e.g. a tool form with no path) — defer.
		return deferToPipeline()
	}

	rc, err := resolveRepoContext(ev.CWD)
	if err != nil {
		// Fail-closed: we cannot establish the boundary, so we cannot prove
		// the target is in-bounds. ASK rather than allow.
		return ask("file:no-repo-context", fmt.Sprintf(
			"Blocked: could not resolve the repository/worktree boundary for this %s (%v). "+
				"Escalating to a human decision (fail-closed) rather than allowing a possibly out-of-bounds path.",
			ev.ToolName, err))
	}

	// allSession stays true only while EVERY target so far is a session-shaped
	// harness scratchpad path (#193) — the sole ground for an outright ALLOW
	// here. badRoot records a scratchpad-root ASK without short-circuiting the
	// walk, so a genuine escape later in the same call still outranks it.
	allSession := true
	var badRoot Decision
	haveBadRoot := false
	for _, p := range paths {
		// #125 (write half), broadened (#35 Fix 3): a file-mutating tool whose
		// canonicalized target is anywhere under a `.git/` directory is a direct
		// write to the git internals tree. This is denied independently of
		// containment — an in-worktree `.git/` write would otherwise be
		// `contained` and defer. There is no legitimate reason for an agent to
		// hand-edit `.git/`: git's own commands own that tree, and a direct write
		// can rewrite committer identity (`.git/config`), inject commit/push
		// hooks (`.git/hooks/pre-commit`), or corrupt repo state. Reads of `.git/`
		// files are not mutations, so this is gated on a mutating tool.
		if isMutatingFileTool(ev.ToolName) && isUnderGitDir(canonicalize(p), rc) {
			return deny("write:.git tree (#125)", fmt.Sprintf(
				"Blocked: %s target '%s' is inside a .git/ directory. Directly editing anything under .git/ can "+
					"rewrite committer identity (.git/config), inject commit/push hooks (.git/hooks/*), or corrupt "+
					"repo state. Git's own commands own that tree — do not hand-edit .git/. %s If a setting is "+
					"genuinely wrong, surface it to the human rather than rewriting it.",
				ev.ToolName, p, scratchDestinations(rc.topLevel)))
		}

		res, real := testContainment(p, rc)
		if res != harnessScratchSession {
			allSession = false
		}
		switch res {
		case escapeWorktree:
			if !isMutatingFileTool(ev.ToolName) {
				// #130: a Read of the primary clone / shared git dir is a read of
				// content the worktree already shares — not the #127 hazard (that
				// is a WRITE into the shared clone). The .git/ tree deny still
				// applies independently (checked above via isUnderGitDir, though
				// that check is gated to mutating tools — so re-check it here for
				// the read case, since .git/ reads must stay gated too, per the
				// issue's explicit requirement).
				if isUnderGitDir(real, rc) {
					return deny("read:.git tree (#125)", fmt.Sprintf(
						"Blocked: %s target '%s' is inside a .git/ directory. Reads of .git/ internals (config, "+
							"hooks, etc.) stay gated even though primary-clone reads are otherwise allowed. Do not "+
							"work around this by reading or writing under .git/.",
						ev.ToolName, p))
				}
				// Not under .git/: treat as contained and keep checking remaining
				// paths — defer to the normal pipeline, the same as an in-worktree
				// read.
				continue
			}
			correct := correctWorktreePath(real, rc)
			return deny("containment:worktree-escape (#127)", fmt.Sprintf(
				"Blocked: %s target '%s' resolves to the primary clone / shared git dir (%s), not this worktree (%s). "+
					"Writes and edits must land inside this worktree. Use the worktree-anchored path instead: %s. "+
					"Anchor every absolute path to $(git rev-parse --show-toplevel). %s",
				ev.ToolName, p, real, rc.topLevel, correct,
				scratchDestinations(rc.topLevel)))
		case escapeRepo:
			return deny("containment:cross-repo (#148)", fmt.Sprintf(
				"Blocked: %s target '%s' resolves outside the current repository (%s, repo root %s). "+
					"Tool-mediated reads and writes must stay within the current repo — do not reach into a sibling "+
					"repo (e.g. another project's node_modules). If you need third-party API details, consult the "+
					"dependency's published docs instead.%s",
				ev.ToolName, p, real, rc.topLevel, scratchHint(ev.ToolName, rc.topLevel)))
		case harnessScratchBadRoot:
			// Record, do not return: a later target may be a genuine escape,
			// and a deny must outrank this ask.
			badRoot = harnessScratchBadRootAsk("file:scratchpad-root (#193)",
				fmt.Sprintf("%s target '%s'", ev.ToolName, p))
			haveBadRoot = true
		case harnessScratchSession:
			// The harness's own per-session scratchpad directory (#193): a
			// region designated safe by construction. Eligible for the ALLOW
			// terminal below, which outranks a settings.json /tmp deny.
		case claudeConfig, harnessScratch:
			// Carve-outs that DEFER rather than deny, so the normal
			// settings.json pipeline governs them: the agent's own ~/.claude
			// global config tree (#247 — required startup reading, allow-listed
			// in settings.json), and the part of the harness scratchpad prefix
			// outside a session-shaped directory (#193 — in the right tree but
			// not provably a session directory, so the gate has no opinion).
		case contained:
			// ok; keep checking the remaining paths
		}
	}
	if haveBadRoot {
		return badRoot
	}
	if allSession {
		return allow(fmt.Sprintf(
			"%s targets only the harness session scratchpad (%s/<project-slug>/<session-id>/{scratchpad,tasks}), "+
				"a region designated safe by construction", ev.ToolName, harnessScratchDisplay()))
	}
	// All targets are inside this worktree — defer to the normal pipeline
	// (settings.json denyRead, ask lists, etc. still apply).
	return deferToPipeline()
}

// classifyPathReader runs containment on the path arguments of a read-class
// Bash program (less/more/od/xxd/hexdump). Flags and option values are skipped;
// the remaining tokens are treated as path operands and tested with Engine B.
// A contained read DEFERS (the normal pipeline governs it); only an escape
// denies/asks. The read-only-utility classifier (classifyReadOnlyUtility) uses
// the same containment via containPathOperands but ALLOWs the contained form.
//
// #148: a bash-read targeting a sibling repo's node_modules is blocked.
func classifyPathReader(prog string, args []string, sc simpleCommand, ev *Event) Decision {
	if sc.hasUnknownExpansion {
		// A path built from a command substitution / unresolved variable can't
		// be statically contained → escalate to a human (fail-closed).
		return ask("bash-read:dynamic-path", fmt.Sprintf(
			"Blocked: '%s' has a path argument built from an expansion the gate cannot resolve statically; "+
				"escalating to a human decision (fail-closed).", prog))
	}
	if d, hit := cdInvalidAsk(prog, sc); hit {
		return d
	}

	if d, ok := containPathOperands(prog, pathOperands(args), sc, ev); !ok {
		return d
	}
	return deferToPipeline()
}

// cdInvalidAsk reports the fail-closed ASK for a command whose running cwd was
// invalidated by an earlier dynamic `cd` (#129: `cd "$UNKNOWN" && cat ../x`).
// A relative path operand cannot be safely resolved against an unknown cwd, so
// this must be checked before containment runs — mirroring the existing
// hasUnknownExpansion fail-closed check the same callers already perform. An
// invocation with no relative operands at all (only absolute / no path
// operands) would still be safe, but the gate cannot cheaply distinguish that
// case here without duplicating the operand walk, so it fails closed for the
// whole command; this only costs an extra human confirmation, never a wrong
// allow.
func cdInvalidAsk(prog string, sc simpleCommand) (Decision, bool) {
	if !sc.cwdInvalid {
		return Decision{}, false
	}
	return ask("bash-read:cd-unresolved-cwd", fmt.Sprintf(
		"Blocked: '%s' runs after a 'cd' whose target the gate could not resolve statically (a dynamic value, or "+
			"'cd -'), so any relative path argument cannot be safely resolved against the actual current directory; "+
			"escalating to a human decision (fail-closed). Use a static 'cd <literal-path>' or an absolute path.",
		prog)), true
}

// containPathOperands runs Engine B containment on a read-class command's path
// operands. It returns ok=true when every operand is contained inside the
// current worktree, is a non-.git/ read of the primary clone / shared git dir
// (#130 — a linked worktree shares tracked content with the primary clone, so
// this is not a disclosure), or is one of the carve-outs (the ~/.claude tree,
// #247; the harness scratchpad prefix, #193), so the caller may proceed to its
// contained-path terminal (ALLOW for the read-only-utility classifier, DEFER
// for classifyPathReader).
//
// ok=false means the returned Decision is TERMINAL — return it verbatim.
// Usually that is a deny (#148 cross-repo, or #125 a .git/-tree read) or an
// ask (no-repo-context fail-closed, or a defective scratchpad root, #193), but
// it is also how the #193 session-scratchpad ALLOW is delivered: when every
// operand lands in a session-shaped scratchpad directory, the read is allowed
// outright rather than left to the caller's terminal, because the DEFER
// terminal would still lose to a `/tmp` deny entry in settings.json. A deny
// found anywhere in the operand walk returns immediately and so always
// outranks both the ask and the allow.
//
// With no operands there is nothing to contain, so ok=true and the caller's
// own terminal applies. The caller is responsible for the hasUnknownExpansion
// AND cwdInvalid fail-closed checks before calling this (the dynamic-path /
// unresolved-cwd messages differ by caller posture).
//
// sc carries the running cwd this command executes in (#129), tracked through
// any preceding `cd` in the same parsed program; a relative operand resolves
// against sc.cwd rather than ev.CWD, so `cd <subdir> && cmd ../x` resolves
// `../x` relative to <subdir> as bash actually would. sc.cwd falls back to
// ev.CWD when no `cd` preceded this command (extractSimpleCommands seeds the
// running cwd from ev.CWD), so passing the zero simpleCommand{} preserves the
// pre-#129 behavior for any caller that has no sc to thread (there are none
// left, but this keeps the fallback explicit).
func containPathOperands(prog string, operands []string, sc simpleCommand, ev *Event) (Decision, bool) {
	if len(operands) == 0 {
		return Decision{}, true
	}

	rc, err := resolveRepoContext(ev.CWD)
	if err != nil {
		return ask("bash-read:no-repo-context", fmt.Sprintf(
			"Blocked: could not resolve the repository boundary for '%s' (%v); escalating to a human (fail-closed).",
			prog, err)), false
	}

	base := sc.cwd
	if base == "" {
		base = ev.CWD
	}
	// See the ok=false contract above: allSession drives the #193 terminal
	// ALLOW; badRoot is recorded rather than returned inline so a genuine
	// escape later in the walk still outranks it.
	allSession := true
	var badRoot Decision
	haveBadRoot := false
	for _, p := range operands {
		res, real := testContainmentFrom(p, base, rc)
		if res != harnessScratchSession {
			allSession = false
		}
		switch res {
		case escapeRepo:
			return deny("bash-read:cross-repo (#148)", fmt.Sprintf(
				"Blocked: '%s' would read '%s' which resolves outside the current repository (%s, repo root %s). "+
					"Do not read another repo's files (e.g. a sibling project's node_modules) to verify third-party "+
					"APIs — use the dependency's published docs. %s Do not work around this by reading or writing "+
					"under .git/.",
				prog, p, real, rc.topLevel, handoffHint())), false
		case escapeWorktree:
			// #130: a linked worktree SHARES tracked content with the primary
			// clone / common dir, so reading a non-.git/ file there discloses
			// nothing the worktree's own history doesn't already have. Relax to
			// contained for reads — but the .git/ tree deny (#125/#35 Fix 3) MUST
			// survive independently of this relaxation: check it BEFORE relaxing.
			if isUnderGitDir(real, rc) {
				return deny("bash-read:.git tree (#125)", fmt.Sprintf(
					"Blocked: '%s' would read '%s' which is inside a .git/ directory. Reads of .git/ internals "+
						"(config, hooks, etc.) stay gated even though primary-clone reads are otherwise allowed. "+
						"Do not work around this by reading or writing under .git/.",
					prog, real)), false
			}
			// Not under .git/: a legitimate shared-content read (#125's stated
			// intent). Treat as contained rather than escalating.
		case harnessScratchBadRoot:
			badRoot = harnessScratchBadRootAsk("bash-read:scratchpad-root (#193)",
				fmt.Sprintf("'%s' operand '%s'", prog, p))
			haveBadRoot = true
		case harnessScratchSession:
			// The harness's own per-session scratchpad directory (#193): a
			// region designated safe by construction. Eligible for the terminal
			// ALLOW below.
		case claudeConfig, harnessScratch:
			// The agent's own ~/.claude global config tree (#247 — required
			// startup reading, allow-listed in settings.json) and the part of
			// the harness scratchpad prefix outside a session-shaped directory
			// (#193). Treat both as contained, leaving the caller's own
			// terminal to govern.
		case contained:
		}
	}
	if haveBadRoot {
		return badRoot, false
	}
	if allSession {
		return allow(fmt.Sprintf(
			"'%s' reads only the harness session scratchpad (%s/<project-slug>/<session-id>/{scratchpad,tasks}), "+
				"a region designated safe by construction", prog, harnessScratchDisplay())), false
	}
	return Decision{}, true
}

// pathOperands returns the non-flag tokens of a read-class command, treating
// them as path operands. Tokens after a `--` separator are all operands. A
// leading-dash token is treated as a flag and skipped; this is conservative
// (a real path starting with `-` is vanishingly rare and a missed operand only
// loses a containment check, which then defers, not allows).
func pathOperands(args []string) []string {
	var out []string
	sawDashDash := false
	for _, a := range args {
		if sawDashDash {
			out = append(out, a)
			continue
		}
		if a == "--" {
			sawDashDash = true
			continue
		}
		if len(a) > 0 && a[0] == '-' {
			continue
		}
		out = append(out, a)
	}
	return out
}

// scratchHint returns the prescriptive scratch-destination guidance to append
// to a containment-escape deny (#30). A guardrail that only forbids invites a
// workaround; one that prescribes prevents it. The under-specified #148/#127
// escapes used to leave the correct landing spot to the model's discretion,
// and a plausible-but-wrong improvisation is to write under .git/ purely
// because it is gitignored and in-repo, so it slips past containment.
//
// For a mutating tool ("I needed somewhere to put a file") the hint names both
// sanctioned destinations via scratchDestinations and explicitly warns off
// .git/. For a read tool the scratch recommendation is not load-bearing, but
// the handoff LOCATION is (the model may be reaching for a file another session
// wrote), so the read hint names that plus the .git/ prohibition. Returns a
// leading-space-prefixed sentence (or "") so callers can append it inline.
//
// repoRoot is the RESOLVED repository root (rc.topLevel), forwarded to
// scratchDestinations — see there for why the gate names the real path rather
// than a placeholder.
func scratchHint(toolName string, repoRoot string) string {
	if isMutatingFileTool(toolName) {
		return " " + scratchDestinations(repoRoot)
	}
	return " " + handoffHint() + " Do not work around this by reading or writing under .git/."
}

// scratchDestinations returns the prescriptive scratch guidance every
// containment-escape deny carries. A guardrail that only forbids invites a
// workaround; one that prescribes prevents it (#30). It names BOTH sanctioned
// destinations (#193), because prescribing only the in-repo one left an agent
// with a genuine cross-repo / cross-session handoff file no legal landing spot
// at all — and an under-specified denial is exactly what induces an improvised
// bad write (e.g. under .git/, purely because it is gitignored and in-repo):
//
//   - repo-scoped scratch  -> <repo-root>/.claude/tmp/ (already gitignored)
//   - cross-repo/-session  -> the harness scratchpad, <system-tmp>/claude-<uid>/
//
// repoRoot is the RESOLVED repository root — rc.topLevel, the same value the
// adjacent cross-repo deny already prints as `repo root %s`. Every call site
// has it in scope, so the message names a real, directly-usable absolute path.
// It is deliberately neither a literal `<repo-root>` placeholder (which the
// model then has to resolve for itself, and can resolve to the primary clone
// rather than its own worktree) nor a `$(git rev-parse --show-toplevel)`
// incantation the model is told to run for a value the gate is already
// holding. A caller without a resolved root would have to pass a placeholder,
// but there is none — do not add one without revisiting this comment.
func scratchDestinations(repoRoot string) string {
	return fmt.Sprintf(
		"For repo-scoped scratch or temporary files, write under %s/.claude/tmp/ (already gitignored) "+
			"instead of an out-of-repo path. For a file that must outlive this repo or this session (a "+
			"cross-repo or cross-session handoff), use the harness scratchpad under %s/ instead. "+
			"Never write scratch files under .git/.",
		repoRoot, harnessScratchDisplay())
}

// harnessScratchBadRootAsk builds the ASK for a target that resolves through a
// harness scratchpad root (<system-tmp>/claude-<uid>) that is not a plain
// directory owned by this uid (#193). The root is the one component of the
// scratchpad path that needs its own check — see resolveHarnessScratchRoot for
// why nothing below it does.
//
// The reason NAMES the defect (a symlink, a non-directory, another user's
// directory) rather than reading as a containment escape, so an operator who
// hits it diagnoses their own broken /tmp instead of concluding that the #193
// carve-out has regressed.
//
// lead identifies the offending call in the caller's own voice, e.g.
// `Write target '/tmp/claude-501/…'` or `'cat' operand '…'`.
func harnessScratchBadRootAsk(op string, lead string) Decision {
	defect := harnessScratchRootResolver().defect
	if defect == "" {
		// The root recovered between the containment test and this message.
		defect = "not in the state the carve-out requires"
	}
	return ask(op, fmt.Sprintf(
		"Blocked: %s resolves through the harness scratchpad root %s, which is %s rather than a plain directory "+
			"owned by this user. The scratchpad carve-out needs a real directory to prove where a path under it "+
			"actually lands, so this escalates to a human decision (fail-closed). This is the scratchpad-root "+
			"check, NOT a containment escape — inspect %s (`ls -ld`) before re-running.",
		lead, harnessScratchDisplay(), defect, harnessScratchDisplay()))
}

// handoffHint names the sanctioned cross-repo / cross-session handoff location
// for a READ deny (#193). The read side has no scratch-destination problem, but
// it has the mirror-image one: a session reading back a handoff file another
// session wrote needs to be told where that file legitimately lives, or the
// deny reads as "this workflow is impossible" and invites a workaround.
func handoffHint() string {
	return fmt.Sprintf(
		"A cross-repo or cross-session handoff file belongs under the harness scratchpad at %s/, "+
			"which reads and writes are not blocked from.",
		harnessScratchDisplay())
}

// isMutatingFileTool reports whether the tool writes/edits files (as opposed to
// Read, which only reads). The .git/config write rule (#125) applies only to
// mutating tools — reading .git/config is not an identity write.
func isMutatingFileTool(name string) bool {
	switch name {
	case "Write", "Edit", "MultiEdit", "NotebookEdit":
		return true
	default:
		return false
	}
}

// isUnderGitDir reports whether the canonicalized target is anywhere under a
// git directory (#35 Fix 3, generalizing the former isGitConfigPath #125-config
// rule to the whole .git/ tree). Two forms are matched:
//
//   - The current repo's resolved shared git dir (rc.commonDir is <gitdir>);
//     the target equals it or is nested under it. This is the precise,
//     canonicalization-safe match for THIS repo and also covers a linked
//     worktree whose commonDir is the primary clone's shared .git.
//   - Any path with a ".git" segment anywhere in it, covering a submodule's
//     .git/ dir, a nested repo's .git/, or a literal "*/.git/..." path the
//     containment layer would otherwise wave through. (A canonicalized target
//     normally has its own .git symlink resolved away, but submodule and nested
//     layouts can still present a real ".git" directory segment.)
//
// real is expected to already be canonicalized.
func isUnderGitDir(real string, rc *repoContext) bool {
	if real == "" {
		return false
	}
	if rc != nil && rc.commonDir != "" && pathUnder(real, rc.commonDir) {
		return true
	}
	for _, seg := range strings.Split(real, string(filepath.Separator)) {
		if seg == ".git" {
			return true
		}
	}
	return false
}

// correctWorktreePath rewrites a primary-clone path to its in-worktree
// equivalent, for the #127 remediation message. Returns the original real
// path if the rewrite cannot be derived.
func correctWorktreePath(real string, rc *repoContext) string {
	if rc.primaryClone != "" && pathUnder(real, rc.primaryClone) {
		rel := real[len(rc.primaryClone):]
		return rc.topLevel + rel
	}
	return rc.topLevel + "/<the-intended-relative-path>"
}
