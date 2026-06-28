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
// Every utility in the ALLOW set carries a defersForm predicate (#31 review
// HIGH): it reports whether the specific invocation must DEFER rather than
// ALLOW. The predicate fires for a write-capable flag (`sed -i`, `sort -o`,
// `awk -p`), a write-destination operand (`uniq INPUT OUTPUT`, `find -delete`),
// OR any unrecognized flag — so a new or unmodeled mutating mode fails safe
// (criterion 4) rather than riding the ALLOW track.
//
// The original cut treated the "always read-only" set (cat/sort/uniq/cut/...)
// as having no mutating mode and skipped all flag/operand inspection. That was
// wrong: `sort -o FILE` and `uniq IN OUT` write a file, and an unrecognized
// flag on ANY of them is a future write hiding behind the ALLOW. Now the
// fail-safe is uniform across the whole curated set.
type utilitySpec struct {
	// pathBearing is true when the utility's operands are filesystem paths that
	// must pass Engine B containment before the ALLOW. Pure-output utilities
	// (printf, echo, seq, true/false, yes, basename, dirname) take no path
	// operands, so they ALLOW on allowEligible() alone and never fork
	// git rev-parse for a containment check.
	pathBearing bool
	// defersForm reports whether THIS invocation must defer instead of allow.
	// nil means the utility is unconditionally read-only with no flags worth
	// modeling at all (the pure-output set: printf/echo/seq/true/false/yes/
	// basename/dirname — none has a write mode and an unknown flag cannot make
	// one). Every path-bearing utility carries a non-nil predicate so an
	// unrecognized flag, a write-capable flag, or a write-destination operand
	// withholds the ALLOW and defers to the normal pipeline.
	defersForm func(args []string) bool
}

