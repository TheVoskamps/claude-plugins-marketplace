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
// Writes and reads diverge on a primary-clone-escape target: a
// mutating tool DENIES a target that resolves into the primary clone /
// shared git dir (a write there corrupts state another worktree
// depends on), while a non-mutating (read) tool is CONTAINED there instead —
// a linked worktree shares tracked content with the primary clone, so a read
// discloses nothing new — except a target under `.git/`, which stays denied
// for reads too. Cross-repo escapes (a genuine sibling repo)
// are still denied for both reads and writes. The hook only DENIES on a
// proven escape; an in-worktree (or now, primary-clone-read) path defers
// (the normal pipeline / settings.json denyRead etc. still apply).
//
// The one path to an outright ALLOW here is the harness scratchpad
// carve-out: when EVERY target of the call lands in an allow-eligible region
// of the harness prefix (a session-shaped scratchpad directory for any tool;
// the bundled-skills tree for a READ — see scratchAllowEligible), the call is
// allowed rather than deferred, because a defer would still lose to a `/tmp`
// deny entry in settings.json. A call that mixes such a target with any other
// kind falls back to the ordinary defer, so the allow never rides along with a
// path the gate has not blessed on its own terms.
func classifyFileTool(ev *Event) Decision {
	paths, err := ev.filePaths()
	if err != nil {
		return deferJudgment("file:unreadable-input", fmt.Sprintf(
			"could not read the file path from this %s event (%v), so there is no target to contain.",
			ev.ToolName, err))
	}
	if len(paths) == 0 {
		// Nothing to guard (e.g. a tool form with no path) — defer.
		return deferToPipeline()
	}

	rc, err := resolveRepoContext(ev.CWD)
	if err != nil {
		// We cannot establish the boundary, so we cannot prove the target is
		// in-bounds — but neither can we say anything a human click would be
		// better informed by. DEFER rather than allow, with the resolution
		// failure as the analysis.
		return deferJudgment("file:no-repo-context", fmt.Sprintf(
			"could not resolve the repository/worktree boundary for this %s (%v), so no target can be proven "+
				"in-bounds.", ev.ToolName, err))
	}

	// allScratch stays true only while EVERY target so far is an allow-eligible
	// harness-prefix path — the sole ground for an outright ALLOW here.
	// Eligibility is read/write-graded for the bundled-skills tree, so the
	// call's class is computed once here from isMutatingFileTool, the same
	// predicate the .git/-tree rule below already uses. badRoot records a
	// scratchpad-root ASK without short-circuiting the walk, so a genuine
	// escape later in the same call still outranks it.
	readClass := !isMutatingFileTool(ev.ToolName)
	allScratch := true
	var badRoot Decision
	haveBadRoot := false
	for _, p := range paths {
		// Write half, broadened to the whole tree: a file-mutating tool whose
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
		if !scratchAllowEligible(res, readClass) {
			allScratch = false
		}
		switch res {
		case escapeWorktree:
			if !isMutatingFileTool(ev.ToolName) {
				// A Read of the primary clone / shared git dir is a read of
				// content the worktree already shares — not the write hazard (that
				// is a WRITE into the shared clone). The .git/ tree deny still
				// applies independently (checked above via isUnderGitDir, though
				// that check is gated to mutating tools — so re-check it here for
				// the read case: a read of .git/ internals stays gated even where
				// primary-clone reads are otherwise relaxed, because config and
				// hooks disclose identity and executable content the shared-content
				// argument does not cover).
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
			badRoot = harnessScratchBadRootDefer("file:scratchpad-root (#193)",
				fmt.Sprintf("%s target '%s'", ev.ToolName, p))
			haveBadRoot = true
		case harnessScratchSession:
			// The harness's own per-session scratchpad directory: a
			// region designated safe by construction. Eligible for the ALLOW
			// terminal below, which outranks a settings.json /tmp deny.
		case harnessScratchBundled:
			// The harness's bundled-skills tree. A READ is eligible for
			// the ALLOW terminal (scratchAllowEligible said so above); a WRITE
			// already cleared allScratch, so it lands on the ordinary DEFER —
			// the content is harness-installed and rewriting it is not this
			// gate's to bless, but neither is it an escape to deny.
		case claudeConfig, harnessScratch:
			// Carve-outs that DEFER rather than deny, so the normal
			// settings.json pipeline governs them: the agent's own ~/.claude
			// global config tree (required startup reading, allow-listed
			// in settings.json), and the part of the harness scratchpad prefix
			// matching neither the session nor the bundled-skills shape
			// (in the right tree but not provably either, so the gate has no
			// opinion).
		case contained:
			// ok; keep checking the remaining paths
		}
	}
	if haveBadRoot {
		return badRoot
	}
	if allScratch {
		return allow(fmt.Sprintf(
			"%s targets only harness-owned regions under %s/ that are designated safe by construction (%s)",
			ev.ToolName, harnessScratchDisplay(), eligibleScratchRegions(readClass)))
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
// A bash-read targeting a sibling repo's node_modules is blocked.
func classifyPathReader(prog string, args []string, sc simpleCommand, ev *Event) Decision {
	if sc.hasUnknownExpansion {
		// A path built from a command substitution / unresolved variable can't
		// be statically contained → hand it to the judge that CAN read the
		// surrounding context, with the reason it was unpinnable.
		return deferJudgment("bash-read:dynamic-path", fmt.Sprintf(
			"'%s' has a path argument built from an expansion the gate cannot resolve statically, so containment "+
				"cannot be run on it.", prog))
	}
	if d, hit := cdInvalidDefer(prog, sc); hit {
		return d
	}

	if d, ok := containPathOperands(prog, readTargets(pathOperands(args), sc), sc, ev); !ok {
		return d
	}
	return deferToPipeline()
}

// cdInvalidDefer reports the DEFER for a command whose running cwd was
// invalidated by an earlier dynamic `cd` (`cd "$UNKNOWN" && cat ../x`).
// A relative path operand cannot be safely resolved against an unknown cwd, so
// this must be checked before containment runs — mirroring the existing
// hasUnknownExpansion check the same callers already perform. An invocation
// with no relative operands at all (only absolute / no path operands) would
// still be safe, but the gate cannot cheaply distinguish that case here
// without duplicating the operand walk, so it withholds its own verdict for
// the whole command. It never rides the allow track.
func cdInvalidDefer(prog string, sc simpleCommand) (Decision, bool) {
	if !sc.cwdInvalid {
		return Decision{}, false
	}
	return deferJudgment("bash-read:cd-unresolved-cwd", fmt.Sprintf(
		"'%s' runs after a 'cd' whose target the gate could not resolve statically (a dynamic value, or "+
			"'cd -'), so any relative path argument cannot be resolved against the actual current directory.",
		prog)), true
}

// containPathOperands runs Engine B containment on a read-class command's path
// operands. It returns ok=true when every operand is contained inside the
// current worktree, is a non-.git/ read of the primary clone / shared git dir
// (a linked worktree shares tracked content with the primary clone, so
// this is not a disclosure), or is one of the carve-outs (the ~/.claude tree,
// or the harness scratchpad prefix), so the caller may proceed to its
// contained-path terminal (ALLOW for the read-only-utility classifier, DEFER
// for classifyPathReader).
//
// ok=false means the returned Decision is TERMINAL — return it verbatim.
// Usually that is a deny (cross-repo, or a .git/-tree read) or an
// ask (no-repo-context fail-closed, or a defective scratchpad root), but
// it is also how the scratchpad ALLOW is delivered: when every operand
// lands in a read-eligible region of the harness prefix (a session-shaped
// scratchpad directory, or the bundled-skills tree), the read is allowed
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
// sc carries the running cwd this command executes in, tracked through
// any preceding `cd` in the same parsed program; a relative operand resolves
// against sc.cwd rather than ev.CWD, so `cd <subdir> && cmd ../x` resolves
// `../x` relative to <subdir> as bash actually would. sc.cwd falls back to
// ev.CWD when no `cd` preceded this command (extractSimpleCommands seeds the
// running cwd from ev.CWD), so passing the zero simpleCommand{} preserves the
// pre-cd-tracking behavior for any caller that has no sc to thread (there are none
// left, but this keeps the fallback explicit).
func containPathOperands(prog string, operands []string, sc simpleCommand, ev *Event) (Decision, bool) {
	if len(operands) == 0 {
		return Decision{}, true
	}

	rc, err := resolveRepoContext(ev.CWD)
	if err != nil {
		return deferJudgment("bash-read:no-repo-context", fmt.Sprintf(
			"could not resolve the repository boundary for '%s' (%v), so no operand can be graded against it.",
			prog, err)), false
	}

	base := sc.cwd
	if base == "" {
		base = ev.CWD
	}
	// See the ok=false contract above: allScratch drives the terminal
	// ALLOW; badRoot is recorded rather than returned inline so a genuine
	// escape later in the walk still outranks it. Every operand reaching this
	// function is a READ operand by construction (containWriteOperands is the
	// write track), which is what makes the bundled-skills tree allow-eligible
	// here and not there — hence the literal readClass=true.
	allScratch := true
	var badRoot Decision
	haveBadRoot := false
	for _, p := range operands {
		if p == procSubstFD {
			// `<(cmd)` — a /dev/fd pipe, not a filesystem path. It cannot escape
			// anything, and the substituted command is classified on its own
			// terms by the walk (descendProcSubsts). Skipping it keeps the
			// all-carve-out ALLOW reachable too: a pipe operand is not a target
			// that could disqualify it.
			continue
		}
		res, real := testContainmentFrom(p, base, rc)
		if !scratchAllowEligible(res, true) {
			allScratch = false
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
			// A linked worktree SHARES tracked content with the primary
			// clone / common dir, so reading a non-.git/ file there discloses
			// nothing the worktree's own history doesn't already have. Relax to
			// contained for reads — but the .git/ tree deny MUST
			// survive independently of this relaxation: check it BEFORE relaxing.
			if isUnderGitDir(real, rc) {
				return deny("bash-read:.git tree (#125)", fmt.Sprintf(
					"Blocked: '%s' would read '%s' which is inside a .git/ directory. Reads of .git/ internals "+
						"(config, hooks, etc.) stay gated even though primary-clone reads are otherwise allowed. "+
						"Do not work around this by reading or writing under .git/.",
					prog, real)), false
			}
			// Not under .git/: a legitimate shared-content read (the git-tree
			// intent). Treat as contained rather than escalating.
		case harnessScratchBadRoot:
			badRoot = harnessScratchBadRootDefer("bash-read:scratchpad-root (#193)",
				fmt.Sprintf("'%s' operand '%s'", prog, p))
			haveBadRoot = true
		case harnessScratchSession, harnessScratchBundled:
			// The harness's own per-session scratchpad directory and its
			// bundled-skills tree: regions designated safe by
			// construction. Both are read-eligible for the terminal ALLOW
			// below — this is the read track, and reading a bundled skill is
			// exactly what that tree is provisioned for.
		case claudeConfig, harnessScratch:
			// The agent's own ~/.claude global config tree (required
			// startup reading, allow-listed in settings.json) and the part of
			// the harness scratchpad prefix matching neither the session nor
			// the bundled-skills shape. Treat both as contained, leaving
			// the caller's own terminal to govern — which differs by track, and
			// is the read-only-utility classifier's ALLOW for the two callers
			// here that hold one. That is this track's pre-existing terminal for
			// any contained operand, not a verdict either carve-out chose.
		case contained:
		}
	}
	if haveBadRoot {
		return badRoot, false
	}
	if allScratch {
		return allow(fmt.Sprintf(
			"'%s' reads only harness-owned regions under %s/ that are designated safe by construction (%s)",
			prog, harnessScratchDisplay(), eligibleScratchRegions(true))), false
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

// readTargets returns every path a read-class command reads: the path operands
// its caller extracted (the plain non-flag walk, or the utility's own operand
// grammar) plus the sources of its input redirects (`cat < f`), which are not
// argv operands and so appear in no arg list.
//
// The two are merged into ONE containment walk on purpose. A redirected read and
// an operand read are the same read spelled two ways, so they must earn the same
// verdict: `cat < ../sibling-repo/.env` denies exactly as
// `cat ../sibling-repo/.env` does, an in-repo source behaves exactly as the
// operand form, and a source in a read-eligible carve-out region rides the same
// terminal ALLOW. Grading them anywhere else would let one spelling drift from
// the other, which is the defect this closes: before, an input redirect was
// graded nowhere at all, so `cat < /etc/passwd` reached the read-only-utility
// classifier with zero operands to contain and was allowed outright.
func readTargets(operands []string, sc simpleCommand) []string {
	out := make([]string, 0, len(operands)+len(sc.inputRedirectTargets))
	out = append(out, operands...)
	return append(out, sc.inputRedirectTargets...)
}

// containReadSources grades the paths a WRITE-class command READS — its
// input-redirect sources (`tee f.md < /etc/passwd`) and the values of its
// path-valued flags (`sed -i -f ../sibling-repo/x.sed f.md`) — through the same
// read containment that grades read operands, and reports ok=false with a
// TERMINAL deny/ask when one of them escapes.
//
// The read tracks do not need this: they merge their input sources straight into
// their operand walk via readTargets. A write command cannot, because
// containPathOperands can also return an outright ALLOW (every operand landed in
// a read-eligible carve-out region), and a read source is no grounds at all to
// bless the command's WRITE. So the allow is discarded here and only the escape
// verdicts are forwarded — a read source on the write track can lose the
// ALLOW but never earn one. Keeping them out of the write operand list matters
// for the same reason in the other direction: a script file sed READS is not a
// file sed writes, and grading it as a write target would say so in the deny.
//
// The caller is responsible for the hasUnknownExpansion / cwdInvalid fail-closed
// checks, exactly as it is for its own operands.
func containReadSources(prog string, sources []string, sc simpleCommand, ev *Event) (Decision, bool) {
	if len(sources) == 0 {
		return Decision{}, true
	}
	d, ok := containPathOperands(prog, sources, sc, ev)
	if ok || d.Bucket == BucketAllow {
		return Decision{}, true
	}
	return d, false
}

// scratchHint returns the prescriptive scratch-destination guidance to append
// to a containment-escape deny. A guardrail that only forbids invites a
// workaround; one that prescribes prevents it. The cross-repo and
// worktree-escape denies used to leave the landing spot to the model's
// discretion,
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
// workaround; one that prescribes prevents it. It names BOTH sanctioned
// destinations, because prescribing only the in-repo one left an agent
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

// harnessScratchBadRootDefer builds the DEFER for a target that resolves
// through a harness scratchpad root (<system-tmp>/claude-<uid>) that is not a
// plain directory owned by this uid. The root is the one component of the
// scratchpad path that needs its own check — see resolveHarnessScratchRoot for
// why nothing below it does.
//
// What this arm establishes is only that the CARVE-OUT cannot be applied: the
// gate cannot prove where a path under a defective root actually lands, so it
// withholds the scratchpad ALLOW. That is not a human-policy question, so the
// analysis NAMES the defect (a symlink, a non-directory, another user's
// directory) rather than reading as a containment escape, and the call goes to
// the judgment middle rather than to a prompt.
//
// lead identifies the offending call in the caller's own voice, e.g.
// `Write target '/tmp/claude-501/…'` or `'cat' operand '…'`.
func harnessScratchBadRootDefer(op string, lead string) Decision {
	defect := harnessScratchRootResolver().defect
	if defect == "" {
		// The root recovered between the containment test and this message.
		defect = "not in the state the carve-out requires"
	}
	return deferJudgment(op, fmt.Sprintf(
		"%s resolves through the harness scratchpad root %s, which is %s rather than a plain directory "+
			"owned by this user, so the scratchpad carve-out cannot prove where the path lands. This is the "+
			"scratchpad-root check, NOT a containment escape — %s is worth inspecting (`ls -ld`).",
		lead, harnessScratchDisplay(), defect, harnessScratchDisplay()))
}

// handoffHint names the sanctioned cross-repo / cross-session handoff location
// for a READ deny. The read side has no scratch-destination problem, but
// it has the mirror-image one: a session reading back a handoff file another
// session wrote needs to be told where that file legitimately lives, or the
// deny reads as "this workflow is impossible" and invites a workaround.
func handoffHint() string {
	return fmt.Sprintf(
		"A cross-repo or cross-session handoff file belongs under the harness scratchpad at %s/, "+
			"which reads and writes are not blocked from.",
		harnessScratchDisplay())
}

// scratchAllowEligible reports whether a harness-prefix containmentResult
// may ride the outright ALLOW terminal, given whether the call is read-class.
// It is the single place the read/write grading of the carve-out lives, and
// every track calls it rather than restating the grading: classifyFileTool and
// containPathOperands drive their allScratch flag from it, containWriteOperands
// drives its deferForCarveOut flag from it, and redirectVetoesAllow grades a
// redirect destination through it as a write operand. Keeping them on one
// predicate is what stops them drifting apart:
//
//   - harnessScratchSession — always eligible. Writing to the session
//     scratchpad is precisely the behavior the carve-out exists to permit.
//   - harnessScratchBundled — eligible for a READ only. The bundled-skills
//     tree is harness-installed content the model legitimately reads; a write
//     there is not an escape to deny, but it is not something this gate has
//     positive grounds to bless either, so it falls through to DEFER and the
//     classifier decides.
//
// Everything else (including the non-shape-matching harnessScratch remainder)
// is ineligible for THIS terminal. What happens then is the caller's own
// terminal for a contained target, which is not one verdict across the board: a
// DEFER on the file-tool, path-reader and write tracks, and the curated
// read-utility track's ordinary ALLOW — the terminal that track already returns
// for an in-repo operand and for the ~/.claude carve-out, decided long
// before this carve-out existed.
//
// readClass is the caller's existing read/write predicate — isMutatingFileTool
// on the file-tool track, operand position on the bash track (a
// containPathOperands operand is read-class by construction, a
// containWriteOperands one is not, and a redirect destination is a write by
// definition). No new classification concept is introduced.
func scratchAllowEligible(res containmentResult, readClass bool) bool {
	switch res {
	case harnessScratchSession:
		return true
	case harnessScratchBundled:
		return readClass
	default:
		return false
	}
}

// redirectVetoesAllow reports whether a command's real-file redirect
// disqualifies it from the allow track.
//
// The veto used to be unconditional: sc.allowEligible() is false whenever
// hasRedirectToFile is set, so `echo x > <scratchpad>/f` could never reach an
// ALLOW no matter where the bytes landed — while `tee <scratchpad>/f` and
// `cp <src> <scratchpad>/f`, the same write to the same region spelled through
// argv, both allow via containWriteOperands. The redirect's stated rationale is
// exfiltration / clobber risk, which is precisely what the session scratchpad
// is designated safe against by construction; two spellings of one write cannot
// have two verdicts, so the veto lifts for that destination and stays intact for
// every other one (an in-repo file, a sibling repo, the bundled-skills tree, the
// unshaped remainder of the prefix, /tmp at large).
//
// The lift is deliberately narrow, and fails closed on every axis:
//
//   - The destination is graded through scratchAllowEligible as a WRITE operand
//     (readClass=false), the same predicate the three operand tracks use, so a
//     redirect can never reach a region a `tee` to the same path could not.
//   - Any unresolved expansion anywhere in the command (including in the
//     redirect word itself, which sets hasUnknownExpansion) keeps the veto: a
//     destination the gate cannot pin statically is not a destination it can
//     bless.
//   - An unresolvable running cwd keeps the veto, since a relative
//     destination cannot then be resolved at all.
//   - EVERY real-file destination must qualify: `cmd > <scratchpad>/f 2> ../x`
//     still vetoes on the second one.
func redirectVetoesAllow(sc simpleCommand, ev *Event) bool {
	if !sc.hasRedirectToFile {
		return false
	}
	if sc.hasUnknownExpansion || sc.cwdInvalid || len(sc.redirectTargets) == 0 {
		return true
	}
	rc, err := resolveRepoContext(ev.CWD)
	if err != nil {
		// The boundary could not be established, so nothing can be proven to
		// land inside the carve-out. Keep the veto.
		return true
	}
	base := sc.cwd
	if base == "" {
		base = ev.CWD
	}
	for _, t := range sc.redirectTargets {
		res, _ := testContainmentFrom(t, base, rc)
		if !scratchAllowEligible(res, false) {
			return true
		}
	}
	return false
}

// credentialedRedirectVerdict grades the real-file redirect of a credentialed
// tool (git / gh / aws) and returns a TERMINAL decision when the destination is
// one the gate cannot bless. hit=false means every destination is fine and the
// caller may proceed to its own verdict.
//
// The two PROVEN-bad destinations DENY (#262), with the same prescriptive
// prose the Write tool's denies carry for the identical destination. Before
// #262 they asked, which made one escape carry two verdicts decided purely by
// spelling: `Write` to /tmp/x.md denied with scratchDestinations guidance,
// while `git show HEAD:f > /tmp/x.md` — same escape, same containment
// predicate, same message — prompted the operator. It was observed in the
// wild: an sdlc:theorem-disprover redirecting `git show` output to /tmp/
// prompted a human when the message it was shown would have redirected it
// perfectly. The deny is also the tier that TEACHES: a redirect has a
// prescriptive alternative (write under <repo>/.claude/tmp/, or the harness
// scratchpad), which is exactly what qualifies it for BucketDeny rather than
// the judgment middle.
//
// The UNPINNABLE arms go the other way and DEFER: "the gate cannot resolve
// this statically" is not a proven escape, it is an absence of proof, and a
// context-reading judge is better placed to grade it than a prompt. They still
// never ride the allow track.
//
// The check it replaces fired on the bare sc.hasRedirectToFile bool, before any
// containment ran, so two spellings of one write carried two verdicts:
// `tee <worktree>/.claude/tmp/x` allowed on the graded in-repo-write track while
// `gh pr diff 224 > <worktree>/.claude/tmp/x` asked. It fired hardest on the two
// destinations the gate itself designates safe — the in-repo `.claude/tmp/` its
// own denies prescribe, and the harness scratchpad.
//
// The stated rationale was wrong too. A redirect into a file in this worktree
// exfiltrates nothing: the bytes land where the agent can already write with
// Write/Edit. The genuine risk is CLOBBER — overwriting a tracked file with
// command output — and ESCAPE, which is exactly what containment decides. So the
// grading is the write-operand grading (readClass=false, the same predicate
// `tee`/`cp` are held to), and the reason names clobber and escape.
//
// It withholds the ALLOW on every axis the graded redirect check already
// withholds it on: an expansion the gate cannot pin, an invalidated running
// cwd, and an unresolvable repo boundary all defer, a `.git/` destination
// denies, and EVERY destination must qualify (`gh … > <scratchpad>/f 2> ../x`
// still returns a terminal for the second one).
func credentialedRedirectVerdict(tool string, sc simpleCommand, ev *Event) (Decision, bool) {
	if !sc.hasRedirectToFile {
		return Decision{}, false
	}
	unpinnable := func(why string) (Decision, bool) {
		return deferJudgment(tool+" redirect-unresolvable", fmt.Sprintf(
			"'%s' redirects output to a file the gate cannot pin statically (%s), so it cannot prove the write "+
				"lands inside this worktree rather than clobbering something outside it.", tool, why)), true
	}
	if sc.hasUnknownExpansion {
		return unpinnable("the destination is built from an expansion or command substitution")
	}
	if sc.cwdInvalid {
		return unpinnable("a preceding 'cd' target could not be resolved, so a relative destination has no base")
	}
	if len(sc.redirectTargets) == 0 {
		return unpinnable("the redirect names no statically-recorded destination")
	}
	rc, err := resolveRepoContext(ev.CWD)
	if err != nil {
		return unpinnable(fmt.Sprintf("the repository boundary could not be resolved: %v", err))
	}
	base := sc.cwd
	if base == "" {
		base = ev.CWD
	}
	for _, t := range sc.redirectTargets {
		if isUnderGitDir(canonicalizeFrom(t, base), rc) {
			return deny(tool+" redirect-into-.git", fmt.Sprintf(
				"Blocked: '%s' redirects output to '%s', inside a .git/ directory. Writing there can rewrite "+
					"committer identity, inject hooks, or corrupt repo state. %s",
				tool, t, scratchDestinations(rc.topLevel))), true
		}
		res, real := testContainmentFrom(t, base, rc)
		if res == contained || scratchAllowEligible(res, false) {
			continue
		}
		return deny(tool+" redirect-escapes-worktree", fmt.Sprintf(
			"Blocked: '%s' redirects output to '%s', which resolves to %s — outside this worktree (%s). A "+
				"redirect clobbers whatever is at the destination, and the gate cannot vouch for a destination "+
				"it does not own. %s",
			tool, t, real, rc.topLevel, scratchDestinations(rc.topLevel))), true
	}
	return Decision{}, false
}

// eligibleScratchRegions names, in the allow reason, exactly the carve-out regions
// that were eligible for THIS call's class — so a Write's reason does not
// advertise the bundled-skills tree it could not have ridden. It is the prose
// mirror of scratchAllowEligible and must be kept in step with it.
func eligibleScratchRegions(readClass bool) string {
	regions := "the session scratchpad, <project-slug>/<session-id>/{scratchpad,tasks}"
	if readClass {
		regions += ", or the bundled-skills tree"
	}
	return regions
}

// isMutatingFileTool reports whether the tool writes/edits files (as opposed to
// Read, which only reads). The .git/config write rule applies only to
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
// git directory. It generalizes the former isGitConfigPath check, which matched
// only .git/config, to the whole .git/ tree. Two forms are matched:
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
// equivalent, for the worktree-escape remediation message. Returns the original real
// path if the rewrite cannot be derived.
func correctWorktreePath(real string, rc *repoContext) string {
	if rc.primaryClone != "" && pathUnder(real, rc.primaryClone) {
		rel := real[len(rc.primaryClone):]
		return rc.topLevel + rel
	}
	return rc.topLevel + "/<the-intended-relative-path>"
}
