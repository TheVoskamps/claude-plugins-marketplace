package main

import (
	"fmt"
	"strings"
)

// In-repo write classifier (#32).
//
// The agent can already mutate any in-repo file via the Write/Edit tools, which
// Engine B lets through when the target is contained in the worktree. The
// EQUIVALENT mutation expressed as a shell one-liner — `sed -i`, `cp src dst`,
// `mv a b`, `tee file`, `mkdir sub/dir`, `touch file` — currently DEFERS and
// then prompts, because settings.json has no allow entry and the gate had no
// opinion. That asymmetry produces prompts for operations no more dangerous than
// the file-tool writes already permitted.
//
// classifyInRepoWrite auto-ALLOWs a curated set of file-mutating programs ONLY
// when every path operand the program writes (or reads, for cp/mv sources) is
// provably contained inside the current repository / worktree via the existing
// Engine B containment. Any operand that escapes the repo (#148) or escapes the
// worktree into the primary clone (#127) DENIES, reusing the worktree-anchored
// remediation. An operand built from an unresolved expansion (`$(...)`) cannot
// be statically contained, so the gate ASKS (matching the read side's
// bash-read:dynamic-path posture, #1).
//
// `rm` is deliberately NOT in this set: it is the highest-blast-radius mutating
// program, and the conservative posture (per #32) keeps `rm`/`rm -rf` on the
// ask/defer track so a human sees each one.

// inRepoWriteSpec describes how to extract the path operands of a mutating
// program. operandsFn returns the tokens that name files the command will touch;
// every returned operand must pass Engine B containment for the ALLOW.
//
// A non-nil mutatesFn lets a dual-mode program (one that also has a read-only
// form handled by the read-only-utility classifier) declare whether THIS
// invocation is actually a mutation that should ride this classifier. When
// mutatesFn is nil the program is an unconditional writer (cp/mv/mkdir/touch)
// and always rides this classifier.
type inRepoWriteSpec struct {
	operandsFn func(args []string) []string
	mutatesFn  func(args []string, sc simpleCommand) bool
}

// inRepoWriters maps a mutating program basename to its operand-extraction spec.
// Each spec parses the program's own flag grammar so a flag value is never
// misread as a path operand and a script argument (sed) is never tested as a
// file. An unrecognized flag makes the operand extractor fail safe by withholding
// the ALLOW (see the per-program functions), so a future mutating flag does not
// slip a write past containment.
var inRepoWriters = map[string]inRepoWriteSpec{
	// cp/mv: all non-flag operands are paths (source(s) + dest). Containment on
	// the DEST is what makes `mv repo-file /tmp/x` deny (#32) — checking only the
	// source would wave an escaping destination through.
	"cp": {operandsFn: cpMvOperands},
	"mv": {operandsFn: cpMvOperands},
	// mkdir/touch: every non-flag operand is a target the command creates.
	"mkdir": {operandsFn: mkdirTouchOperands},
	"touch": {operandsFn: mkdirTouchOperands},
	// sed -i: only the FILE args are paths; the script arg (`s/a/b/`) is not.
	// mutatesFn gates this to the in-place form; the read-only form (no -i) is
	// handled by the read-only-utility classifier.
	"sed": {operandsFn: sedFileOperands, mutatesFn: sedMutates},
	// tee: the operands are WRITE destinations. mutatesFn gates this to the
	// real-file form; `tee /dev/null` stays on the read-only-utility track.
	"tee": {operandsFn: teeTargets, mutatesFn: teeMutates},
}