// readOnlyUtilities maps a program basename to its read-only spec. cat/head/
// tail moved here from the classifyPathReader dispatch in classify_command.go:
// they were path-readers that DEFERRED contained operands, and now ALLOW the
// proven read-only form. Pagers / binary dumpers (less, more, od, xxd, hexdump)
// deliberately stay on classifyPathReader (DEFER) — they are out of this
// issue's ALLOW set.
var readOnlyUtilities = map[string]utilitySpec{
	// Path-bearing, no write-capable flag of their own — but they STILL carry a
	// defersForm so an unrecognized flag fails safe (criterion 4): a future flag
	// that turns out to write must not ride the ALLOW just because today's flag
	// set looks read-only. Each predicate enumerates the utility's known
	// read-only flags; anything else defers.
	"cat":      {pathBearing: true, defersForm: catDefers},
	"head":     {pathBearing: true, defersForm: headTailDefers},
	"tail":     {pathBearing: true, defersForm: headTailDefers},
	"wc":       {pathBearing: true, defersForm: wcDefers},
	"cut":      {pathBearing: true, defersForm: cutDefers},
	"tr":       {pathBearing: true, defersForm: trDefers},
	"comm":     {pathBearing: true, defersForm: commDefers},
	"paste":    {pathBearing: true, defersForm: pasteDefers},
	"nl":       {pathBearing: true, defersForm: nlDefers},
	"fold":     {pathBearing: true, defersForm: foldDefers},
	"fmt":      {pathBearing: true, defersForm: fmtDefers},
	"column":   {pathBearing: true, defersForm: columnDefers},
	"rev":      {pathBearing: true, defersForm: revDefers},
	"realpath": {pathBearing: true, defersForm: realpathDefers},

	// sort writes a file with `-o`/`--output` (`sort -o f f` clobbers in place).
	// uniq's optional second path operand is an OUTPUT file (`uniq IN OUT`).
	// Both must defer when the write form is present; both also fail safe on an
	// unrecognized flag.
	"sort": {pathBearing: true, defersForm: sortDefers},
	"uniq": {pathBearing: true, defersForm: uniqDefers},

	// grep never writes a file (it writes only to stdout). It is read-only
	// regardless of flags, but it still carries a fail-safe predicate so a future
	// flag is not auto-allowed — grepDefers recognizes grep's flag grammar and
	// defers on anything outside it. Its operands include a pattern (non-path)
	// plus file paths; containment on the pattern token resolves under cwd and is
	// harmless (a single-arg `grep PATTERN` has no file operand, so the pattern is
	// treated as a path and containment fails closed — it can only deny/ask, never
	// wrongly allow).
	"grep": {pathBearing: true, defersForm: grepDefers},

	// Pure-output, no path operands and no write mode at all: nil defersForm.
	// printf/echo/seq/true/false/yes/basename/dirname write only to stdout and
	// have no flag that could change that, so there is nothing for a predicate to
	// guard. They ALLOW on allowEligible() alone (no containment fork).
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

// flagScan is a reusable defersForm body for the always-read-only path-bearing
// utilities (cat/head/wc/cut/sort/uniq/...). It walks args and reports whether
// the invocation must DEFER. The fail-safe posture (criterion 4, generalized to
// the always-read-only set per the #31 review HIGH finding) is: ALLOW only the
// recognized read-only flag grammar; anything else defers.
//
//   - writeFlags: a flag that writes a file (e.g. sort's `-o`/`--output`).
//     Matched bare, in the combined-short cluster, AND in the `--flag=VALUE`
//     long form. Presence → defer.
//   - valueFlags: a read-only flag that consumes the FOLLOWING token as its
//     value (e.g. cut's `-d ,`). The value token is skipped so it is not misread
//     as an unknown flag or a path operand.
//   - boolFlags: a read-only flag that takes no value.
//   - maxPathOperands: cap on non-flag path operands. -1 means unlimited. A
//     utility whose grammar reserves a trailing operand as a WRITE destination
//     (uniq's optional OUTPUT) sets this to the count of read operands; exceeding
//     it → defer. clusterable controls whether single-dash flags may be bundled
//     (`-cl` == `-c -l`); set false for utilities that don't cluster.
//
// Short flags are also matched as `--flag` long aliases via the same maps when a
// caller registers both spellings.
type flagScan struct {
	valueFlags      map[string]bool
	boolFlags       map[string]bool
	writeFlags      map[string]bool
	maxPathOperands int  // -1 = unlimited
	clusterable     bool // allow `-ab` == `-a -b` for single-char bool flags
}

func (fs flagScan) defers(args []string) bool {
	pathOps := 0
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			// Remaining tokens are operands. Count them against the cap.
			for range args[i+1:] {
				pathOps++
				if fs.maxPathOperands >= 0 && pathOps > fs.maxPathOperands {
					return true
				}
			}
			return false
		}
		// Write-capable flag in any spelling → defer.
		if fs.writeFlags[a] {
			return true
		}
		if strings.HasPrefix(a, "--") && strings.Contains(a, "=") {
			name := a[:strings.IndexByte(a, '=')]
			if fs.writeFlags[name] {
				return true
			}
			if fs.valueFlags[name] || fs.boolFlags[name] {
				continue
			}
			return true // unrecognized long flag → fail safe
		}
		if !strings.HasPrefix(a, "-") || a == "-" {
			// Path operand (or stdin `-`). Count `-` too: it is a read source, and
			// counting it conservatively only tightens the operand cap.
			pathOps++
			if fs.maxPathOperands >= 0 && pathOps > fs.maxPathOperands {
				return true
			}
			continue
		}
		if fs.valueFlags[a] {
			i++ // consume the flag's value
			continue
		}
		if fs.boolFlags[a] {
			continue
		}
		// Attached short-flag value (e.g. `-d,` for `cut -d,`): the flag name is
		// the leading `-X`. Recognized only when `-X` is a known value flag.
		if len(a) >= 2 && a[0] == '-' && a[1] != '-' {
			short := a[:2]
			if fs.valueFlags[short] {
				continue // `-d,` style attached value
			}
			if fs.clusterable && clusterIsReadOnly(a, fs.boolFlags, fs.valueFlags, fs.writeFlags) {
				// A bundle like `-cl` (all bool) or `-sf1` (bool + trailing value
				// flag with attached value). A write flag anywhere makes the whole
				// cluster defer (clusterIsReadOnly returns false) and we fall through
				// to the defer below.
				continue
			}
		}
		return true // unrecognized flag → fail safe
	}
	return false
}

