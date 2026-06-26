package main

import (
	"fmt"
	"strings"
)

// readOnlyUtility is the curated read-only-utility classifier (#31): it
// auto-ALLOWs a fixed set of text/data utilities when their invocation is
// provably non-mutating, instead of deferring (which then fails to match any
// settings.json allow entry and prompts the user). These program heads are the
// single largest source of permission prompts in practice.
//
// Two posture invariants make the ALLOW safe, both inherited from the existing
// allow track:
//
//   - sc.allowEligible() must hold: no real-file redirect (exfiltration /
//     clobber) and no command substitution / unresolved expansion (#1, a
//     `$(...)`-built arg can't be statically proven safe). Checked by the
//     caller's gate before any per-program logic.
//   - Path operands of a path-bearing utility must pass Engine B containment,
//     so a `cat ../sibling-repo/node_modules/x` still denies (#148) and a
//     worktree-escaping read still asks (#127). Reused from classifyPathReader
//     via containPathOperands.
//
// A utility is split into "always read-only" (no mutating mode worth modeling)
// and "conditionally read-only" (a mutating mode gated by a flag). For the
// conditional set, defersForm reports whether the specific invocation must
// DEFER rather than ALLOW — it fires both for a known mutating flag (`sed -i`,
// `find -delete`) AND for any unrecognized flag, so a new mutating mode fails
// safe (criterion 4) rather than getting auto-allowed.
type utilitySpec struct {
	// pathBearing is true when the utility's operands are filesystem paths that
	// must pass Engine B containment before the ALLOW. Pure-output utilities
	// (printf, echo, seq, true/false, yes, basename, dirname) take no path
	// operands, so they ALLOW on allowEligible() alone and never fork
	// git rev-parse for a containment check.
	pathBearing bool
	// defersForm reports whether THIS invocation must defer instead of allow.
	// nil means the utility is always read-only (no mutating mode). A non-nil
	// predicate returns true for a mutating flag or any unrecognized flag, so
	// the ALLOW is withheld and the line defers to the normal pipeline.
	defersForm func(args []string) bool
}

// readOnlyUtilities maps a program basename to its read-only spec. cat/head/
// tail moved here from the classifyPathReader dispatch in classify_command.go:
// they were path-readers that DEFERRED contained operands, and now ALLOW the
// proven read-only form. Pagers / binary dumpers (less, more, od, xxd, hexdump)
// deliberately stay on classifyPathReader (DEFER) — they are out of this
// issue's ALLOW set.
var readOnlyUtilities = map[string]utilitySpec{
	// Always-read-only, path-bearing: operands are files to read.
	"cat":      {pathBearing: true},
	"head":     {pathBearing: true},
	"tail":     {pathBearing: true},
	"wc":       {pathBearing: true},
	"sort":     {pathBearing: true},
	"uniq":     {pathBearing: true},
	"cut":      {pathBearing: true},
	"tr":       {pathBearing: true},
	"comm":     {pathBearing: true},
	"paste":    {pathBearing: true},
	"nl":       {pathBearing: true},
	"fold":     {pathBearing: true},
	"fmt":      {pathBearing: true},
	"column":   {pathBearing: true},
	"rev":      {pathBearing: true},
	"realpath": {pathBearing: true},
	// grep never writes; it is read-only regardless of flags, so no defersForm.
	// Its operands include a pattern (non-path) plus file paths; containment on
	// the pattern token resolves under cwd and is harmless.
	"grep": {pathBearing: true},

	// Always-read-only, pure output: no path operands, so no containment fork.
	"printf":   {pathBearing: false},
	"echo":     {pathBearing: false},
	"basename": {pathBearing: false},
	"dirname":  {pathBearing: false},
	"true":     {pathBearing: false},
	"false":    {pathBearing: false},
	"seq":      {pathBearing: false},
	"yes":      {pathBearing: false},

	// Conditionally read-only: a mutating mode is gated by a flag. defersForm
	// withholds the ALLOW for the mutating flag OR any unrecognized flag.
	"sed":  {pathBearing: true, defersForm: sedDefers},
	"awk":  {pathBearing: true, defersForm: awkDefers},
	"jq":   {pathBearing: true, defersForm: jqDefers},
	"find": {pathBearing: true, defersForm: findDefers},
	// tee's operands are WRITE destinations, not read sources, and teeDefers
	// already restricts them to /dev/null (the only allowed form). It is
	// therefore NOT pathBearing: read-containment on /dev/null would wrongly
	// deny it as a cross-repo path. teeDefers is the complete gate.
	"tee": {pathBearing: false, defersForm: teeDefers},
}