// classifyInRepoWrite ALLOWs a curated file-mutating program when every path
// operand is provably contained in the current worktree, else denies/asks per
// the escape, or defers when the gate cannot prove the form is a clean in-repo
// write. The caller has already confirmed prog is in inRepoWriters.
func classifyInRepoWrite(prog string, args []string, sc simpleCommand, ev *Event) Decision {
	spec := inRepoWriters[prog]

	// A real-file redirect (`cp a b > log`) means bytes also leave for a file the
	// operand parser does not model. Don't auto-allow — defer to the pipeline.
	if sc.hasRedirectToFile {
		return deferToPipeline()
	}

	// A command substitution / unresolved expansion in ANY argument means a path
	// operand may be dynamically built and cannot be statically contained (#1).
	// Fail closed ASK, the same posture the read side holds for dynamic paths.
	if sc.hasUnknownExpansion {
		return ask("bash-write:dynamic-path", fmt.Sprintf(
			"Blocked: '%s' has an argument built from an expansion the gate cannot resolve statically, so its "+
				"write target cannot be proven in-repo; escalating to a human decision (fail-closed).", prog))
	}

	operands := spec.operandsFn(args)
	if len(operands) == 0 {
		// No statically-extractable write target (e.g. an unrecognized flag the
		// extractor refused to model, or a form we don't recognize). Defer rather
		// than allow — a write we cannot see is a write we must not bless.
		return deferToPipeline()
	}

	if d, ok := containWriteOperands(prog, operands, ev); !ok {
		return d
	}
	return allow(fmt.Sprintf("%s writes only paths contained in the current worktree (in-repo write)", prog))
}

// containWriteOperands runs Engine B containment on a write-class command's path
// operands. It returns ok=true only when EVERY operand is contained inside the
// current worktree (or is the carved-out ~/.claude tree, #247). When an operand
// escapes, ok is false and the returned Decision is the appropriate write-side
// deny: cross-repo (#148) or worktree-escape (#127), each carrying the
// worktree-anchored remediation (mirroring the file-tool deny wording).
//
// Unlike the read side (containPathOperands), a worktree-escape here DENIES
// rather than ASKS: writing into the primary clone from a subagent worktree is
// the #127 escape, exactly the case classifyFileTool denies for Write/Edit. A
// subagent writing inside its own worktree is contained and fine; a subagent
// writing into the primary clone still denies, because rc.topLevel is the
// subagent's worktree root.
func containWriteOperands(prog string, operands []string, ev *Event) (Decision, bool) {
	rc, err := resolveRepoContext(ev.CWD)
	if err != nil {
		return ask("bash-write:no-repo-context", fmt.Sprintf(
			"Blocked: could not resolve the repository boundary for '%s' (%v); escalating to a human (fail-closed).",
			prog, err)), false
	}

	for _, p := range operands {
		// A write whose canonicalized target lands under a .git/ directory is a
		// direct write to git internals (#125, broadened by #35 Fix 3) — denied
		// independently of containment, exactly as classifyFileTool denies it for
		// the Write/Edit tools. An in-worktree `.git/` target would otherwise be
		// `contained` and ride the ALLOW.
		if isUnderGitDir(canonicalize(p), rc) {
			return deny("bash-write:.git tree (#125)", fmt.Sprintf(
				"Blocked: '%s' target '%s' is inside a .git/ directory. Directly writing anything under .git/ can "+
					"rewrite committer identity (.git/config), inject commit/push hooks (.git/hooks/*), or corrupt "+
					"repo state. Git's own commands own that tree — do not hand-write .git/. For scratch files, write "+
					"under $(git rev-parse --show-toplevel)/.claude/tmp/ (already gitignored); never use .git/.",
				prog, p)), false
		}

		res, real := testContainment(p, rc)
		switch res {
		case escapeWorktree:
			correct := correctWorktreePath(real, rc)
			return deny("bash-write:worktree-escape (#127)", fmt.Sprintf(
				"Blocked: '%s' target '%s' resolves to the primary clone / shared git dir (%s), not this worktree (%s). "+
					"Writes must land inside this worktree. Use the worktree-anchored path instead: %s. Anchor every "+
					"absolute path to $(git rev-parse --show-toplevel). For scratch or temporary files, write under "+
					"$(git rev-parse --show-toplevel)/.claude/tmp/ (already gitignored) rather than picking an arbitrary "+
					"spot; never use .git/ for scratch.",
				prog, p, real, rc.topLevel, correct)), false
		case escapeRepo:
			return deny("bash-write:cross-repo (#148)", fmt.Sprintf(
				"Blocked: '%s' target '%s' resolves outside the current repository (%s, repo root %s). Tool-mediated "+
					"writes must stay within the current repo — do not write into a sibling repo or the wider "+
					"filesystem. For scratch or temporary files, write under <repo-root>/.claude/tmp/ (already "+
					"gitignored) instead of an out-of-repo path. Never write scratch files under .git/.",
				prog, p, real, rc.topLevel)), false
		case claudeConfig:
			// The agent's own ~/.claude global config tree (#247). A WRITE here is
			// not a clean in-repo write the gate should bless on its own — let the
			// settings.json allow-list / normal pipeline govern it. Treat as
			// not-contained-for-allow without denying: signal a defer.
			return deferToPipeline(), false
		case contained:
		}
	}
	return Decision{}, true
}