// clusterIsReadOnly reports whether a combined short-flag cluster (`-cl`,
// `-rn`, `-sf1`) is a provably read-only bundle. The rules, walking the cluster
// left to right:
//
//   - A write flag (`-o` on sort) anywhere → not read-only (return false). This
//     is the load-bearing safety guard: `sort -ro file` must NOT ride the ALLOW
//     just because `-r` is a bool and the cluster "looks" short. The write flag
//     is caught here regardless of its position in the cluster.
//   - A bool flag → keep scanning the rest of the cluster.
//   - A value flag → it consumes the REMAINDER of the cluster as its attached
//     value (getopt semantics: in `-sf1`, `-f`'s value is `1`; in `-f1`, `1`).
//     Whatever follows is the value, not independent flags, so we stop scanning
//     and accept. A value flag therefore does not open a write hole — its value
//     is data, and any genuine write flag would have been a distinct cluster
//     char (already rejected above) or a value-taking write flag (rejected by
//     the writeFlags check, which covers value-taking write flags like `-o`).
//   - Anything else (unknown char) → not read-only (return false), fail-safe.
func clusterIsReadOnly(a string, boolFlags, valueFlags, writeFlags map[string]bool) bool {
	for _, c := range a[1:] {
		f := "-" + string(c)
		if writeFlags[f] {
			return false
		}
		if valueFlags[f] {
			// Remaining cluster chars are this flag's attached value. Stop here;
			// the value is data, not flags.
			return true
		}
		if !boolFlags[f] {
			return false
		}
	}
	return true
}

// --- Always-read-only path-bearing utilities. Each enumerates its read-only
// flag grammar so an unrecognized flag, a write-capable flag, or (for uniq) an
// excess write-destination operand fails safe. Flag sets cover both GNU and BSD
// spellings; over-inclusion is safe (it only ALLOWs more read-only forms), while
// any unknown flag still defers. ---

// catDefers: cat has only display flags (-n/-b/-s/-E/-T/-v and long forms); none
// writes. An unknown flag defers.
func catDefers(args []string) bool {
	return flagScan{
		boolFlags: map[string]bool{
			"-A": true, "--show-all": true, "-b": true, "--number-nonblank": true,
			"-e": true, "-E": true, "--show-ends": true, "-n": true, "--number": true,
			"-s": true, "--squeeze-blank": true, "-t": true, "-T": true,
			"--show-tabs": true, "-u": true, "-v": true, "--show-nonprinting": true,
		},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// headTailDefers: head/tail share -c/-n (value), -q/-v, and tail's -f/-F/-s/--pid/
// --retry. None writes. `-n5`/`-c10` attached forms are handled by the value-flag
// attached check. A leading `-5` (obsolete count) is treated as an unknown flag
// and defers — conservative, not wrong.
func headTailDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{
			"-c": true, "--bytes": true, "-n": true, "--lines": true,
			"-s": true, "--sleep-interval": true, "--pid": true,
			"--max-unchanged-stats": true,
		},
		boolFlags: map[string]bool{
			"-q": true, "--quiet": true, "--silent": true, "-v": true, "--verbose": true,
			"-z": true, "--zero-terminated": true,
			"-f": true, "--follow": true, "-F": true, "--retry": true,
		},
		maxPathOperands: -1,
	}.defers(args)
}

// wcDefers: wc has only counting flags (-c/-m/-l/-w/-L and --files0-from value).
func wcDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{"--files0-from": true},
		boolFlags: map[string]bool{
			"-c": true, "--bytes": true, "-m": true, "--chars": true,
			"-l": true, "--lines": true, "-w": true, "--words": true,
			"-L": true, "--max-line-length": true,
		},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// cutDefers: cut selects fields/bytes/chars to stdout. -b/-c/-f/-d/--output-delimiter
// take values; none writes a file.
func cutDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{
			"-b": true, "--bytes": true, "-c": true, "--characters": true,
			"-f": true, "--fields": true, "-d": true, "--delimiter": true,
			"--output-delimiter": true,
		},
		boolFlags: map[string]bool{
			"-s": true, "--only-delimited": true, "-n": true,
			"--complement": true, "-z": true, "--zero-terminated": true,
		},
		maxPathOperands: -1,
		// clusterable: cut's value flags (-b/-c/-f/-d) are not bool flags, so a
		// cluster containing one defers; an all-bool cluster (`cut -sn`) ALLOWs.
		// `cut -sf1` is `-s` (bool) + attached `-f1` value, handled before the
		// cluster path. No write flag exists for cut.
		clusterable: true,
	}.defers(args)
}

