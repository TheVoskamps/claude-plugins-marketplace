package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
)

// readOnlyUtility is the curated read-only-utility classifier: it
// auto-ALLOWs a fixed set of text/data utilities when their invocation is
// provably non-mutating, instead of deferring (which then fails to match any
// settings.json allow entry and prompts the user). These program heads are the
// single largest source of permission prompts in practice.
//
// The posture invariants that make the ALLOW safe, all inherited from the
// existing allow track, are:
//
//   - No command substitution / unresolved expansion (a `$(...)`-built arg
//     can't be statically proven safe), and no real-file redirect — except one
//     whose every destination is a session-shaped harness scratchpad, a region
//     the carve-out designates safe by construction (redirectVetoesAllow grades
//     it; the two conditions together are sc.allowEligible() with its redirect
//     half graded rather than absolute). Both can only withhold the ALLOW,
//     so classifyReadOnlyUtility runs them after containment, which can
//     deny.
//   - Path operands of a path-bearing utility must pass Engine B containment,
//     so a `cat ../sibling-repo/node_modules/x` still denies; so does a
//     target resolving into the primary clone / shared git dir, whose
//     working file can differ from this worktree's, and so does one under
//     `.git/`. Reused from classifyPathReader via containPathOperands.
//
// Every utility in the ALLOW set carries a defersForm predicate: it reports
// whether the specific invocation must DEFER rather than ALLOW. The predicate
// fires for a write-capable flag (`sed -i`, `sort -o`, `awk -p`), a
// write-destination operand (`uniq INPUT OUTPUT`, `find -delete`),
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
	// operands, so they ALLOW on the posture invariants above alone and
	// never fork git rev-parse for a containment check of their own. (A
	// redirect destination is not an operand; when one is present it is graded
	// separately, by redirectVetoesAllow, which does resolve repo context.)
	pathBearing bool
	// defersForm reports whether THIS invocation must defer instead of allow.
	// nil means the utility is unconditionally read-only with no flags worth
	// modeling at all (the pure-output set: printf/echo/seq/true/false/yes/
	// basename/dirname — none has a write mode and an unknown flag cannot make
	// one). Every path-bearing utility carries a non-nil predicate so an
	// unrecognized flag, a write-capable flag, or a write-destination operand
	// withholds the ALLOW and defers to the normal pipeline.
	defersForm func(args []string) bool
	// operandsFn returns the tokens of THIS invocation that name files the
	// utility reads, parsed against the utility's own operand grammar. nil means
	// every non-flag token is a path (pathOperands), which is right for a
	// utility whose leading positional is already a file.
	//
	// It exists because that default is WRONG for a utility whose leading
	// positional is a program, not a path: sed's script, awk's program text, and
	// grep's pattern. A `sed -n '/A/,/B/p' f.md` range address starts with '/',
	// so containment read it as an absolute path and DENIED the command as a
	// cross-repo read. The write track has had this grammar since it was built
	// (inRepoWriteSpec.operandsFn, for `sed -i`); this is the same idea on the
	// read track, which had only the undifferentiated non-flag-token walk.
	operandsFn func(args []string) []string
	// pathValueFlags names the flags whose VALUE is a filesystem path — one the
	// utility READS (`grep -f PATFILE`, `awk -f PROG`,
	// `diff -X EXCLUDEFILE`, `wc --files0-from=LIST`), WRITES (`sort -T DIR`
	// holds its temporary spill files) or RESOLVES (`realpath
	// --relative-to=DIR`). Their values are added to the containment list by
	// operands() below.
	//
	// Neither operand walk can see them on its own. pathOperands drops every
	// token beginning with `-`, so a GLUED spelling (`diff -X/etc/passwd`,
	// `wc --files0-from=/etc/shadow`) never reaches containment while the
	// separate-token spelling of the same command does. A per-program
	// operandsFn goes further and CONSUMES the value in both spellings —
	// correct for a pattern (`grep -e`), a number (`diff -U`) or a label
	// (`diff -L`), wrong for a filename the utility opens.
	// valueFlags is the utility's COMPLETE value-taking flag set (of which
	// pathValueFlags is a subset); pathFlagValues needs it to know where a value
	// begins inside a bundled short-flag cluster (`grep -rf PATFILE`).
	pathValueFlags map[string]bool
	valueFlags     map[string]bool
	// pathValuesFn returns the path-valued flag values of THIS invocation, read
	// by the utility's own option grammar. When set it is used in place of the
	// pathFlagValues walk over valueFlags and pathValueFlags, for a utility whose
	// option spellings that walk cannot read (sed's abbreviated long options).
	pathValuesFn func(args []string) []string
	// boolFlags, when set, holds every long option of the utility that takes
	// no value, so that with valueFlags it holds all of the utility's long
	// options. A utility that has one accepts a long option spelled as any
	// unique prefix of its name, as getopt_long and less's own parser do, and
	// fileOperands resolves such a prefix against both tables. Only
	// fileOperands reads it.
	boolFlags map[string]bool
	// plusOptions is true when an argument starting with `+` is an option, not
	// a file: tail's obsolete `+N` count, or less's `+cmd`. Only fileOperands
	// reads it.
	plusOptions bool
}

// operands returns the utility's read path operands for this invocation:
// its own operand grammar when it has one and the plain non-flag walk
// otherwise, plus the values of any path-valued flags it carries.
//
// The flag values are APPENDED to what the operand walk produced, never
// substituted for it, so this addition can only ever put MORE paths through
// containment. That keeps the property the flag models rely on — a mismodelled
// flag arity can make a verdict stricter (an extra operand to contain) but
// never open a hole by swallowing a real path operand.
func (s utilitySpec) operands(args []string) []string {
	ops := pathOperands(args)
	if s.operandsFn != nil {
		ops = s.operandsFn(args)
	}
	return dedupeOperands(append(ops, s.pathValues(args)...))
}

// pathValues returns the values of the path-valued flags this invocation
// carries: pathValuesFn's when the utility has one, pathFlagValues' otherwise.
func (s utilitySpec) pathValues(args []string) []string {
	if s.pathValuesFn != nil {
		return s.pathValuesFn(args)
	}
	return pathFlagValues(args, s.valueFlags, s.pathValueFlags)
}

// fileOperands returns the operands of this invocation that name a file the
// utility reads: its own operand grammar when it has one, and otherwise every
// argument that is neither an option nor the value of one of valueFlags, read
// with getopt's spellings. `-` names standard input, not a file.
//
// operands, which feeds containment, walks a utility with no grammar of its own
// with pathOperands instead, which also keeps each flag's value: containing a
// token that names no file costs nothing there, while a mismodelled arity that
// swallowed a real path would let it escape. This walk is for a caller that
// needs the other direction — a value counted as a file is a file the
// invocation does not read. For the same reason a `+` argument of a utility
// whose plusOptions is set is an option here, not a file.
func (s utilitySpec) fileOperands(args []string) []string {
	var ops []string
	if s.operandsFn != nil {
		ops = s.operandsFn(args)
	} else {
		ops = getoptOperands(args, s.valueFlags, s.boolFlags, s.plusOptions)
	}
	out := ops[:0:0]
	for _, op := range ops {
		if op != "-" {
			out = append(out, op)
		}
	}
	return out
}

// readFileOperands returns the operands of prog's invocation that name a file
// it reads, by the grammar the read tracks give prog: its readOnlyUtilities
// entry, its pathReaderFileSpecs entry, or for any other reader the plain
// non-flag walk classifyPathReader contains.
func readFileOperands(prog string, args []string) []string {
	if spec, ok := readOnlyUtilities[prog]; ok {
		return spec.fileOperands(args)
	}
	if spec, ok := pathReaderFileSpecs[prog]; ok {
		return spec.fileOperands(args)
	}
	return pathOperands(args)
}

// pathReaderFileSpecs gives a classifyPathReader program the option grammar
// readFileOperands reads it with. classifyPathReader's own containment keeps
// the plain non-flag walk.
var pathReaderFileSpecs = map[string]utilitySpec{
	"less": {valueFlags: lessValueFlags, boolFlags: lessBoolFlags, plusOptions: true},
}

// lessValueFlags and lessBoolFlags hold every option in the option table
// (opttbl.c) of less v581 or of less's source at v712, the pager macOS,
// FreeBSD and Linux all ship. An option of type STRING or NUMBER
// takes a value, in the same argument or the next one, and is in
// lessValueFlags, in its short form when it has one and its long form. Every
// other option is in lessBoolFlags by its long name, a triple option once in
// lower case and once in upper case, since less matches a triple option's long
// name in either; a short option that takes no value needs no entry. `--tty`
// and `--rstat` are declared only in a LESSTEST build, which no platform
// ships, so they are in neither table and are no candidate for an abbreviation.
var lessValueFlags = map[string]bool{
	"-b": true, "--buffers": true,
	"-D": true, "--color": true,
	"-h": true, "--max-back-scroll": true,
	"-j": true, "--jump-target": true,
	"-k": true, "--lesskey-file": true,
	"--lesskey-content": true, "--lesskey-src": true,
	"-o": true, "--log-file": true,
	"-O": true, "--LOG-FILE": true,
	"-p": true, "--pattern": true,
	"-P": true, "--prompt": true,
	"-t": true, "--tag": true,
	"-T": true, "--tag-file": true,
	"-x": true, "--tabs": true,
	"-y": true, "--max-forw-scroll": true,
	"-z": true, "--window": true,
	"-\"": true, "--quotes": true,
	"-#": true, "--shift": true,
	"--rscroll": true, "--emouse": true, "--wheel-lines": true,
	"--line-num-width": true, "--status-col-width": true, "--time-file-size": true,
	"--header": true, "--search-options": true, "--modelines": true,
	"--intr": true, "--cmd": true, "--match-shift": true,
	"--autosave": true, "--end-prompt": true,
}