// cpMvOperands returns the path operands of cp / mv: every non-flag token,
// including the destination. The flag grammar of cp/mv has only a handful of
// value-taking options (`-t DEST`/`--target-directory`, `-S SUFFIX`/`--suffix`);
// their values are consumed so they are not double-counted, except `-t`/`--target-directory`
// whose value IS a destination path and is kept. An unrecognized long flag with
// `=VALUE` is skipped (the value is attached, not a separate token). A bare
// single-dash token is treated as a flag and skipped.
//
// cp/mv have no read-only mode, so there is no fail-safe-defer on an unknown
// flag here: an unknown flag is skipped, and the real path operands are still
// tested. The ALLOW only fires when those operands are contained, so a stray
// unknown flag cannot widen the write surface — at worst it loses a flag's value
// token from the operand list, which only relaxes nothing (containment still
// runs on every actual path).
func cpMvOperands(args []string) []string {
	var out []string
	sawDashDash := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if sawDashDash {
			out = append(out, a)
			continue
		}
		if a == "--" {
			sawDashDash = true
			continue
		}
		// `-t DEST` / `--target-directory DEST`: the value is a destination PATH —
		// keep it as an operand so it is contained.
		if a == "-t" || a == "--target-directory" {
			if i+1 < len(args) {
				out = append(out, args[i+1])
				i++
			}
			continue
		}
		if strings.HasPrefix(a, "--target-directory=") {
			out = append(out, strings.TrimPrefix(a, "--target-directory="))
			continue
		}
		// `-S SUFFIX` / `--suffix SUFFIX`: the value is a suffix string, not a path.
		if a == "-S" || a == "--suffix" {
			i++ // skip the value
			continue
		}
		if len(a) > 0 && a[0] == '-' && a != "-" {
			continue // a flag (its value, if any, is attached or skipped above)
		}
		out = append(out, a)
	}
	return out
}

// mkdirTouchOperands returns the target operands of mkdir / touch: every non-flag
// token. touch's `-r REFFILE`/`--reference` and `-d DATE`/`--date`/`-t STAMP`
// take values that are NOT targets (a reference file is read, a date/stamp is a
// string); their values are consumed. mkdir's `-m MODE`/`--mode` value is a mode
// string, also consumed. Everything else non-flag is a directory/file to create.
func mkdirTouchOperands(args []string) []string {
	valueFlags := map[string]bool{
		// mkdir
		"-m": true, "--mode": true,
		// touch
		"-d": true, "--date": true, "-t": true, "-r": true, "--reference": true,
	}
	var out []string
	sawDashDash := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if sawDashDash {
			out = append(out, a)
			continue
		}
		if a == "--" {
			sawDashDash = true
			continue
		}
		if valueFlags[a] {
			i++ // skip the value (mode / date / reference file)
			continue
		}
		if strings.HasPrefix(a, "--") && strings.Contains(a, "=") {
			continue // long flag with attached value (e.g. --mode=0755)
		}
		if len(a) > 0 && a[0] == '-' && a != "-" {
			continue // a flag
		}
		out = append(out, a)
	}
	return out
}

// sedMutates reports whether a sed invocation is the in-place (mutating) form
// the in-repo-write classifier should handle. It reuses sedDefers, which the
// read-only-utility classifier uses to DEFER the mutating form: sedDefers
// returns true for `-i`/`--in-place` (any suffix form) AND for any unrecognized
// flag. We only want to claim the genuine in-place form here, so we test for the
// `-i` token directly; a non-`-i` form that merely trips sedDefers (an unknown
// flag) is left to defer rather than mis-classified as an in-repo write.
func sedMutates(args []string, _ simpleCommand) bool {
	for _, a := range args {
		if a == "--" {
			return false
		}
		if a == "-i" || a == "--in-place" ||
			strings.HasPrefix(a, "-i") || strings.HasPrefix(a, "--in-place=") {
			return true
		}
	}
	return false
}