// trDefers: tr reads stdin and writes stdout; it takes NO file operand (its
// non-flag args are SET1/SET2, not paths). So pathBearing containment sees the
// SETs as "paths" — harmless, they resolve under cwd and contain. No flag writes.
func trDefers(args []string) bool {
	return flagScan{
		boolFlags: map[string]bool{
			"-c": true, "-C": true, "--complement": true,
			"-d": true, "--delete": true, "-s": true, "--squeeze-repeats": true,
			"-t": true, "--truncate-set1": true, "-u": true,
		},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// commDefers: comm compares two sorted files to stdout. -1/-2/-3 and
// --output-delimiter(value); no write flag.
func commDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{"--output-delimiter": true},
		boolFlags: map[string]bool{
			"-1": true, "-2": true, "-3": true,
			"--check-order": true, "--nocheck-order": true,
			"--total": true, "-z": true, "--zero-terminated": true,
		},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// pasteDefers: paste merges lines to stdout. -d/--delimiters(value), -s/-z.
func pasteDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{"-d": true, "--delimiters": true},
		boolFlags: map[string]bool{
			"-s": true, "--serial": true, "-z": true, "--zero-terminated": true,
		},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// nlDefers: nl numbers lines to stdout. Many value flags (-b/-d/-f/-h/-i/-l/-n/
// -s/-v/-w); none writes a file.
func nlDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{
			"-b": true, "--body-numbering": true, "-d": true, "--section-delimiter": true,
			"-f": true, "--footer-numbering": true, "-h": true, "--header-numbering": true,
			"-i": true, "--line-increment": true, "-l": true, "--join-blank-lines": true,
			"-n": true, "--number-format": true, "-s": true, "--number-separator": true,
			"-v": true, "--starting-line-number": true, "-w": true, "--number-width": true,
		},
		boolFlags:       map[string]bool{"-p": true, "--no-renumber": true},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// foldDefers: fold wraps lines to stdout. -w/--width(value), -b/-s.
func foldDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{"-w": true, "--width": true},
		boolFlags: map[string]bool{
			"-b": true, "--bytes": true, "-s": true, "--spaces": true,
		},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// fmtDefers: fmt reformats paragraphs to stdout. -w/--width(value),
// -p/--prefix(value), -c/-s/-t/-u.
func fmtDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{
			"-w": true, "--width": true, "-p": true, "--prefix": true,
			"-g": true, "--goal": true,
		},
		boolFlags: map[string]bool{
			"-c": true, "--crown-margin": true, "-s": true, "--split-only": true,
			"-t": true, "--tagged-paragraph": true, "-u": true, "--uniform-spacing": true,
		},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// columnDefers: column formats input into columns on stdout. BSD/util-linux flags
// -c/-s/-t/-o/-N/-R/-W/-d/-x etc. None writes a file (BSD `-o` is the OUTPUT
// SEPARATOR string, util-linux `-o`/--output-separator likewise — stdout only).
func columnDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{
			"-c": true, "--output-width": true, "-s": true, "--separator": true,
			"-o": true, "--output-separator": true, "-N": true, "--table-columns": true,
			"-R": true, "--table-right": true, "-W": true, "--table-wrap": true,
			"-d": true, "-H": true, "--table-hide": true, "-O": true, "--table-order": true,
			"-l": true, "--table-columns-limit": true,
		},
		boolFlags: map[string]bool{
			"-t": true, "--table": true, "-x": true, "--fillrows": true,
			"-e": true, "--table-empty-lines": true, "-n": true,
		},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// revDefers: rev reverses characters per line to stdout. It has essentially no
// flags; any flag defers (fail-safe).
func revDefers(args []string) bool {
	return flagScan{maxPathOperands: -1}.defers(args)
}

// realpathDefers: realpath resolves paths to stdout; no write flag. -e/-m/-s/-z/-q
// and the value flag --relative-to / --relative-base.
func realpathDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{"--relative-to": true, "--relative-base": true},
		boolFlags: map[string]bool{
			"-e": true, "--canonicalize-existing": true, "-m": true,
			"--canonicalize-missing": true, "-L": true, "--logical": true,
			"-P": true, "--physical": true, "-q": true, "--quiet": true,
			"-s": true, "--strip": true, "--no-symlinks": true,
			"-z": true, "--zero": true,
		},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// grepDefers: grep writes only to stdout, never a file, so no write flag exists.
// It still fails safe on an unrecognized flag. grep has a large flag grammar;
// value flags (-e/-f/-m/-A/-B/-C/--color etc.) and bool flags are enumerated.
func grepDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{
			"-e": true, "--regexp": true, "-f": true, "--file": true,
			"-m": true, "--max-count": true, "-A": true, "--after-context": true,
			"-B": true, "--before-context": true, "-C": true, "--context": true,
			"-d": true, "--directories": true, "-D": true, "--devices": true,
			"--include": true, "--exclude": true, "--exclude-dir": true,
			"--include-dir": true, "--group-separator": true, "--label": true,
			"--color": true, "--colour": true, "--binary-files": true,
		},
		boolFlags: map[string]bool{
			"-E": true, "--extended-regexp": true, "-F": true, "--fixed-strings": true,
			"-G": true, "--basic-regexp": true, "-P": true, "--perl-regexp": true,
			"-i": true, "--ignore-case": true, "-v": true, "--invert-match": true,
			"-w": true, "--word-regexp": true, "-x": true, "--line-regexp": true,
			"-c": true, "--count": true, "-l": true, "--files-with-matches": true,
			"-L": true, "--files-without-match": true, "-n": true, "--line-number": true,
			"-H": true, "--with-filename": true, "-h": true, "--no-filename": true,
			"-o": true, "--only-matching": true, "-q": true, "--quiet": true, "--silent": true,
			"-r": true, "--recursive": true, "-R": true, "--dereference-recursive": true,
			"-s": true, "--no-messages": true, "-a": true, "--text": true,
			"-I": true, "-z": true, "--null-data": true, "-Z": true, "--null": true,
			"-b": true, "--byte-offset": true, "-T": true, "--initial-tab": true,
			"-U": true, "--binary": true, "--line-buffered": true, "-u": true, "--unix-byte-offsets": true,
		},
		maxPathOperands: -1,
		clusterable:     true,
	}.defers(args)
}