// classifyReadOnlyUtility ALLOWs a curated read-only utility when its
// invocation is provably non-mutating, else defers. The caller has already
// confirmed prog is in readOnlyUtilities.
func classifyReadOnlyUtility(prog string, args []string, sc simpleCommand, ev *Event) Decision {
	spec := readOnlyUtilities[prog]

	// A real-file redirect (clobber/exfiltration) disqualifies the allow track:
	// the bytes leave stdout for a file. Defer to the normal pipeline. (The
	// unknown-expansion half of allowEligible is handled below: a path-bearing
	// utility fails closed ASK on a dynamic path operand, a stronger posture
	// than defer.)
	if sc.hasRedirectToFile {
		return deferToPipeline()
	}

	// Conditionally-read-only utilities defer on a mutating flag or any
	// unrecognized flag (fail-safe for new mutating modes — criterion 4).
	if spec.defersForm != nil && spec.defersForm(args) {
		return deferToPipeline()
	}

	if spec.pathBearing {
		// A command substitution / unresolved expansion in a path operand can't
		// be statically contained → fail closed ASK (the same posture
		// classifyPathReader holds), not a silent defer (#1).
		if sc.hasUnknownExpansion {
			return ask("bash-read:dynamic-path", fmt.Sprintf(
				"Blocked: '%s' has a path argument built from an expansion the gate cannot resolve statically; "+
					"escalating to a human decision (fail-closed).", prog))
		}
		// Engine B containment on every path operand: a cross-repo read still
		// denies (#148), a worktree-escape read still asks (#127). A
		// non-contained operand returns that deny/ask verdict; otherwise ALLOW.
		if d, ok := containPathOperands(prog, pathOperands(args), ev); !ok {
			return d
		}
	} else if !sc.allowEligible() {
		// Pure-output utility (printf/echo/seq/...) with an unresolved
		// expansion: no path to contain, but #1 still forbids the allow track.
		return deferToPipeline()
	}

	return allow(fmt.Sprintf("%s is a provably read-only utility invocation", prog))
}

// sedDefers reports whether a sed invocation must defer rather than allow. sed
// is read-only EXCEPT for in-place editing (`-i` / `--in-place`, including the
// BSD/GNU suffix forms `-i.bak` / `--in-place=.bak`). Any flag outside sed's
// known read-only set also defers, so a future mutating flag fails safe.
func sedDefers(args []string) bool {
	// Known read-only sed flags. `-e`/`-f`/`-l` take a following value; the
	// value is consumed so it is not mistaken for an unknown flag.
	valueFlags := map[string]bool{"-e": true, "--expression": true, "-f": true, "--file": true, "-l": true, "--line-length": true}
	boolFlags := map[string]bool{
		"-n": true, "--quiet": true, "--silent": true,
		"-E": true, "-r": true, "--regexp-extended": true,
		"-z": true, "--null-data": true,
		"-s": true, "--separate": true,
		"-u": true, "--unbuffered": true,
		"--posix": true, "--debug": true, "--sandbox": true,
		"--follow-symlinks": true,
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			return false // remaining tokens are operands, not flags
		}
		if a == "-i" || a == "--in-place" || strings.HasPrefix(a, "-i") || strings.HasPrefix(a, "--in-place=") {
			return true // in-place edit → mutating
		}
		if !strings.HasPrefix(a, "-") || a == "-" {
			continue // operand (script or file path)
		}
		if strings.HasPrefix(a, "--") && strings.Contains(a, "=") {
			// long flag with attached value (e.g. --expression=...): recognized
			// only if its name is a known read-only flag.
			name := a[:strings.IndexByte(a, '=')]
			if valueFlags[name] || boolFlags[name] {
				continue
			}
			return true // unrecognized → fail safe
		}
		if valueFlags[a] {
			i++ // skip the flag's value
			continue
		}
		if boolFlags[a] {
			continue
		}
		return true // unrecognized flag → fail safe
	}
	return false
}