var lessBoolFlags = map[string]bool{
	"--search-skip-screen": true, "--SEARCH-SKIP-SCREEN": true,
	"--auto-buffers": true,
	"--clear-screen": true, "--CLEAR-SCREEN": true,
	"--dumb":        true,
	"--quit-at-eof": true, "--QUIT-AT-EOF": true,
	"--force": true, "--quit-if-one-screen": true,
	"--hilite-search": true, "--HILITE-SEARCH": true,
	"--ignore-case": true, "--IGNORE-CASE": true,
	"--status-column": true, "--quit-on-intr": true, "--no-lessopen": true,
	"--long-prompt": true, "--LONG-PROMPT": true,
	"--line-numbers": true, "--LINE-NUMBERS": true,
	"--quiet": true, "--QUIET": true, "--silent": true, "--SILENT": true,
	"--raw-control-chars": true, "--RAW-CONTROL-CHARS": true,
	"--squeeze-blank-lines": true, "--chop-long-lines": true,
	"--underline-special": true, "--UNDERLINE-SPECIAL": true,
	"--version": true, "--hilite-target": true,
	"--hilite-unread": true, "--HILITE-UNREAD": true,
	"--no-init": true, "--tilde": true, "--help": true,
	"--no-keypad": true, "--old-bot": true, "--follow-name": true,
	"--use-backslash": true, "--no-histdups": true,
	"--mouse": true, "--MOUSE": true,
	"--rmouse": true, "--save-marks": true, "--incsearch": true,
	"--use-color": true, "--file-size": true, "--status-line": true,
	"--no-paste": true, "--form-feed": true, "--past-eof": true,
	"--no-edit-warn": true, "--no-warn-edit": true,
	"--no-number-headers": true, "--no-search-headers": true,
	"--no-search-header-lines": true, "--no-search-header-columns": true,
	"--redraw-on-quit": true, "--exit-follow-on-close": true, "--no-vbell": true,
	"--wordwrap": true, "--show-preproc-errors": true,
	"--proc-backspace": true, "--PROC-BACKSPACE": true,
	"--proc-tab": true, "--PROC-TAB": true,
	"--proc-return": true, "--PROC-RETURN": true,
}

// resolveLongOption returns the long option of the tables that a `--name`
// argument, with any `=value` already cut off, spells: the name itself when a
// table has it, or else the one name it is a prefix of, which is how
// getopt_long and less read an abbreviated long option. A prefix of more than
// one name, and a name no table has, resolve to "".
func resolveLongOption(name string, tables ...map[string]bool) string {
	if name == "--" || !strings.HasPrefix(name, "--") {
		return ""
	}
	for _, t := range tables {
		if t[name] {
			return name
		}
	}
	match := ""
	for _, t := range tables {
		for opt := range t {
			if !strings.HasPrefix(opt, "--") || !strings.HasPrefix(opt, name) || opt == match {
				continue
			}
			if match != "" {
				return ""
			}
			match = opt
		}
	}
	return match
}

// getoptOperands returns the arguments that are not options, skipping the
// value of each flag in valueFlags: the next token after a bare long flag or a
// short flag ending its cluster, and nothing more for `--flag=value` or a short
// value flag with the rest of its cluster attached. With boolFlags set, a long
// option is read through resolveLongOption against both tables, so an
// abbreviated value option skips its value too. With plusOptions, an argument
// starting with `+` is an option too (less's `+G`, tail's `+2`). Every argument
// after `--` is an operand.
func getoptOperands(args []string, valueFlags, boolFlags map[string]bool, plusOptions bool) []string {
	var out []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--":
			return append(out, args[i+1:]...)
		case plusOptions && strings.HasPrefix(a, "+") && a != "+":
			// an option carrying its own value; nothing to skip
		case strings.HasPrefix(a, "--"):
			if strings.Contains(a, "=") {
				break
			}
			name := a
			if boolFlags != nil {
				name = resolveLongOption(a, valueFlags, boolFlags)
			}
			if valueFlags[name] {
				i++
			}
		case strings.HasPrefix(a, "-") && a != "-":
			for j := 1; j < len(a); j++ {
				if valueFlags["-"+string(a[j])] {
					if j == len(a)-1 {
						i++
					}
					break
				}
			}
		default:
			out = append(out, a)
		}
	}
	return out
}

// dedupeOperands drops repeated operands while keeping first-seen order. A path
// named both as a bare operand and as a flag value would otherwise be contained
// twice and, on an escape, named twice in one deny message.
func dedupeOperands(operands []string) []string {
	seen := make(map[string]bool, len(operands))
	out := operands[:0:0]
	for _, o := range operands {
		if seen[o] {
			continue
		}
		seen[o] = true
		out = append(out, o)
	}
	return out
}

// pathRef is one path an argv walk extracted, tagged with the index — into the
// args slice that was walked — of the token the path came from: the VALUE token
// for a separate-token spelling (`-f FILE`), and the FLAG token itself for a
// glued or `=`-joined one (`-fFILE`, `--exclude-from=FILE`), where the path has
// no token of its own. An index of -1 means the path came from no argv token at
// all (a shell redirect the caller substituted in).
//
// The index exists so a caller can ask whether THIS path was built from a word
// the gate could not resolve statically — simpleCommand.argMeta carries per-token
// `exact` — rather than falling back to the whole-command hasUnknownExpansion
// bool, which answers only "was anything dynamic anywhere". See
// ghPathTokensDynamic (classify_gh_files.go); unshieldedDynamicArg
// (classify_command.go) is the same narrowing on the precondition.
type pathRef struct {
	path string
	arg  int
}

// pathFlagValues returns the values of the flags in pathFlags — the flags whose
// value names a filesystem path (see utilitySpec.pathValueFlags) — in every
// spelling GETOPT gives it: a separate token (`-f FILE`, `--file FILE`), a
// glued short form (`-fFILE`, `-X/etc/passwd`), an `=`-joined long form
// (`--exclude-from=FILE`), and the value-taking tail of a short cluster
// (`grep -rf FILE`). That is the whole spelling set for a program that parses
// with getopt, which is what the callers of THIS wrapper grade — the
// read-only-utility track (utilitySpec.operands) and the in-repo-write track's
// read sources (classify_inrepo_write.go). A caller whose program parses with
// pflag needs one reading more and calls pathFlagValueRefs directly; its doc
// comment below has the detail.
//
// It is the value-only view of pathFlagValueRefs, for the callers that grade a
// path without needing to know which token produced it.
func pathFlagValues(args []string, valueFlags, pathFlags map[string]bool) []string {
	refs := pathFlagValueRefs(args, valueFlags, pathFlags)
	if len(refs) == 0 {
		return nil
	}
	out := make([]string, 0, len(refs))
	for _, r := range refs {
		out = append(out, r.path)
	}
	return out
}