// sortDefers: sort writes a file with `-o FILE` / `--output=FILE`
// (`sort -o f f` clobbers f in place). That write form must defer (#31 review
// HIGH). All other sort flags are read-only; an unrecognized flag fails safe.
func sortDefers(args []string) bool {
	return flagScan{
		writeFlags: map[string]bool{"-o": true, "--output": true},
		valueFlags: map[string]bool{
			"-k": true, "--key": true, "-t": true, "--field-separator": true,
			"-S": true, "--buffer-size": true, "-T": true, "--temporary-directory": true,
			"--batch-size": true, "--compress-program": true, "--files0-from": true,
			"--random-source": true, "--parallel": true, "--sort": true,
		},
		boolFlags: map[string]bool{
			"-b": true, "--ignore-leading-blanks": true, "-c": true, "--check": true,
			"-C": true, "--check=quiet": true, "-d": true, "--dictionary-order": true,
			"-f": true, "--ignore-case": true, "-g": true, "--general-numeric-sort": true,
			"-h": true, "--human-numeric-sort": true, "-i": true, "--ignore-nonprinting": true,
			"-M": true, "--month-sort": true, "-m": true, "--merge": true,
			"-n": true, "--numeric-sort": true, "-R": true, "--random-sort": true,
			"-r": true, "--reverse": true, "-s": true, "--stable": true,
			"-u": true, "--unique": true, "-V": true, "--version-sort": true,
			"-z": true, "--zero-terminated": true, "--debug": true,
		},
		maxPathOperands: -1,
		// clusterable: sort's only write flag is -o, which clusterIsReadOnly rejects
		// (`sort -ro` → cluster contains a write flag → defers). Value flags
		// (-k/-t/-S/-T) are likewise not bool flags, so a cluster containing one
		// defers. Only all-bool clusters (`sort -rn`, `sort -ru`) ALLOW.
		clusterable: true,
	}.defers(args)
}