// awkDefers reports whether an awk invocation must defer. awk is read-only
// except for gawk in-place editing (`-i inplace` / `--include inplace` /
// `--include=inplace`); an explicit output-file redirect is already caught by
// sc.hasRedirectToFile in the caller. Any unrecognized flag also defers.
func awkDefers(args []string) bool {
	valueFlags := map[string]bool{"-F": true, "--field-separator": true, "-v": true, "--assign": true, "-f": true, "--file": true}
	boolFlags := map[string]bool{
		"--posix": true, "--traditional": true, "-c": true, "--csv": true,
		"--characters-as-bytes": true, "-C": true, "--copyright": true,
		"-d": true, "--dump-variables": true, "-g": true, "--gen-pot": true,
		"-l": true, "--lint": true, "-n": true, "--non-decimal-data": true,
		"-N": true, "--use-lc-numeric": true, "-o": true, "-O": true,
		"--optimize": true, "-p": true, "-P": true, "--profile": true,
		"-r": true, "--re-interval": true, "-s": true, "--no-optimize": true,
		"-S": true, "--sandbox": true, "-t": true, "--lint-old": true,
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			return false
		}
		// gawk in-place: `-i inplace`, `--include inplace`, `--include=inplace`.
		if a == "-i" || a == "--include" {
			if i+1 < len(args) && args[i+1] == "inplace" {
				return true
			}
			// `-i`/`--include` loading another extension is read-only, but the
			// extension name is unknown territory; consume its value and continue.
			i++
			continue
		}
		if a == "--include=inplace" {
			return true
		}
		if !strings.HasPrefix(a, "-") || a == "-" {
			continue // operand (program text or file path)
		}
		if strings.HasPrefix(a, "--") && strings.Contains(a, "=") {
			name := a[:strings.IndexByte(a, '=')]
			if valueFlags[name] || boolFlags[name] || name == "--include" {
				continue
			}
			return true
		}
		if valueFlags[a] {
			i++
			continue
		}
		if boolFlags[a] {
			continue
		}
		return true
	}
	return false
}

// jqDefers reports whether a jq invocation must defer. jq is read-only unless a
// caller writes its output back to a file — there is no standard in-place flag,
// but `-i` / `--in-place` is reserved here so a future/aliased in-place mode
// fails safe. Output redirects are caught by sc.hasRedirectToFile in the caller.
func jqDefers(args []string) bool {
	for _, a := range args {
		if a == "--" {
			return false
		}
		if a == "-i" || a == "--in-place" {
			return true
		}
	}
	return false
}

// findDefers reports whether a find invocation must defer. find is read-only
// unless it carries an action that mutates the filesystem or runs an arbitrary
// command: `-delete`, the `-exec*`/`-ok*` family (which run ANY command, e.g.
// `-exec rm`), or the file-writing primaries `-fprint*`/`-fls`. Any of these →
// defer; the safe traversal/test forms (`-name`, `-type`, `-print`, ...) allow.
func findDefers(args []string) bool {
	for _, a := range args {
		switch a {
		case "-delete",
			"-exec", "-execdir", "-ok", "-okdir",
			"-fprint", "-fprint0", "-fprintf", "-fls":
			return true
		}
	}
	return false
}

// teeDefers reports whether a tee invocation must defer. tee writes its stdin
// to every file operand, so it is read-only ONLY when its sole destination is
// /dev/null (a common "swallow output" idiom). Any other operand is a real-file
// write → defer. Flags (`-a`, `-i`, ...) are skipped; a non-flag operand other
// than /dev/null disqualifies the allow.
func teeDefers(args []string) bool {
	for _, a := range args {
		if a == "--" {
			continue
		}
		if strings.HasPrefix(a, "-") && a != "-" {
			continue // a tee flag (-a/--append, -i/--ignore-interrupts, ...)
		}
		if a != "/dev/null" {
			return true // a real-file destination → not read-only
		}
	}
	return false
}