// pathFlagValueRefs is pathFlagValues with each value tagged by the index of the
// argv token it came from (see pathRef).
//
// valueFlags is the utility's complete value-taking flag set; pathFlags is a
// subset of it. Walking with the full set is what makes the cluster and
// separate-token cases exact: the value of a NON-path flag (`grep -e PATTERN`)
// is consumed rather than mistaken for the next flag, and inside a cluster the
// first value-taking character ends the flag run.
//
// The spellings it covers are GETOPT's, which is what its utility callers parse
// with. A caller whose program parses with pflag needs one reading more, because
// pflag takes an `=` immediately after a shorthand as the separator while getopt
// keeps it in the value: see ghPflagEqualValueRefs (classify_gh_files.go), which
// appends that reading rather than replacing this one.
func pathFlagValueRefs(args []string, valueFlags, pathFlags map[string]bool) []pathRef {
	if len(pathFlags) == 0 {
		return nil
	}
	var out []pathRef
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			// Everything after `--` is an operand; the operand walk has it.
			break
		}
		if !strings.HasPrefix(a, "-") || a == "-" {
			continue // an operand, not a flag
		}
		if strings.HasPrefix(a, "--") {
			name := a
			if eq := strings.IndexByte(a, '='); eq >= 0 {
				if pathFlags[a[:eq]] {
					out = append(out, pathRef{path: a[eq+1:], arg: i})
				}
				continue
			}
			if valueFlags[name] {
				if i+1 < len(args) {
					if pathFlags[name] {
						out = append(out, pathRef{path: args[i+1], arg: i + 1})
					}
					i++ // consume the value token either way
				}
			}
			continue
		}
		// A single-dash token: one short flag, or a bundle of them. Walk it left
		// to right; the first value-taking character consumes the REST of the
		// cluster as its value (getopt semantics), or the next token when it sits
		// at the end.
		for j := 1; j < len(a); j++ {
			f := "-" + string(a[j])
			if !valueFlags[f] {
				continue // a bool flag; keep walking the cluster
			}
			if j+1 < len(a) {
				if pathFlags[f] {
					out = append(out, pathRef{path: a[j+1:], arg: i})
				}
			} else if i+1 < len(args) {
				if pathFlags[f] {
					out = append(out, pathRef{path: args[i+1], arg: i + 1})
				}
				i++ // consume the separate value token either way
			}
			break
		}
	}
	return out
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
	"cat":    {pathBearing: true, defersForm: catDefers},
	"head":   {pathBearing: true, defersForm: headTailDefers, valueFlags: headTailValueFlags},
	"tail":   {pathBearing: true, defersForm: headTailDefers, valueFlags: headTailValueFlags, plusOptions: true},
	"cut":    {pathBearing: true, defersForm: cutDefers},
	"tr":     {pathBearing: true, defersForm: trDefers},
	"comm":   {pathBearing: true, defersForm: commDefers},
	"paste":  {pathBearing: true, defersForm: pasteDefers},
	"nl":     {pathBearing: true, defersForm: nlDefers, valueFlags: nlValueFlags},
	"fold":   {pathBearing: true, defersForm: foldDefers},
	"fmt":    {pathBearing: true, defersForm: fmtDefers},
	"column": {pathBearing: true, defersForm: columnDefers},
	"rev":    {pathBearing: true, defersForm: revDefers},

	// wc's `--files0-from=LIST` names a file wc READS (and then reads every
	// path the list names), and realpath's `--relative-to`/`--relative-base`
	// name a directory it resolves against. Both are dropped by the plain
	// non-flag walk in their `=`-joined spelling, so both are declared as
	// pathValueFlags and contained in either spelling.
	"wc": {pathBearing: true, defersForm: wcDefers,
		valueFlags: wcValueFlags, pathValueFlags: wcPathValueFlags},
	"realpath": {pathBearing: true, defersForm: realpathDefers,
		valueFlags: realpathValueFlags, pathValueFlags: realpathPathValueFlags},

	// ls lists a directory to stdout and has no write mode at all — nothing to
	// guard beyond the table's standing fail-safe-on-unknown-flag convention,
	// which lsDefers supplies. It was missing from this set while `find` and
	// `grep`, both strictly more capable, were in it, so `ls <path>` deferred on
	// every path and reached no allow track: the harness scratchpad
	// carve-out could not be exercised by the one command whose whole job is
	// naming what is in a directory, which made the carve-out's own worked
	// example — an `ls` of the bundled-skills hash directory — false.
	//
	// pathBearing, like every other operand-taking member: an `ls` of a path
	// outside the repo now earns the ordinary cross-repo read deny instead of the
	// defer it used to get, exactly as `cat`/`grep`/`find`/`less` already do for
	// the same operand. That is the point of joining the track, not a side
	// effect of it.
	"ls": {pathBearing: true, defersForm: lsDefers},

	// sort writes a file with `-o`/`--output` (`sort -o f f` clobbers in place).
	// uniq's optional second path operand is an OUTPUT file (`uniq IN OUT`).
	// Both must defer when the write form is present; both also fail safe on an
	// unrecognized flag. sort additionally carries path-valued flags —
	// `--files0-from` (a list file it reads), `--random-source` (a file it
	// reads) and `-T`/`--temporary-directory` (where it spills) — which the
	// plain walk drops in their glued spelling.
	"sort": {pathBearing: true, defersForm: sortDefers,
		valueFlags: sortValueFlags, pathValueFlags: sortPathValueFlags},
	"uniq": {pathBearing: true, defersForm: uniqDefers},

	// grep never writes a file (it writes only to stdout). It is read-only
	// regardless of flags, but it still carries a fail-safe predicate so a future
	// flag is not auto-allowed — grepDefers recognizes grep's flag grammar and
	// defers on anything outside it. Its leading positional is the PATTERN, not a
	// path, so it carries an operand grammar too: an anchored pattern like
	// `grep '/etc/passwd' f` would otherwise be tested as an absolute path and
	// earn a cross-repo deny for a command that reads nothing of the sort. Its
	// `-f PATFILE` value goes the other way — grep READS that file, so it is a
	// pathValueFlag and stays contained in every spelling getopt gives it (see
	// pathFlagValues).
	"grep": {pathBearing: true, defersForm: grepDefers, operandsFn: grepFileOperands,
		valueFlags: grepValueFlags, pathValueFlags: grepPathValueFlags},

	// diff compares two inputs and writes only to stdout — no output-file flag
	// exists in its grammar, so there is no write mode to gate beyond the
	// table's standing fail-safe-on-unknown-flag convention. It is here because
	// the process-substitution idiom it anchors (`diff <(a) <(b)`) is the
	// canonical two-stream comparison, and leaving diff off the track meant that
	// line could never reach an allow no matter how the substitutions were
	// graded. Several diff flags take a FILE value (`-X`/`--exclude-from`,
	// `--from-file`, `--to-file`, `-S`/`--starting-file`); glued, those tokens
	// begin with `-` and so were dropped by the plain walk while the
	// separate-token spelling of the same command was contained. They are
	// pathValueFlags, so both spellings now earn the same verdict.
	"diff": {pathBearing: true, defersForm: diffDefers,
		valueFlags: diffValueFlags, pathValueFlags: diffPathValueFlags},

	// Pure-output, no path operands and no write mode at all: nil defersForm.
	// printf/echo/seq/true/false/yes/basename/dirname write only to stdout and
	// have no flag that could change that, so there is nothing for a predicate to
	// guard. They ALLOW on the posture invariants alone (no containment fork for
	// operands — `echo x > <scratchpad>/f` reaches its ALLOW through the graded
	// redirect check, not through this table).
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
	// sed and awk also carry an operand grammar: their leading positional is a
	// SCRIPT / PROGRAM, not a path (sed's parse, sedReadings, is shared with
	// the sed write track). What that grammar drops is the script TEXT; the
	// script FILE named by `-f`/`--file` is a file the program reads, so it is
	// put back through containment — by sedReadValues for sed, with every file
	// the script's own `r` and `R` read, and as a pathValueFlag for awk. gawk's
	// `-i`/`--include` names a source library it reads and is an awk
	// pathValueFlag too (`-i inplace` walks its value as a path too, a bare
	// relative name graded against the running cwd — awkDefers withholds the
	// ALLOW on the in-place form regardless).
	"sed": {pathBearing: true, defersForm: sedDefers, operandsFn: sedFileOperands,
		pathValuesFn: sedReadValues},
	"awk": {pathBearing: true, defersForm: awkDefers, operandsFn: awkFileOperands,
		valueFlags: awkOperandValueFlags, pathValueFlags: awkPathValueFlags},
	// jq's leading positional is a FILTER, which is the same shape of non-path
	// positional — but jqDefers deliberately does NOT fail safe on an unknown
	// flag, so an operand grammar here could silently drop a real file operand
	// out of containment instead of merely losing an allow. A jq filter is not
	// absolute-path-shaped in practice, so the containment false positive sed
	// and awk suffer does not arise; left on the plain non-flag walk. Its
	// file-taking flags (`-f`/`--from-file`, `--slurpfile`, `--rawfile`,
	// `--argfile`) need no pathValueFlags entry either: jq accepts neither a
	// glued short form nor an `=`-joined long one (jq 1.8.2 answers both
	// `-f/dev/null` and `--from-file=/dev/null` with "Unknown option"), so its
	// file values always arrive as separate non-flag tokens the plain walk
	// already contains.
	"jq":   {pathBearing: true, defersForm: jqDefers},
	"find": {pathBearing: true, defersForm: findDefers},
	// tee's operands are WRITE destinations, not read sources, and teeDefers
	// already restricts them to /dev/null (the only allowed form). It is
	// therefore NOT pathBearing: read-containment on /dev/null would wrongly
	// deny it as a cross-repo path. teeDefers is the complete gate.
	"tee": {pathBearing: false, defersForm: teeDefers},
}

// classifyReadOnlyUtility ALLOWs a curated read-only utility when its
// invocation is provably non-mutating, denies when a path it reads escapes
// containment, and defers otherwise. The caller has already confirmed prog is
// in readOnlyUtilities.
func classifyReadOnlyUtility(prog string, args []string, sc simpleCommand, ev *Event) Decision {
	spec := readOnlyUtilities[prog]

	// Everything this invocation READS, in one list: the path operands of a
	// path-bearing utility, plus the sources of any input redirect. The input
	// redirects are graded even for a utility whose OPERANDS are not paths —
	// `tee /dev/null < /etc/passwd` copies the file to stdout without ever taking
	// it as an operand, so leaving it ungraded would disclose it under an ALLOW.
	readPaths := sc.inputRedirectTargets
	if spec.pathBearing {
		readPaths = readTargets(spec.operands(args), sc)
	}

	// Containment runs before every check that can only defer — the flag
	// grammar and the redirect veto below — so an escaping read denies
	// whatever else the command carries; `cat <cross-repo> > .claude/tmp/x`
	// earns the deny `cat <cross-repo>` earns. The one containment verdict that
	// must wait is its ALLOW for an all-carve-out read set: a deferring flag or
	// a vetoed redirect withholds that ALLOW, so it is held here and delivered
	// only once both checks have passed.
	var carved Decision
	haveCarved := false
	if spec.pathBearing || len(readPaths) > 0 {
		// A command substitution / unresolved expansion in a path operand or a
		// redirect source can't be statically contained → DEFER WITH THE
		// ANALYSIS (the same posture classifyPathReader holds), not a silent
		// bare defer: the verdict is the same, but the log records why.
		if sc.hasUnknownExpansion {
			return deferJudgment("bash-read:dynamic-path", fmt.Sprintf(
				"'%s' has a path argument built from an expansion the gate cannot resolve statically, so "+
					"containment cannot be run on it.", prog))
		}
		// A preceding dynamic `cd` invalidated the running cwd: a
		// relative operand cannot be safely resolved. DEFER, the same posture
		// classifyPathReader holds via cdInvalidDefer.
		if d, hit := cdInvalidDefer(prog, sc); hit {
			return d
		}
		// Engine B containment on every path it reads: a cross-repo read, a
		// read that resolves into the primary clone from a linked worktree,
		// and a read under `.git/` each deny. A non-contained path returns
		// that deny verdict.
		if d, ok := containPathOperands(prog, readPaths, sc, ev); !ok {
			if d.Bucket != BucketAllow {
				return d
			}
			carved, haveCarved = d, true
		}
	} else if sc.hasUnknownExpansion {
		// Pure-output utility (printf/echo/seq/...) with an unresolved
		// expansion: no path to contain, but an unprovable command still may
		// not ride the allow track.
		// This is allowEligible()'s unknown-expansion half, spelled out: the
		// redirect half is the graded check below, and calling allowEligible()
		// here would re-apply the ungraded veto and undo it (`echo x >
		// <scratchpad>/f` is exactly this branch).
		return deferToPipeline()
	}

	// Conditionally-read-only utilities defer on a mutating flag or any
	// unrecognized flag (fail-safe for new mutating modes — criterion 4).
	if spec.defersForm != nil && spec.defersForm(args) {
		return deferToPipeline()
	}

	// A real-file redirect (clobber/exfiltration) disqualifies the allow track:
	// the bytes leave stdout for a file. Defer to the normal pipeline — unless
	// every destination is a session-shaped harness scratchpad, a region the
	// carve-out designates safe by construction and which `tee`/`cp` already
	// write to under an ALLOW. redirectVetoesAllow owns that grading; see why
	// the lift is exactly that narrow.
	if redirectVetoesAllow(sc, ev) {
		return deferToPipeline()
	}

	if haveCarved {
		return carved
	}
	return allow(fmt.Sprintf("%s is a provably read-only utility invocation", prog))
}

// flagScan is a reusable defersForm body for the always-read-only path-bearing
// utilities (cat/head/wc/cut/sort/uniq/...). It walks args and reports whether
// the invocation must DEFER. The fail-safe posture (criterion 4, generalized to
// the always-read-only set per a review HIGH finding) is: ALLOW only the
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

// headTailValueFlags is head's and tail's value-taking flag set.
var headTailValueFlags = map[string]bool{
	"-c": true, "--bytes": true, "-n": true, "--lines": true,
	"-s": true, "--sleep-interval": true, "--pid": true,
	"--max-unchanged-stats": true,
}