// uniqDefers: uniq's operand grammar is `uniq [INPUT [OUTPUT]]` — the optional
// SECOND path operand is a WRITE destination (`uniq IN OUT` writes OUT). So at
// most ONE path operand is read-only; a second defers (#31 review HIGH). uniq
// has no write-capable flag, but it still fails safe on an unrecognized flag.
func uniqDefers(args []string) bool {
	return flagScan{
		// -f/-s/-w take a value. -D/--all-repeated and --group take an OPTIONAL
		// attached value (`--all-repeated=METHOD`), handled by the long-with-value
		// path; their bare forms take no separate token, so they are bool flags
		// (a value flag would wrongly swallow the INPUT path).
		valueFlags: map[string]bool{
			"-f": true, "--skip-fields": true, "-s": true, "--skip-chars": true,
			"-w": true, "--check-chars": true,
		},
		boolFlags: map[string]bool{
			"-c": true, "--count": true, "-d": true, "--repeated": true,
			"-i": true, "--ignore-case": true, "-u": true, "--unique": true,
			"-z": true, "--zero-terminated": true,
			"-D": true, "--all-repeated": true, "--group": true,
		},
		maxPathOperands: 1, // a second operand is the OUTPUT file → defer
		// clusterable: uniq has no write flag; clustering bundles only bool flags
		// (`uniq -cd` == `-c -d`). The OUTPUT-operand guard (maxPathOperands: 1) is
		// independent of flag clustering, so `uniq -cd IN OUT` still defers on the
		// second operand. Value flags (-f/-s/-w) are not bool flags, so a cluster
		// containing one defers.
		clusterable: true,
	}.defers(args)
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
// except when it writes a file. Three write modes are modeled:
//
//   - gawk in-place editing: `-i inplace` / `--include inplace` /
//     `--include=inplace`.
//   - gawk profile/pretty-print: `-p`/`--profile` (writes awkprof.out) and
//     `-o`/`--pretty-print` (writes awkprof.out). The file argument is OPTIONAL
//     and ATTACHED (`-pFILE`, `-oFILE`, `--profile=FILE`); a bare `-p`/`-o`
//     still writes the default awkprof.out, so the bare form ALSO defers
//     (#31 review MEDIUM — these were previously listed as read-only boolFlags).
//   - gawk dump-variables: `-d`/`--dump-variables` writes awkvars.out. Swept in
//     with -p/-o per "fix the class": same default-output-file footgun.
//
// `-O`/`--optimize`, `-P`/`--posix`, and `-D`/`--debug` do NOT write a file and
// stay read-only. An explicit output-file redirect is caught by
// sc.hasRedirectToFile in the caller. Any unrecognized flag also defers.
func awkDefers(args []string) bool {
	valueFlags := map[string]bool{"-F": true, "--field-separator": true, "-v": true, "--assign": true, "-f": true, "--file": true}
	// Flags that write a file → defer (bare, attached, or long-with-value form).
	writeFlags := map[string]bool{
		"-o": true, "--pretty-print": true,
		"-p": true, "--profile": true,
		"-d": true, "--dump-variables": true,
	}
	boolFlags := map[string]bool{
		"--posix": true, "--traditional": true, "-c": true, "--csv": true,
		"--characters-as-bytes": true, "-C": true, "--copyright": true,
		"-g": true, "--gen-pot": true,
		"-l": true, "--lint": true, "-n": true, "--non-decimal-data": true,
		"-N": true, "--use-lc-numeric": true, "-O": true,
		"--optimize": true, "-P": true,
		"-r": true, "--re-interval": true, "-s": true, "--no-optimize": true,
		"-S": true, "--sandbox": true, "-t": true, "--lint-old": true,
		"-D": true, "--debug": true,
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
		// Write flags in bare form (`-p`, `-o`, `-d`, `--profile`, ...) write the
		// default output file → defer.
		if writeFlags[a] {
			return true
		}
		// Write flags in attached short form (`-pFILE`, `-oFILE`, `-dFILE`) or
		// long-with-value form (`--profile=FILE`, `--pretty-print=FILE`,
		// `--dump-variables=FILE`) → defer.
		if strings.HasPrefix(a, "-p") || strings.HasPrefix(a, "-o") || strings.HasPrefix(a, "-d") {
			return true
		}
		if strings.HasPrefix(a, "--profile=") || strings.HasPrefix(a, "--pretty-print=") || strings.HasPrefix(a, "--dump-variables=") {
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
		// Attached short value form (`-F:`, `-v x=1`, `-fprog.awk`): the flag name
		// is the leading `-X`; recognized only when `-X` is a known value flag.
		if len(a) >= 2 && a[0] == '-' && a[1] != '-' && valueFlags[a[:2]] {
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