// sedFileOperands returns the FILE operands of a sed invocation, excluding the
// script. sed's grammar is `sed [FLAGS] {script | -e script | -f file} [FILE...]`.
// When the script is supplied inline (no -e/-f), it is the FIRST non-flag operand
// and is NOT a path; the remaining non-flag operands are files. When -e/-f
// supplies the script, EVERY non-flag operand is a file. Flag values for
// -e/-f/-l are consumed. An unrecognized flag returns no operands (fail safe →
// the caller defers), so a future mutating flag does not slip a write through.
func sedFileOperands(args []string) []string {
	valueFlags := map[string]bool{
		"-e": true, "--expression": true, "-f": true, "--file": true,
		"-l": true, "--line-length": true,
	}
	boolFlags := map[string]bool{
		"-n": true, "--quiet": true, "--silent": true,
		"-E": true, "-r": true, "--regexp-extended": true,
		"-z": true, "--null-data": true,
		"-s": true, "--separate": true,
		"-u": true, "--unbuffered": true,
		"--posix": true, "--debug": true, "--sandbox": true,
		"--follow-symlinks": true,
	}
	scriptSuppliedByFlag := false
	var operands []string
	sawDashDash := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if sawDashDash {
			operands = append(operands, a)
			continue
		}
		if a == "--" {
			sawDashDash = true
			continue
		}
		// The in-place flag (any spelling/suffix) is what put us here; skip it.
		if a == "-i" || a == "--in-place" ||
			strings.HasPrefix(a, "-i") || strings.HasPrefix(a, "--in-place=") {
			continue
		}
		if !strings.HasPrefix(a, "-") || a == "-" {
			operands = append(operands, a)
			continue
		}
		// -e/-f with attached or long-with-value form supplies the script.
		if strings.HasPrefix(a, "--expression=") || strings.HasPrefix(a, "--file=") {
			scriptSuppliedByFlag = true
			continue
		}
		if strings.HasPrefix(a, "--line-length=") {
			continue
		}
		if a == "-e" || a == "--expression" || a == "-f" || a == "--file" {
			scriptSuppliedByFlag = true
			i++ // skip the script/file value
			continue
		}
		if a == "-l" || a == "--line-length" {
			i++ // skip the value
			continue
		}
		// Attached short value forms: `-e'...'` / `-f file` collapse to `-eSCRIPT`.
		if len(a) >= 2 && a[0] == '-' && a[1] != '-' {
			short := a[:2]
			if short == "-e" || short == "-f" {
				scriptSuppliedByFlag = true
				continue
			}
			if short == "-l" {
				continue
			}
		}
		if valueFlags[a] {
			i++
			continue
		}
		if boolFlags[a] {
			continue
		}
		// Unrecognized flag → fail safe (no operands → caller defers).
		return nil
	}
	if scriptSuppliedByFlag {
		// Every non-flag operand is a file.
		return operands
	}
	// The script is the first non-flag operand; drop it. The rest are files.
	if len(operands) <= 1 {
		// Only the script, no files (sed reads stdin) — there is no in-place
		// target despite `-i`. Nothing to contain; return empty so the caller
		// defers (a `sed -i 's/a/b/'` with no file is an odd no-op write form).
		return nil
	}
	return operands[1:]
}

// teeMutates reports whether a tee invocation writes a real file (the in-repo
// write form), as opposed to `tee /dev/null` (the read-only swallow idiom the
// read-only-utility classifier handles). It reuses teeDefers: teeDefers returns
// true exactly when a non-/dev/null destination is present.
func teeMutates(args []string, _ simpleCommand) bool {
	return teeDefers(args)
}

// teeTargets returns tee's real-file write destinations (every non-flag operand
// that is not /dev/null). tee flags (`-a`/--append, `-i`/--ignore-interrupts,
// -p, --output-error[=MODE]) are skipped; /dev/null is dropped because it is not
// a containment-relevant write.
func teeTargets(args []string) []string {
	var out []string
	sawDashDash := false
	for _, a := range args {
		if sawDashDash {
			if a != "/dev/null" {
				out = append(out, a)
			}
			continue
		}
		if a == "--" {
			sawDashDash = true
			continue
		}
		if strings.HasPrefix(a, "-") && a != "-" {
			continue // a tee flag
		}
		if a == "/dev/null" {
			continue
		}
		out = append(out, a)
	}
	return out
}