// headTailDefers: head/tail share -c/-n (value), -q/-v, and tail's -f/-F/-s/--pid/
// --retry. None writes. `-n5`/`-c10` attached forms are handled by the value-flag
// attached check. A leading `-5` (obsolete count) is treated as an unknown flag
// and defers — conservative, not wrong.
func headTailDefers(args []string) bool {
	return flagScan{
		valueFlags: headTailValueFlags,
		boolFlags: map[string]bool{
			"-q": true, "--quiet": true, "--silent": true, "-v": true, "--verbose": true,
			"-z": true, "--zero-terminated": true,
			"-f": true, "--follow": true, "-F": true, "--retry": true,
		},
		maxPathOperands: -1,
	}.defers(args)
}

// wcValueFlags is wc's value-taking flag set, and wcPathValueFlags the subset
// whose value is a path: `--files0-from=LIST` names a file wc opens and reads
// (and then reads every path the list names).
var wcValueFlags = map[string]bool{"--files0-from": true}

var wcPathValueFlags = map[string]bool{"--files0-from": true}

// wcDefers: wc has only counting flags (-c/-m/-l/-w/-L and --files0-from value).
func wcDefers(args []string) bool {
	return flagScan{
		valueFlags: wcValueFlags,
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

// nlValueFlags is nl's value-taking flag set.
var nlValueFlags = map[string]bool{
	"-b": true, "--body-numbering": true, "-d": true, "--section-delimiter": true,
	"-f": true, "--footer-numbering": true, "-h": true, "--header-numbering": true,
	"-i": true, "--line-increment": true, "-l": true, "--join-blank-lines": true,
	"-n": true, "--number-format": true, "-s": true, "--number-separator": true,
	"-v": true, "--starting-line-number": true, "-w": true, "--number-width": true,
}

// nlDefers: nl numbers lines to stdout. Many value flags (-b/-d/-f/-h/-i/-l/-n/
// -s/-v/-w); none writes a file.
func nlDefers(args []string) bool {
	return flagScan{
		valueFlags:      nlValueFlags,
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

// lsDefers: ls lists directory entries on stdout and has no write mode in any
// implementation, so there is no write flag to enumerate — the predicate exists
// purely for the table's fail-safe convention (an unrecognized flag defers).
//
// Only flags that are BOOL in both GNU coreutils and BSD/macOS ls are listed.
// The short flags whose meaning DIVERGES — GNU's `-I PATTERN`, `-T COLS` and
// `-w COLS` take a value while BSD's `-I`/`-T` are bools — are deliberately left
// unmodelled, so they hit the unknown-flag arm and defer.
//
// What that choice does NOT do is hold a containment hole shut. For `ls` the
// flag model decides allow-ELIGIBILITY only; it has no say in which tokens are
// contained. pathOperands does that, and it keeps every token that does not
// begin with `-` without ever consulting this model — so `ls -I /etc` yields
// the operand `/etc` either way. (A program that declares pathValueFlags does
// feed flag values into containment, but only by ADDING them; `ls` declares
// none, since no ls flag takes a path value.) The outcomes are:
//
//	unmodelled          → unknown flag → this predicate defers → DEFER
//	modelled as a value → allow-eligible → containment runs    → DENY
//
// Modelling them would therefore be STRICTER than leaving them out, not laxer.
// They stay out because a model must not assert an arity that is wrong on one of
// the two platforms: as value flags this predicate would misread the BSD form
// `ls -I .` (consuming `.` as a pattern), and as bools it would misread the GNU
// form `ls -w 80 .` (treating the column count `80` as a path). A defer costs a
// prompt on a rare form, which is cheaper than either mismodel — and it is the
// same fail-safe-on-unknown-flag convention the rest of this table follows.
//
// The GNU long forms of those same options are unambiguous (long flags do not
// exist in BSD ls), so they ARE modelled as value flags. `--color`/`--colour`
// are bools instead, because their value is optional (`ls --color` is legal and
// means `=always`), so consuming the following token would misread the path
// operand in `ls --color .` as the flag's value.
func lsDefers(args []string) bool {
	return flagScan{
		valueFlags: map[string]bool{
			"--block-size": true, "--format": true, "--time": true,
			"--time-style": true, "--sort": true, "--indicator-style": true,
			"--quoting-style": true, "--ignore": true, "--hide": true,
			"--width": true, "--tabsize": true,
		},
		boolFlags: map[string]bool{
			"-a": true, "--all": true, "-A": true, "--almost-all": true,
			"-b": true, "--escape": true, "-B": true, "--ignore-backups": true,
			"-c": true, "-C": true, "-d": true, "--directory": true,
			"-D": true, "--dired": true, "-f": true, "-F": true, "--classify": true,
			"--file-type": true, "-g": true, "-G": true, "--no-group": true,
			"-h": true, "--human-readable": true, "--si": true,
			"-H": true, "--dereference-command-line": true,
			"--dereference-command-line-symlink-to-dir": true,
			"-i": true, "--inode": true, "-k": true, "--kibibytes": true,
			"-l": true, "-L": true, "--dereference": true, "-m": true,
			"-n": true, "--numeric-uid-gid": true, "-N": true, "--literal": true,
			"-o": true, "-p": true, "-q": true, "--hide-control-chars": true,
			"--show-control-chars": true, "-Q": true, "--quote-name": true,
			"-r": true, "--reverse": true, "-R": true, "--recursive": true,
			"-s": true, "--size": true, "-S": true, "-t": true,
			"-u": true, "-U": true, "-v": true, "-x": true, "-X": true,
			"-Z": true, "--context": true, "-1": true,
			"--author": true, "--full-time": true, "--group-directories-first": true,
			"--color": true, "--colour": true, "--zero": true,
			// BSD/macOS-only bools.
			"-@": true, "-e": true, "-O": true, "-P": true, "-W": true,
		},
		maxPathOperands: -1, // every operand is a directory/file to list
		// clusterable: `ls -la`, `ls -lrt` are the overwhelmingly common forms.
		// ls has no write flag, and none of the modelled short flags takes a
		// value, so a cluster ALLOWs only when every character is a known bool —
		// `ls -lT` defers on the unmodelled `T`.
		clusterable: true,
	}.defers(args)
}

// realpathValueFlags is realpath's value-taking flag set, and
// realpathPathValueFlags the subset whose value is a path: both
// `--relative-to` and `--relative-base` name a DIRECTORY realpath resolves the
// operand against. realpath does not read its contents, but it is a filesystem
// path the command reaches for, and the separate-token spelling has always been
// contained — declaring it keeps the glued spelling from earning a laxer
// verdict than the spaced one.
var realpathValueFlags = map[string]bool{"--relative-to": true, "--relative-base": true}

var realpathPathValueFlags = map[string]bool{"--relative-to": true, "--relative-base": true}

// realpathDefers: realpath resolves paths to stdout; no write flag. -e/-m/-s/-z/-q
// and the value flag --relative-to / --relative-base.
func realpathDefers(args []string) bool {
	return flagScan{
		valueFlags: realpathValueFlags,
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
		valueFlags: grepValueFlags,
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

// sortValueFlags is sort's value-taking flag set (its write flag `-o` is graded
// separately, by writeFlags), and sortPathValueFlags the subset whose value is a
// path: `--files0-from` and `--random-source` name files sort READS, and
// `-T`/`--temporary-directory` the directory it SPILLS its temporary runs into.
var sortValueFlags = map[string]bool{
	"-k": true, "--key": true, "-t": true, "--field-separator": true,
	"-S": true, "--buffer-size": true, "-T": true, "--temporary-directory": true,
	"--batch-size": true, "--compress-program": true, "--files0-from": true,
	"--random-source": true, "--parallel": true, "--sort": true,
}

var sortPathValueFlags = map[string]bool{
	"-T": true, "--temporary-directory": true,
	"--files0-from": true, "--random-source": true,
}

// sortDefers: sort writes a file with `-o FILE` / `--output=FILE`
// (`sort -o f f` clobbers f in place). That write form must defer (a review
// HIGH). All other sort flags are read-only; an unrecognized flag fails safe.
func sortDefers(args []string) bool {
	return flagScan{
		writeFlags: map[string]bool{"-o": true, "--output": true},
		valueFlags: sortValueFlags,
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
// most ONE path operand is read-only; a second defers (a review HIGH finding). uniq
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

// sedValueFlags, sedBoolFlags and sedArityFlags are sed's whole option table:
// the union of GNU sed's (its getopt_long table, so a long option may be
// abbreviated to any unique prefix) and BSD and macOS sed's (getopt
// "EHI:ae:f:i:lnru"; FreeBSD's lacks H, and neither has a long option).
// sedValueFlags take a value, in the same argument or the next: `-e` the script
// itself and `-f` a file sed reads it from. sedBoolFlags take none.
// sedArityFlags are the two options whose value the two seds read differently:
//
//   - the in-place option. GNU's `-i` and `--in-place` take a suffix only in
//     the same argument; BSD's `-i` and `-I` take one in the same argument or
//     the next. GNU has no `-I`, so the argument after a bare `-I` is its
//     suffix. The argument after a bare `-i` has two readings, BSD's suffix and
//     GNU's script or file, and sedReadings returns both.
//   - the line length. GNU's `-l` and `--line-length` take a value, the rest of
//     the argument or the next one, and accept any text as it; BSD's `-l`
//     takes nothing, so the rest of its argument is more options and the next
//     argument is the script or a file. sedReadings returns both readings.
var sedValueFlags = map[string]bool{
	"-e": true, "--expression": true,
	"-f": true, "--file": true,
}

var sedBoolFlags = map[string]bool{
	"-n": true, "--quiet": true, "--silent": true,
	"-E": true, "-r": true, "--regexp-extended": true,
	"-z": true, "--null-data": true, "--zero-terminated": true,
	"-s": true, "--separate": true,
	"-u": true, "--unbuffered": true,
	"-b": true, "--binary": true,
	"-a": true, "-H": true,
	"--posix": true, "--debug": true, "--sandbox": true,
	"--follow-symlinks": true, "--help": true, "--version": true,
}

var sedArityFlags = map[string]bool{
	"-i": true, "-I": true, "--in-place": true,
	"-l": true, "--line-length": true,
}

// sedLongOption is the sed long option a `--name` argument, with any `=value`
// cut off, spells (resolveLongOption), or "" when it spells none.
func sedLongOption(name string) string {
	return resolveLongOption(name, sedValueFlags, sedBoolFlags, sedArityFlags)
}

// sedSuffix is an in-place backup suffix and the seds that take it as one.
type sedSuffix struct {
	text     string
	gnu, bsd bool
}

// sedInvocation is one reading of a sed argv against sed's option table.
type sedInvocation struct {
	// quiet: -n, --quiet or --silent is present.
	quiet bool
	// inPlace: the in-place option is present.
	inPlace bool
	// suffixes are the in-place option's backup suffixes.
	suffixes []sedSuffix
	// forked: this reading is BSD's, forked off where it reads an option
	// differently from GNU's (sedReadings).
	forked bool
	// bareSuffix: this reading took the argument after a bare `-i` as its
	// suffix, as BSD sed does, where GNU sed takes it as the script or a file.
	// bareText is that argument.
	bareSuffix bool
	bareText   string
	// followSymlinks: --follow-symlinks is present, so GNU sed edits the file a
	// symlink operand ends at, under the name sedFollowSymlink gives it.
	followSymlinks bool
	// scriptByFlag: -e or -f supplied the script, so no positional is one.
	scriptByFlag bool
	// scripts are the values of -e and --expression, in order.
	scripts []string
	// scriptFiles are the values of -f and --file, files sed reads.
	scriptFiles []string
	// unknown: an option outside the table, which makes sed exit with a usage
	// error before it reads or writes anything.
	unknown bool
	// positional are the arguments that are neither an option nor an option's
	// value, in order: the script first unless scriptByFlag, then the files.
	positional []string
}

// clone returns a copy of p that shares no slice with it.
func (p sedInvocation) clone() sedInvocation {
	q := p
	q.suffixes = append([]sedSuffix(nil), p.suffixes...)
	q.scripts = append([]string(nil), p.scripts...)
	q.scriptFiles = append([]string(nil), p.scriptFiles...)
	q.positional = append([]string(nil), p.positional...)
	return q
}

// fork returns a copy of p, as a reading forked off it (clone).
func (p sedInvocation) fork() sedInvocation {
	q := p.clone()
	q.forked = true
	return q
}

// runs reports whether sed runs this reading at all: it carries no unknown
// option, it does not edit in place with no file to edit, which both seds
// refuse, and its script, when it has one, is not one both seds reject
// (sedScriptRejected). A reading that does not run reads and edits no file.
func (p sedInvocation) runs() bool {
	if p.unknown || p.inPlace && len(p.files()) == 0 {
		return false
	}
	script, ok := p.script()
	return !ok || !sedScriptRejected(script)
}

// counts reports whether this reading's files are among the invocation's: a
// reading GNU sed's option parse yields always counts, so a mistake in the
// script walk never drops a file from containment, and a forked one counts
// when sed runs it (runs).
func (p sedInvocation) counts() bool {
	return !p.forked || p.runs()
}

// files are the files this reading reads, or edits in place: the positional
// arguments after the script.
func (p sedInvocation) files() []string {
	if p.scriptByFlag {
		return p.positional
	}
	if len(p.positional) <= 1 {
		return nil
	}
	return p.positional[1:]
}

// script is the script text this reading gives sed on its command line, and
// false when it gives none. A -f script is a file's content and is not in it.
func (p sedInvocation) script() (string, bool) {
	if p.scriptByFlag {
		return strings.Join(p.scripts, "\n"), len(p.scripts) > 0
	}
	if len(p.positional) == 0 {
		return "", false
	}
	return p.positional[0], true
}

// edited is the name GNU sed edits the file operand f under in this reading:
// f as spelled, or under --follow-symlinks the name followed maps f to
// (sedFollowedNames).
func (p sedInvocation) edited(f string, followed map[string]string) string {
	if n, ok := followed[f]; ok && p.followSymlinks {
		return n
	}
	return f
}

// backups are the backup files this reading's in-place edit writes, with
// followed as for edited. BSD sed appends the suffix to each file's name. GNU
// sed puts the name it edits the file under (edited), directory included, in
// place of each `*` in the suffix, which a suffix without one gets in front of
// it, and makes no backup for a suffix of `*` alone (open_next_file, closedown
// and get_backup_file_name, sed/execute.c).
func (p sedInvocation) backups(followed map[string]string) []string {
	var out []string
	for _, f := range p.files() {
		for _, s := range p.suffixes {
			if s.bsd && s.text != "" {
				out = append(out, f+s.text)
			}
			if !s.gnu {
				continue
			}
			ext := s.text
			if !strings.Contains(ext, "*") {
				ext = "*" + ext
			}
			if ext != "*" {
				out = append(out, strings.ReplaceAll(ext, "*", p.edited(f, followed)))
			}
		}
	}
	return out
}

// sedMaxLinks bounds how many symlinks sedFollowSymlink follows from one file
// operand before it gives up.
const sedMaxLinks = 40

// sedFollowSymlink returns the name GNU sed's --follow-symlinks edits the file
// operand name under, reading links relative to base, the directory sed runs
// in: while the name is a symlink, the link text, behind the name's own
// directory as the name spells it when the text is relative and the name has
// one (follow_symlink, sed/utils.c). It returns false when a link cannot be
// read, which includes a name that does not exist, or the chain is longer
// than sedMaxLinks.
func sedFollowSymlink(name, base string) (string, bool) {
	fn := name
	for n := 0; ; n++ {
		at := fn
		if !strings.HasPrefix(at, "/") {
			at = base + "/" + at
		}
		link, err := os.Readlink(at)
		if errors.Is(err, syscall.EINVAL) {
			return fn, true
		}
		if err != nil || n >= sedMaxLinks {
			return "", false
		}
		if k := strings.LastIndex(fn, "/"); !strings.HasPrefix(link, "/") && k >= 0 {
			link = fn[:k+1] + link
		}
		fn = link
	}
}

// sedFollowedNames maps each file a reading that counts (counts) edits in
// place under --follow-symlinks to the name sedFollowSymlink gives it, from
// base. It reports false when one of them cannot be followed; the map then
// holds the rest.
func sedFollowedNames(readings []sedInvocation, base string) (map[string]string, bool) {
	followed := map[string]string{}
	ok := true
	for _, p := range readings {
		if !p.followSymlinks || !p.inPlace || !p.counts() {
			continue
		}
		for _, f := range p.files() {
			if _, done := followed[f]; done {
				continue
			}
			n, found := sedFollowSymlink(f, base)
			if !found {
				ok = false
				continue
			}
			followed[f] = n
		}
	}
	return followed, ok
}

// sedMaxForks bounds how many readings sedReadings forks off an argument it
// reads two ways, counted across every reading rather than per argument. An
// argv that needs more is read as one with an unknown option.
const sedMaxForks = 8

// sedPending is a reading sedReadings has yet to finish: p as read so far, to
// resume at argument i — at byte j of it when j is above zero, inside a
// short-option cluster — taking options wherever they stand when permute is
// set.
type sedPending struct {
	p       sedInvocation
	i, j    int
	permute bool
}

// sedReadings reads a sed argv against sed's option table, every way GNU and
// BSD sed read it, up to a `--`:
//
//   - GNU sed's reading takes an option wherever it stands.
//   - BSD sed's getopt, and GNU sed's with POSIXLY_CORRECT set, stop taking
//     options at the first argument that is not one, so every argument from
//     there on is the script or a file. That reading forks at the two short
//     options whose value the seds read differently: it goes on as GNU's, and
//     the fork goes on as BSD's — a bare `-i` ending a cluster, with an
//     argument after it, taking that argument as its suffix, and `-l` taking
//     no value.
//
// GNU's reading is first.
func sedReadings(args []string) []sedInvocation {
	var out []sedInvocation
	work := []sedPending{{permute: true}, {}}
	forks := 0
	for len(work) > 0 {
		p, i, j, permute := work[0].p, work[0].i, work[0].j, work[0].permute
		work = work[1:]
	reading:
		for ; i < len(args); i, j = i+1, 0 {
			a := args[i]
			var fork *sedPending
			switch {
			case j > 0:
				i, fork = p.shortCluster(args, i, j, permute)
			case a == "--":
				p.positional = append(p.positional, args[i+1:]...)
				break reading
			case (!strings.HasPrefix(a, "-") || a == "-") && !permute:
				p.positional = append(p.positional, args[i:]...)
				break reading
			case !strings.HasPrefix(a, "-") || a == "-":
				p.positional = append(p.positional, a)
			case strings.HasPrefix(a, "--"):
				i = p.longOption(args, i)
			default:
				i, fork = p.shortCluster(args, i, 1, permute)
			}
			if fork == nil {
				continue
			}
			if forks++; forks > sedMaxForks {
				return []sedInvocation{{inPlace: true, unknown: true}}
			}
			work = append(work, *fork)
		}
		out = append(out, p)
	}
	return out
}

// longOption reads the long option args[i] and returns the index of the last
// argument it used.
func (p *sedInvocation) longOption(args []string, i int) int {
	name, value, attached := strings.Cut(args[i], "=")
	switch opt := sedLongOption(name); {
	case opt == "":
		p.unknown = true
	case sedValueFlags[opt]:
		p.scriptByFlag = true
		if !attached {
			if i+1 >= len(args) {
				return i
			}
			i++
			value = args[i]
		}
		if opt == "--file" {
			p.scriptFiles = append(p.scriptFiles, value)
		} else {
			p.scripts = append(p.scripts, value)
		}
	case opt == "--line-length":
		if !attached && i+1 < len(args) {
			i++
		}
	case opt == "--in-place":
		p.inPlace = true
		if attached {
			p.suffixes = append(p.suffixes, sedSuffix{text: value, gnu: true})
		}
	case attached:
		p.unknown = true
	case opt == "--quiet" || opt == "--silent":
		p.quiet = true
	case opt == "--follow-symlinks":
		p.followSymlinks = true
	}
	return i
}

// shortCluster reads the short-option cluster args[i] from its byte j0 and
// returns the index of the last argument it used. Outside a permute reading,
// where the two seds read an option of the cluster differently, it reads it as
// GNU does and returns BSD's reading as fork, else nil.
func (p *sedInvocation) shortCluster(args []string, i, j0 int, permute bool) (next int, fork *sedPending) {
	a := args[i]
	for j := j0; j < len(a); j++ {
		c, rest := a[j], a[j+1:]
		switch {
		case c == 'e' || c == 'f':
			p.scriptByFlag = true
			value := rest
			if rest == "" {
				if i+1 >= len(args) {
					return i, nil
				}
				i++
				value = args[i]
			}
			if c == 'f' {
				p.scriptFiles = append(p.scriptFiles, value)
			} else {
				p.scripts = append(p.scripts, value)
			}
			return i, nil
		case c == 'i' || c == 'I':
			p.inPlace = true
			switch {
			case rest != "":
				p.suffixes = append(p.suffixes, sedSuffix{text: rest, gnu: c == 'i', bsd: true})
			case i+1 >= len(args):
			case c == 'I':
				p.suffixes = append(p.suffixes, sedSuffix{text: args[i+1], bsd: true})
				return i + 1, nil
			case !permute:
				q := p.fork()
				q.suffixes = append(q.suffixes, sedSuffix{text: args[i+1], bsd: true})
				q.bareSuffix, q.bareText = true, args[i+1]
				return i, &sedPending{p: q, i: i + 2}
			}
			return i, nil
		case c == 'l':
			if !permute && (rest != "" || i+1 < len(args)) {
				fork = &sedPending{p: p.fork(), i: i, j: j + 1}
				if rest == "" {
					fork.i, fork.j = i+1, 0
				}
			}
			if rest == "" && i+1 < len(args) {
				i++
			}
			return i, fork
		case c == 'n':
			p.quiet = true
		case !sedBoolFlags["-"+string(c)]:
			p.unknown = true
			return i, nil
		}
	}
	return i, nil
}

// sedUnknown reports whether a reading of a sed argv other than a forked one
// carries an option outside sed's table. A forked reading is BSD's, whose
// options the table holds whole, so an unknown option there is one BSD sed
// rejects rather than one the table lacks.
func sedUnknown(readings []sedInvocation) bool {
	for _, p := range readings {
		if p.unknown && !p.forked {
			return true
		}
	}
	return false
}

// sedFileOperands returns the files a sed invocation reads, or edits in place,
// in any reading that counts (counts): the positional arguments after the
// script. An invocation that names no file returns none. One that carries an
// option outside sed's table returns the files its readings name with that
// option read as taking no value, so containment still denies an escape among
// them before sedDefers defers the invocation.
func sedFileOperands(args []string) []string {
	readings := sedReadings(args)
	var out []string
	for _, p := range readings {
		if p.counts() {
			out = append(out, p.files()...)
		}
	}
	return dedupeOperands(out)
}

// sedScriptFiles returns the files a sed invocation reads its script from, in
// any reading.
func sedScriptFiles(args []string) []string {
	var out []string
	for _, p := range sedReadings(args) {
		out = append(out, p.scriptFiles...)
	}
	return dedupeOperands(out)
}

// sedQuiet reports whether a sed invocation carries -n, --quiet or --silent
// in any reading.
func sedQuiet(args []string) bool {
	for _, p := range sedReadings(args) {
		if p.quiet {
			return true
		}
	}
	return false
}

// sedInPlace reports whether a sed invocation edits a file in place in any
// reading. It is the one sed in-place rule; the read-only-utility track, the
// in-repo-write track and the file-work redirect all decide on it.
func sedInPlace(args []string) bool {
	for _, p := range sedReadings(args) {
		if p.inPlace {
			return true
		}
	}
	return false
}

// sedCommandFileSets returns the files the script on a sed invocation's
// command line names in its own commands, in any reading of the argv but a
// forked one BSD sed rejects for an unknown option, and either sed's reading of
// the script (sedCommandFiles): the files it reads, and the files it writes.
func sedCommandFileSets(args []string) (reads, writes []string) {
	for _, p := range sedReadings(args) {
		script, ok := p.script()
		if !ok || p.unknown && p.forked {
			continue
		}
		for _, brackets := range []bool{false, true} {
			r, w := sedCommandFiles(script, brackets)
			reads = append(reads, r...)
			writes = append(writes, w...)
		}
	}
	return dedupeOperands(reads), dedupeOperands(writes)
}

// sedWrites reports whether a sed invocation writes a file: it edits in place,
// or its script writes one.
func sedWrites(args []string) bool {
	if sedInPlace(args) {
		return true
	}
	_, writes := sedCommandFileSets(args)
	return len(writes) > 0
}

// sedReadValues returns the files a sed invocation reads other than its file
// operands: its script files, and the files its script reads.
func sedReadValues(args []string) []string {
	reads, _ := sedCommandFileSets(args)
	return dedupeOperands(append(sedScriptFiles(args), reads...))
}

// sedWriteTargets returns the files a writing sed invocation that runs in base
// writes, in any reading: the files it edits in place, under each name it
// edits them under (edited), and their backups, and the files its script
// writes. An invocation that carries an option outside sed's table returns
// them as sedFileOperands does, and the in-repo-write track defers it once
// containment passes (sedWriteDefers). It reports false when a file it edits
// under --follow-symlinks cannot be followed (sedFollowedNames); the files
// returned then lack that file's followed name and its backups.
func sedWriteTargets(args []string, base string) ([]string, bool) {
	readings := sedReadings(args)
	followed, ok := sedFollowedNames(readings, base)
	var out []string
	for _, p := range readings {
		out = append(out, p.writeTargets(followed)...)
	}
	return dedupeOperands(out), ok
}

// writeTargets are the files this reading writes, with followed as for
// edited: the files it edits in place, as spelled and as edited, and their
// backups, when the reading counts (counts), and the files its script writes
// in either reading of the script (sedCommandFiles), which sed opens as it
// compiles the script, before it rejects anything after them.
func (p sedInvocation) writeTargets(followed map[string]string) []string {
	if p.unknown && p.forked {
		return nil
	}
	var out []string
	if p.inPlace && p.counts() {
		for _, f := range p.files() {
			out = append(out, f)
			if e := p.edited(f, followed); e != f {
				out = append(out, e)
			}
		}
		out = append(out, p.backups(followed)...)
	}
	if script, ok := p.script(); ok {
		for _, brackets := range []bool{false, true} {
			_, w := sedCommandFiles(script, brackets)
			out = append(out, w...)
		}
	}
	return out
}

// sedGNUBareInPlaceTargets returns the files a sed invocation writes only in
// GNU's reading of a bare `-i`: with an argument after the `-i`, which BSD sed
// takes as the suffix, GNU sed takes it as the script, so the argument BSD
// takes as the script is a file GNU edits. It also returns the argument BSD
// sed takes as the suffix. It returns no file when no reading sed runs (runs)
// takes such an argument as the suffix, or the invocation carries an option
// outside sed's table. base is as for sedWriteTargets.
func sedGNUBareInPlaceTargets(args []string, base string) (files []string, suffix string) {
	readings := sedReadings(args)
	if sedUnknown(readings) {
		return nil, ""
	}
	followed, _ := sedFollowedNames(readings, base)
	bsd := map[string]bool{}
	forked := false
	for _, p := range readings {
		if p.bareSuffix && p.runs() {
			if !forked {
				suffix = p.bareText
			}
			forked = true
			for _, f := range p.writeTargets(followed) {
				bsd[f] = true
			}
		}
	}
	if !forked {
		return nil, ""
	}
	all, _ := sedWriteTargets(args, base)
	for _, f := range all {
		if !bsd[f] {
			files = append(files, f)
		}
	}
	return files, suffix
}

// sedWriteReadSources returns the files a writing sed invocation reads and does
// not write: sedReadValues', and its file operands when it does not edit them
// in place.
func sedWriteReadSources(args []string) []string {
	out := sedReadValues(args)
	if !sedInPlace(args) {
		out = append(out, sedFileOperands(args)...)
	}
	return dedupeOperands(out)
}

// sedDefers reports whether a sed invocation must defer rather than allow:
// when it writes a file (sedWrites), runs a script the gate cannot grade whole
// (sedOpaque), or carries an option outside sed's table, so a mutating option
// the table does not know fails safe.
func sedDefers(args []string) bool {
	return sedWrites(args) || sedOpaque(args) || sedUnknown(sedReadings(args))
}

// sedOpaque reports whether a sed invocation, in any reading of its argv and
// either reading of its script, runs a script the gate cannot grade whole: one
// it reads from a file (-f, --file), whose commands the gate never sees, or one
// sedScriptOpaque reports. No track allows it. The file-work redirect does not
// consult it, and grades an opaque sed as it grades any other.
func sedOpaque(args []string) bool {
	for _, p := range sedReadings(args) {
		if p.unknown && p.forked {
			continue
		}
		if len(p.scriptFiles) > 0 {
			return true
		}
		script, ok := p.script()
		if !ok {
			continue
		}
		for _, brackets := range []bool{false, true} {
			if sedScriptOpaque(script, brackets) {
				return true
			}
		}
	}
	return false
}

// sedCommandFiles returns the files a sed script names in its own commands:
// those `r` and `R` read, and those `w`, `W` and the `w` flag of `s` write.
// `/dev/stdin`, `/dev/stdout` and `/dev/stderr` name sed's own streams, not a
// file. Where the two seds compile a script differently, the walk reads it the
// way that reaches every command either compiles: a label ends at a blank, `;`,
// `}` or `#`, as GNU ends one where BSD reads to the end of the line, and the
// next command may follow it directly, as GNU reads one; and a command only one
// sed has is read rather than rejected. The one exception is a bracket
// expression in a regular expression, inside which BSD sed takes the delimiter
// literally and GNU sed ends the expression at it; brackets selects BSD's
// reading. A command the script spells wrong ends the walk, as it ends sed's
// compile; the files named before it are kept, since sed opens a `w` file as it
// compiles the command.
func sedCommandFiles(script string, brackets bool) (reads, writes []string) {
	w := walkSedScript(script, brackets)
	return w.reads, w.writes
}

// sedScriptOpaque reports whether the gate cannot grade a sed script whole: it
// runs a shell command, through its `e` command or the `e` flag of an `s`
// command, or its walk stopped at something other than a missing command — the
// one place both seds are known to reject a script — and so may have missed
// commands after it. The walk is sedCommandFiles'.
func sedScriptOpaque(script string, brackets bool) bool {
	w := walkSedScript(script, brackets)
	return w.executes || w.unread
}

// sedScriptRejected reports whether both seds reject a sed script: its walk,
// in either reading of a bracket expression, stops at a missing command.
func sedScriptRejected(script string) bool {
	for _, brackets := range []bool{false, true} {
		if !walkSedScript(script, brackets).noCommand {
			return false
		}
	}
	return true
}

// walkSedScript walks script, with brackets as for sedCommandFiles, and
// returns the finished walk.
func walkSedScript(script string, brackets bool) *sedScriptWalker {
	w := &sedScriptWalker{s: script, brackets: brackets}
	w.walk()
	return w
}

// sedScriptWalker walks a sed script command by command.
type sedScriptWalker struct {
	s             string
	i             int
	brackets      bool
	reads, writes []string
	// executes: an `e` command or an `s` command's `e` flag was read.
	executes bool
	// noCommand: the walk stopped where a command is due and none of either
	// sed's stands — another byte, or the end of the script — which both seds
	// reject.
	noCommand bool
	// unread: the walk stopped anywhere else, where the rest of the script is
	// something the walk cannot read.
	unread bool
}

// peek is the byte at the walk's position, or 0 at the end of the script.
func (w *sedScriptWalker) peek() byte {
	if w.i < len(w.s) {
		return w.s[w.i]
	}
	return 0
}

// skipBlanks moves past spaces and tabs.
func (w *sedScriptWalker) skipBlanks() {
	for w.peek() == ' ' || w.peek() == '\t' {
		w.i++
	}
}

// skipDigits moves past a run of decimal digits.
func (w *sedScriptWalker) skipDigits() {
	for c := w.peek(); c >= '0' && c <= '9'; c = w.peek() {
		w.i++
	}
}

// toEOL returns the text up to the next newline and moves past the newline.
func (w *sedScriptWalker) toEOL() string {
	rest := w.s[w.i:]
	line, _, found := strings.Cut(rest, "\n")
	w.i += len(line)
	if found {
		w.i++
	}
	return line
}

// filename reads a command's filename: blanks skipped, then the rest of the
// line.
func (w *sedScriptWalker) filename() string {
	w.skipBlanks()
	return w.toEOL()
}

// walk reads commands until the script ends or one is spelled wrong, and sets
// unread when it stops anywhere but the end or a missing command.
func (w *sedScriptWalker) walk() {
	if !w.commands() {
		w.unread = !w.noCommand
	}
}

// commands reads commands until the script ends, and reports false when one is
// spelled wrong.
func (w *sedScriptWalker) commands() bool {
	for {
		for w.i < len(w.s) && strings.IndexByte(" \t\n;", w.s[w.i]) >= 0 {
			w.i++
		}
		if w.i >= len(w.s) {
			return true
		}
		if !w.address(false) {
			return false
		}
		w.skipBlanks()
		if w.peek() == ',' {
			w.i++
			w.skipBlanks()
			if !w.address(true) {
				return false
			}
			w.skipBlanks()
		}
		for w.peek() == '!' {
			w.i++
			w.skipBlanks()
		}
		if !w.command() {
			return false
		}
	}
}

// address reads one address, and reports false when it is spelled wrong or,
// with required set, absent.
func (w *sedScriptWalker) address(required bool) bool {
	switch c := w.peek(); {
	case c >= '0' && c <= '9':
		w.skipDigits()
		if w.peek() == '~' {
			w.i++
			w.skipDigits()
		}
		return true
	case c == '$':
		w.i++
		return true
	case c == '+' || c == '~':
		w.i++
		w.skipDigits()
		return true
	case c == '/':
		w.i++
		return w.regexAddress('/')
	case c == '\\':
		w.i++
		d := w.peek()
		if d == 0 || d == '\n' || d == '\\' {
			return false
		}
		w.i++
		return w.regexAddress(d)
	}
	return !required
}

// regexAddress reads a regular expression address after its opening
// delimiter d, and its I and M flags.
func (w *sedScriptWalker) regexAddress(d byte) bool {
	if !w.delimited(d, true) {
		return false
	}
	for w.peek() == 'I' || w.peek() == 'M' {
		w.i++
	}
	return true
}

// delimited reads up to and past the delimiter d. A backslash escapes the byte
// after it, a newline included. In a regular expression read with brackets
// set, a bracket expression is read whole. A bare newline, or the end of the
// script, is an error.
func (w *sedScriptWalker) delimited(d byte, regex bool) bool {
	for w.i < len(w.s) {
		switch c := w.s[w.i]; {
		case c == '\\':
			w.i += 2
		case c == '\n':
			return false
		case c == d:
			w.i++
			return true
		case c == '[' && regex && w.brackets:
			if !w.bracket() {
				return false
			}
		default:
			w.i++
		}
	}
	return false
}

// bracket reads a bracket expression from its `[` to its closing `]`, as BSD
// sed reads one: a `]` first, after any `^`, is a member, and `[:`, `[.` and
// `[=` open a class that runs to its own closing `:]`, `.]` or `=]`.
func (w *sedScriptWalker) bracket() bool {
	w.i++
	if w.peek() == '^' {
		w.i++
	}
	if w.peek() == ']' {
		w.i++
	}
	for w.i < len(w.s) {
		c := w.s[w.i]
		switch {
		case c == ']':
			w.i++
			return true
		case c == '\n':
			return false
		case c == '[' && w.i+1 < len(w.s) && strings.IndexByte(":.=", w.s[w.i+1]) >= 0:
			end := strings.Index(w.s[w.i+2:], string(w.s[w.i+1])+"]")
			if end < 0 {
				return false
			}
			w.i += 2 + end + 2
		default:
			w.i++
		}
	}
	return false
}

// command reads one command after its addresses, and reports false when it is
// spelled wrong.
func (w *sedScriptWalker) command() bool {
	if w.i >= len(w.s) {
		w.noCommand = true
		return false
	}
	c := w.s[w.i]
	w.i++
	switch c {
	case '{':
		return true
	case '}':
		return w.endOfCommand()
	case '#':
		w.toEOL()
		return true
	case 'e':
		w.executes = true
		w.toEOL()
		return true
	case 'a', 'i', 'c':
		w.text()
		return true
	case 'r', 'R':
		if name := w.filename(); name != "" && name != "/dev/stdin" {
			w.reads = append(w.reads, name)
		}
		return true
	case 'w', 'W':
		w.write(w.filename())
		return true
	case 's':
		return w.substitute()
	case 'y':
		d := w.peek()
		if d == 0 || d == '\n' || d == '\\' {
			return false
		}
		w.i++
		return w.delimited(d, false) && w.delimited(d, false) && w.endOfCommand()
	case ':', 'b', 't', 'T', 'v':
		// GNU sed reads the next command straight after the label, with no
		// `;` or newline between them.
		w.skipBlanks()
		for w.i < len(w.s) && strings.IndexByte(" \t\n;}#", w.s[w.i]) < 0 {
			w.i++
		}
		return true
	case 'l', 'L', 'q', 'Q':
		w.skipBlanks()
		w.skipDigits()
		return w.endOfCommand()
	case '=', 'd', 'D', 'g', 'G', 'h', 'H', 'n', 'N', 'p', 'P', 'x', 'z', 'F':
		return w.endOfCommand()
	}
	w.noCommand = true
	return false
}

// write records a file a command writes.
func (w *sedScriptWalker) write(name string) {
	if name != "" && name != "/dev/stdout" && name != "/dev/stderr" {
		w.writes = append(w.writes, name)
	}
}

// text reads the text of an `a`, `i` or `c` command: after an optional
// backslash and newline, every line up to one that does not end in an escaping
// backslash.
func (w *sedScriptWalker) text() {
	w.skipBlanks()
	if w.peek() == '\\' {
		w.i++
		if w.peek() == '\n' {
			w.i++
		}
	}
	for w.i < len(w.s) {
		line := w.toEOL()
		trailing := len(line) - len(strings.TrimRight(line, "\\"))
		if trailing%2 == 0 {
			return
		}
	}
}

// substitute reads an `s` command after the `s`: its regular expression, its
// replacement and its flags, the last of which may be `w` and a filename.
func (w *sedScriptWalker) substitute() bool {
	d := w.peek()
	if d == 0 || d == '\n' || d == '\\' {
		return false
	}
	w.i++
	if !w.delimited(d, true) || !w.delimited(d, false) {
		return false
	}
	for w.i < len(w.s) {
		c := w.s[w.i]
		switch {
		case c == 'w':
			w.i++
			w.write(w.filename())
			return true
		case c == 'e':
			w.executes = true
			w.i++
		case strings.IndexByte("gpiImM0123456789 \t", c) >= 0:
			w.i++
		default:
			return w.endOfCommand()
		}
	}
	return true
}

// endOfCommand reads what may follow a command: blanks, then the end of the
// script, a `;` or newline, which it moves past, or a `}` or `#`, which it
// leaves to be read as the next command.
func (w *sedScriptWalker) endOfCommand() bool {
	w.skipBlanks()
	switch w.peek() {
	case 0, '}', '#':
		return true
	case ';', '\n':
		w.i++
		return true
	}
	return false
}

// awkDefers reports whether an awk invocation must defer. awk is read-only
// except when it writes a file. The write modes modeled are:
//
//   - gawk in-place editing: `-i inplace` / `--include inplace` /
//     `--include=inplace`.
//   - gawk profile/pretty-print: `-p`/`--profile` (writes awkprof.out) and
//     `-o`/`--pretty-print` (writes awkprof.out). The file argument is OPTIONAL
//     and ATTACHED (`-pFILE`, `-oFILE`, `--profile=FILE`); a bare `-p`/`-o`
//     still writes the default awkprof.out, so the bare form ALSO defers
//     (a review MEDIUM finding — these were previously listed as read-only boolFlags).
//   - gawk dump-variables: `-d`/`--dump-variables` writes awkvars.out. Swept in
//     with -p/-o per "fix the class": same default-output-file footgun.
//
// `-O`/`--optimize`, `-P`/`--posix`, and `-D`/`--debug` do NOT write a file and
// stay read-only. An explicit output-file redirect is caught by
// sc.hasRedirectToFile in the caller. Any unrecognized flag also defers.
func awkDefers(args []string) bool {
	// NOT awkOperandValueFlags: `-i`/`--include` are deliberately absent here.
	// This walk reaches its attached-short-value arm (`valueFlags[a[:2]]`) only
	// for flags in THIS map, and `-i` there would recognize the glued
	// `-iinplace` as a mere value form and make gawk's in-place WRITE
	// allow-eligible. Left out, that spelling hits the unknown-flag arm and
	// defers, which is the verdict it must keep. The operand walk has the
	// opposite need — it must know `-i` takes a value to see the library file —
	// so the two maps differ on purpose.
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

// awkOperandValueFlags is the value-taking flag set the awk OPERAND walks use —
// awkFileOperands and, through the table's valueFlags, pathFlagValues. It adds
// `-i`/`--include` to the set awkDefers walks, because an operand walk that did
// not know they take a value would read the library name as a file operand
// (and, for pathFlagValues, would never find it at all). See awkDefers for why
// that same addition would be a hole on the DEFER walk.
var awkOperandValueFlags = map[string]bool{
	"-F": true, "--field-separator": true,
	"-v": true, "--assign": true,
	"-f": true, "--file": true,
	"-i": true, "--include": true,
}

// awkPathValueFlags is the subset of awkOperandValueFlags whose value is a PATH:
// `-f PROGFILE` names the program file awk reads, and `-i`/`--include LIB` a
// gawk source library it loads. `-F`'s field separator and `-v`'s assignment
// name no file.
var awkPathValueFlags = map[string]bool{
	"-f": true, "--file": true,
	"-i": true, "--include": true,
}

// awkFileOperands returns the FILE operands of an awk invocation, excluding the
// program text. awk's grammar is `awk [FLAGS] {'program' | -f progfile} [var=value
// | FILE]...`: when no `-f`/`--file` supplied the program, the FIRST non-flag
// operand IS the program and is not a path; the rest are files. A `var=value`
// operand is an awk variable assignment, not a file, and is dropped too.
//
// Flag VALUES (`-F :`, `-v x=1`, `-f prog.awk`) are consumed rather than
// returned, mirroring sedFileOperands: a flag value is not a path operand of the
// command. A flag outside this grammar is skipped as a bool flag; awkDefers
// refuses the invocation's ALLOW on it, but only after these operands have been
// contained, so a value such a flag consumes is walked as a positional, and its
// slot decides its fate: after the program text it is contained as an extra
// file, but in the program-text slot it is dropped uncontained. A value-taking
// flag that awkDefers lists as a bool one has its value walked the same way,
// with no refusal to follow, so the flag tables are load-bearing for
// containment.
func awkFileOperands(args []string) []string {
	valueFlags := awkOperandValueFlags
	programSuppliedByFlag := false
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
		if !strings.HasPrefix(a, "-") || a == "-" {
			operands = append(operands, a)
			continue
		}
		if strings.HasPrefix(a, "--file=") || strings.HasPrefix(a, "-f") && len(a) > 2 {
			programSuppliedByFlag = true
			continue
		}
		if a == "-f" || a == "--file" {
			programSuppliedByFlag = true
			i++ // consume the program file
			continue
		}
		if strings.HasPrefix(a, "--") && strings.Contains(a, "=") {
			continue // long flag carrying its own value
		}
		if valueFlags[a] {
			i++ // consume the flag's value
			continue
		}
		if len(a) >= 2 && a[1] != '-' && valueFlags[a[:2]] {
			continue // attached short value form (`-F:`, `-vx=1`)
		}
		// Treated as a bool flag: known ones carry no value, and an unknown
		// one loses the ALLOW in awkDefers after this walk.
	}
	if !programSuppliedByFlag {
		if len(operands) == 0 {
			return nil
		}
		operands = operands[1:] // the first non-flag operand is the program text
	}
	return dropAssignmentOperands(operands)
}

// dropAssignmentOperands removes `var=value` tokens from an awk operand list.
// awk interleaves variable assignments with file names (`awk '{…}' n=1 f.txt`),
// and an assignment names no file.
func dropAssignmentOperands(operands []string) []string {
	var out []string
	for _, o := range operands {
		if isAssignment(o) {
			continue
		}
		out = append(out, o)
	}
	return out
}

// grepFileOperands returns the FILE operands of a grep invocation, excluding the
// pattern. grep's grammar is `grep [FLAGS] {PATTERN | -e PATTERN | -f PATFILE}
// [FILE...]`: with no `-e`/`-f`, the FIRST non-flag operand is the pattern.
//
// A pattern is not a path, and treating it as one is not merely wasted work: an
// anchored pattern (`grep '/usr/local/bin' f`) looks absolute, so containment
// resolves it outside the repo and DENIES a command that reads only `f`.
//
// A flag outside grep's known grammar is skipped as a bool flag. grepDefers
// refuses the invocation's ALLOW on it, but only after these operands have
// been contained, so a value such a flag consumes is walked as a positional,
// and its slot decides its fate: after the pattern it is contained as an
// extra file, but in the pattern slot it is dropped uncontained. A
// value-taking flag that grepDefers lists as a bool one has its value walked
// the same way, with no refusal to follow, so the flag tables are
// load-bearing for containment.
func grepFileOperands(args []string) []string {
	patternSuppliedByFlag := false
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
		if !strings.HasPrefix(a, "-") || a == "-" {
			operands = append(operands, a)
			continue
		}
		name := a
		glued := strings.Contains(a, "=")
		if glued {
			name = a[:strings.IndexByte(a, '=')]
		}
		switch name {
		case "-e", "--regexp", "-f", "--file":
			patternSuppliedByFlag = true
			if !glued && !(len(a) > 2 && a[1] != '-') && i+1 < len(args) {
				i++ // consume the separate pattern/pattern-file token
			}
			continue
		}
		if glued {
			continue // long flag carrying its own value
		}
		if grepValueFlags[name] {
			i++ // consume the flag's value
			continue
		}
		if len(a) > 2 && a[1] != '-' && (grepValueFlags[a[:2]] || a[:2] == "-e" || a[:2] == "-f") {
			if a[:2] == "-e" || a[:2] == "-f" {
				patternSuppliedByFlag = true
			}
			continue // attached short value form (`-A3`, `-eFOO`)
		}
		// Treated as a bool flag or a short cluster: known ones carry no
		// value, and an unknown one loses the ALLOW in grepDefers after this
		// walk.
	}
	if !patternSuppliedByFlag {
		if len(operands) == 0 {
			return nil
		}
		operands = operands[1:] // the first non-flag operand is the pattern
	}
	return operands
}

// grepValueFlags is the set of grep flags that consume a following token, shared
// by grepDefers (which must not misread the value as an unknown flag) and
// grepFileOperands (which must not misread it as a file). One table, so the two
// walks cannot drift.
var grepValueFlags = map[string]bool{
	"-e": true, "--regexp": true, "-f": true, "--file": true,
	"-m": true, "--max-count": true, "-A": true, "--after-context": true,
	"-B": true, "--before-context": true, "-C": true, "--context": true,
	"-d": true, "--directories": true, "-D": true, "--devices": true,
	"--include": true, "--exclude": true, "--exclude-dir": true,
	"--include-dir": true, "--group-separator": true, "--label": true,
	"--color": true, "--colour": true, "--binary-files": true,
}

// grepPathValueFlags is the subset of grepValueFlags whose value is a PATH.
// `-f PATFILE` names a file grep opens and reads its patterns from, so it must
// stay in containment even though grepFileOperands consumes it as a flag value:
// `grep -f /etc/passwd README.md` reads /etc/passwd. `-e PATTERN` and the
// `--include`/`--exclude` globs are not paths — they are matched against names,
// never opened — and stay out.
var grepPathValueFlags = map[string]bool{"-f": true, "--file": true}

// diffValueFlags is diff's value-taking flag set, and diffPathValueFlags the
// subset whose value is a PATH: `-X`/`--exclude-from` names a file of exclusion
// patterns diff reads, `--from-file`/`--to-file` name the files it compares
// everything against, and `-S`/`--starting-file` names the directory entry it
// starts a recursive comparison at. The rest take a pattern (`-I`, `-x`, `-F`),
// a label (`-L`), a name (`-D`) or a number (`-U`, `-C`, `-W`, `--tabsize`,
// `--horizon-lines`) and name no file.
var diffValueFlags = map[string]bool{
	"-D": true, "--ifdef": true, "-F": true, "--show-function-line": true,
	"-I": true, "--ignore-matching-lines": true, "-L": true, "--label": true,
	"-S": true, "--starting-file": true, "-X": true, "--exclude-from": true,
	"-x": true, "--exclude": true, "-W": true, "--width": true,
	"--from-file": true, "--to-file": true, "--horizon-lines": true,
	"--tabsize": true, "--line-format": true, "--GTYPE-group-format": true,
	"-U": true, "--unified": true, "-C": true, "--context": true,
}

var diffPathValueFlags = map[string]bool{
	"-X": true, "--exclude-from": true,
	"--from-file": true, "--to-file": true,
	"-S": true, "--starting-file": true,
}

// diffDefers reports whether a diff invocation must defer. diff writes only to
// stdout — its grammar has no output-file flag at all — so there is no write
// mode to gate; the predicate exists only for the table's standing fail-safe:
// a flag outside the enumerated grammar defers rather than riding the ALLOW.
func diffDefers(args []string) bool {
	return flagScan{
		valueFlags: diffValueFlags,
		boolFlags: map[string]bool{
			"-a": true, "--text": true, "-b": true, "--ignore-space-change": true,
			"-B": true, "--ignore-blank-lines": true, "-c": true,
			"-d": true, "--minimal": true, "-e": true, "--ed": true,
			"-E": true, "--ignore-tab-expansion": true, "-i": true, "--ignore-case": true,
			"-l": true, "--paginate": true, "-N": true, "--new-file": true,
			"-n": true, "--rcs": true, "-p": true, "--show-c-function": true,
			"-q": true, "--brief": true, "-r": true, "--recursive": true,
			"-s": true, "--report-identical-files": true, "-t": true, "--expand-tabs": true,
			"-T": true, "--initial-tab": true, "-u": true, "-w": true,
			"--ignore-all-space": true, "-y": true, "--side-by-side": true,
			"-Z": true, "--ignore-trailing-space": true, "--no-dereference": true,
			"--strip-trailing-cr": true, "--suppress-common-lines": true,
			"--suppress-blank-empty": true, "--binary": true, "--color": true,
			"--normal": true, "--left-column": true, "--speed-large-files": true,
			"--unidirectional-new-file": true, "--no-ignore-file-name-case": true,
			"--ignore-file-name-case": true,
		},
		maxPathOperands: -1,
		// clusterable: `diff -ru`, `diff -qr` are the common forms. diff has no
		// write flag, so a cluster ALLOWs only when every character is a known
		// bool — a cluster containing a value flag (`-U`, `-C`) defers.
		clusterable: true,
	}.defers(args)
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
