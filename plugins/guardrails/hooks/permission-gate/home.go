package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// Home-directory usability, decided ONCE for the whole gate.
//
// The gate reads the home directory from many places — `~` expansion in a
// Bash word, `$HOME` resolution, an in-script `HOME=` assignment, `cd` / `cd ~`
// tracking, the containment resolver's tilde arm, `lexicalAbs`, the carve-out
// config loader, the Claude config root, the evolution-log path. Before this
// chokepoint each of those sites decided for itself what an unusable home
// meant, so the same relative `$HOME` produced a different outcome per site:
// `cat ~/x` allowed (the tilde joined onto the tracked cwd as an in-repo path)
// while `cat "$HOME/x"` deferred, and the log was written into the worktree.
// Nothing escaped — a relative home is joined UNDER the worktree — but the gate
// believed the operator's home sat at `<worktree>/relhome`, and every rule
// added later would have inherited that.
//
// The repair is one predicate (homeUsable) applied at one chokepoint
// (bashHomeChokepoint / fileToolHomeChokepoint), before any track-specific
// logic runs. Downstream of it a site that reads home either gets a usable
// absolute home or the event has already been denied, so no site does its own
// emptiness or IsAbs test on a home value.

// homeUsable is the ONE predicate that decides whether a home-directory value
// may be used. A home is usable iff it resolved without error, is non-empty,
// and is absolute. Callers that hold a value rather than a resolver (an
// in-script `HOME=` assignment, expandLeadingTilde's parameter) pass a nil
// error.
func homeUsable(home string, err error) bool {
	return err == nil && home != "" && filepath.IsAbs(home)
}

// resolveHome resolves a home directory through the injected resolver and
// grades it with homeUsable. A nil resolver is unusable, which is how the
// zero-value varResolver ("no source for any of these names") stays
// fail-closed. The value is returned VERBATIM: callers that need bash's
// trailing-slash-free spelling Clean it themselves, and expandLeadingTilde
// carries the post-`~` remainder uncleaned on purpose.
func resolveHome(homeDir func() (string, error)) (string, bool) {
	if homeDir == nil {
		return "", false
	}
	home, err := homeDir()
	if !homeUsable(home, err) {
		return "", false
	}
	return home, true
}

// processHome resolves the gate process's own home directory.
func processHome() (string, bool) {
	return resolveHome(os.UserHomeDir)
}

// homeUnusableOp is the classified-operation label for the chokepoint deny.
const homeUnusableOp = "home:unusable"

// denyUnusableHome is the chokepoint's single verdict, for both tracks. It is
// a DENY rather than a defer because a path whose home the gate cannot place is
// a containment escape by the gate's own reckoning: it cannot say which
// directory the operand lands in, and the downstream judge has no more to go on
// than the gate does. The redirect is total — every legitimate use of the
// spelling has an absolute spelling that says the same thing.
func denyUnusableHome(spelling string) Decision {
	return deny(homeUnusableOp, fmt.Sprintf(
		"Blocked: `%s` names the home directory, but this process has no usable home — $HOME (or the "+
			"in-script HOME= this word resolves against) is unset, empty, or not an absolute path. The gate "+
			"cannot tell which directory that operand lands in, so it grades it as a containment escape. "+
			"Spell the target as an absolute path carrying no `~` and no `$HOME`, or re-run with $HOME set "+
			"to an absolute path.", spelling))
}

// bashHomeChokepoint denies a parsed Bash program in which any word references
// an unusable home. It runs before every track-specific classifier, so no
// track sees a word whose home the gate could not place.
//
// It grades two values with the one predicate: the process home the resolver
// returns, and the value of each PERSISTENT in-script `HOME=` assignment (see
// persistentAssigns). A word is judged against the in-script value once one has
// been seen, and against the process home before that — the same precedence
// resolveVar applies to `$HOME`.
//
// A `cd` that carries no directory operand (bareCd) is a home reference too:
// bash sends it to $HOME, so it denies here under an unusable home like any
// `~`-spelling would, and nothing downstream is left to track a home the gate
// cannot place.
//
// The scan carries its own knownVars, recorded exactly as recordAssign records
// the classifier's: a top-level static assignment only, dropped on an RHS that
// does not resolve exactly. It is consulted only where failing to resolve a
// word would make the scan miss a home reference and UNDER-deny — the `cd`
// program word (bareCd), so that `C=cd; $C` is the same `cd` call here that it
// is in applyCd. Grading a HOME= VALUE keeps the nil map on purpose
// (assignedHomeUsable): there an unresolved value grades unusable, which is the
// deny direction already.
//
// Deliberate over-approximations, each in the deny direction:
//
//   - An in-script `HOME=` whose value literalWord cannot resolve EXACTLY is
//     graded unusable, because the gate cannot place the home the later words
//     resolve against. That set is an append, an array, a command substitution,
//     and an expansion this scan cannot resolve — `$PWD`, or a variable assigned
//     earlier in the same program, neither of which it tracks
//     (assignedHomeUsable). It does NOT include `HOME=$HOME/sub`
//     or `HOME=~/sub`: literalWord resolves both against the PROCESS home — the
//     resolution threads no in-script value, so a second `HOME=` built from the
//     first resolves against the process home too — and under a usable process
//     home each sets a usable home and denies nothing. This arm
//     therefore does move with both homes usable — `HOME=$(pwd); cat ~/x` denies
//     though bash would have placed that home fine.
//   - A SCOPED `HOME=` — one inside a subshell, a function body, a backgrounded
//     statement or a substitution — does not set the home the words after the
//     scope resolve against, so it may only make the scan stricter, never
//     laxer: it takes effect here when it grades UNUSABLE (and then stays in
//     effect past the scope, which recordAssign would not), and is ignored when
//     it grades usable. So a scoped `HOME=<relative>` denies later home words
//     that real bash would resolve against a usable process home, while
//     `(HOME=/abs); cat ~/x` under an UNUSABLE process home still denies rather
//     than riding a home the enclosing shell never had.
//   - A `cd` whose operands are all options — `cd -P`, `cd -L`, `cd --`, and
//     combinations — is a bare `cd` here (cdOption). An operand bash would
//     reject as an invalid option is graded as one too, which denies a `cd`
//     bash would not have moved at all.
func bashHomeChokepoint(file *syntax.File, resolver varResolver) (Decision, bool) {
	_, homeOK := resolveHome(resolver.homeDir)
	scriptHomeSeen := false
	scriptHomeOK := false
	knownVars := map[string]string{}

	effectiveOK := func() bool {
		if scriptHomeSeen {
			return scriptHomeOK
		}
		return homeOK
	}

	var d Decision
	hit := false
	// gradeWords denies on the first home-referencing word beneath n, judged
	// against the home in effect right now.
	gradeWords := func(n syntax.Node) {
		syntax.Walk(n, func(n syntax.Node) bool {
			if hit {
				return false
			}
			w, ok := n.(*syntax.Word)
			if !ok {
				return true
			}
			if spelling, ok := wordHomeReference(w); ok && !effectiveOK() {
				d = denyUnusableHome(spelling)
				hit = true
				return false
			}
			return true
		})
	}

	// scopeDepth counts the scoping constructs the walk is currently inside, the
	// same set recordAssign scopes against: a `( … )` subshell, a function body,
	// a backgrounded statement, and a command or process substitution. syntax.Walk
	// reports a node's EXIT as a nil callback that does not name the node — and
	// only for a node whose callback returned true — so the depth is carried on
	// an explicit stack, pushed by descend and popped by that nil.
	scopeDepth := 0
	var scopes []bool
	descend := func(n syntax.Node) bool {
		opens := opensScope(n)
		scopes = append(scopes, opens)
		if opens {
			scopeDepth++
		}
		return true
	}

	syntax.Walk(file, func(n syntax.Node) bool {
		if n == nil {
			if last := len(scopes) - 1; last >= 0 {
				if scopes[last] {
					scopeDepth--
				}
				scopes = scopes[:last]
			}
			return true
		}
		if hit {
			return false
		}
		// A `cd` carrying no directory operand references the home directory
		// with no word that carries a `~` or a `$HOME`, so it is graded here
		// rather than by gradeWords.
		if bareCd(n, knownVars, resolver) && !effectiveOK() {
			d = denyUnusableHome("cd")
			hit = true
			return false
		}
		// A HOME assignment feeds LATER words only when it is a persistent
		// one: a standalone `HOME=x` (a call expression with assignments and
		// no program) or a declaration (`export HOME=x`). A PREFIX assignment
		// — `HOME=x cmd …`, a call expression that has a program — sets the
		// environment of that one command, and the gate's own word resolution
		// does not record it (measured against the committed binary:
		// `HOME=/absolute/home cat ~/x` resolves the tilde against the PROCESS
		// home, while `HOME=/absolute/home; cat ~/x` resolves it against
		// `/absolute/home`). So a prefix assignment updates nothing here, and
		// its words are graded like any other.
		assigns, persistent := persistentAssigns(n)
		if !persistent {
			if w, ok := n.(*syntax.Word); ok {
				if spelling, ok := wordHomeReference(w); ok && !effectiveOK() {
					d = denyUnusableHome(spelling)
					hit = true
					return false
				}
			}
			return descend(n)
		}
		for _, a := range assigns {
			// The right-hand side is expanded with the home in effect BEFORE
			// the assignment, so it is graded first — `HOME=~/sub` references
			// the old home — and only then does the new value take effect.
			gradeWords(a)
			if hit {
				return false
			}
			if a.Name == nil {
				continue
			}
			if a.Name.Value == "HOME" && !a.Naked {
				// A NAKED `export HOME` (no `=`) sets no value: bash leaves
				// $HOME exactly as it was, so the effective home keeps whatever
				// grade it already had. Only a spelling carrying an `=` —
				// `HOME=` included, which sets the empty home — reaches the
				// grader.
				usable := assignedHomeUsable(a, resolver)
				if scopeDepth == 0 || !usable {
					scriptHomeSeen = true
					scriptHomeOK = usable
				}
			}
			recordScanVar(knownVars, a, scopeDepth, resolver)
		}
		// Everything beneath has just been graded, in assignment order.
		return false
	})
	return d, hit
}

// opensScope reports whether a node runs what is beneath it in a CHILD shell,
// so an assignment made there does not reach a word after the node. It names the
// same set recordAssign's scopeDepth counts: a `( … )` subshell, a function
// body, a backgrounded statement, and a command or process substitution.
func opensScope(n syntax.Node) bool {
	switch x := n.(type) {
	case *syntax.Subshell, *syntax.FuncDecl, *syntax.CmdSubst, *syntax.ProcSubst:
		return true
	case *syntax.Stmt:
		return x.Background
	}
	return false
}

// recordScanVar captures one assignment into the chokepoint's own knownVars,
// mirroring recordAssign: a scoped assignment is not recorded at all (and does
// not delete a top-level value, which it would not overwrite in real bash), an
// append/array/indexed assignment or an RHS that does not resolve exactly drops
// any prior value, and a naked `export VAR` leaves the value alone.
//
// The RHS is resolved with an EMPTY cwdCtx, because the scan runs before the
// classifier that tracks the cwd. A `$PWD`-built value is therefore inexact
// here and exact there — the one axis on which this map and recordAssign's
// still disagree, and the one that leaves applyCd's bare-cd fail-safe arm
// reachable (see engine_a_bash.go).
func recordScanVar(knownVars map[string]string, a *syntax.Assign, scopeDepth int, resolver varResolver) {
	if a.Name == nil || scopeDepth > 0 || a.Naked {
		return
	}
	name := a.Name.Value
	if a.Append || a.Array != nil || a.Index != nil {
		delete(knownVars, name)
		return
	}
	if a.Value == nil {
		knownVars[name] = ""
		return
	}
	val, exact := literalWord(a.Value, knownVars, resolver, cwdCtx{})
	if !exact {
		delete(knownVars, name)
		return
	}
	knownVars[name] = val
}

// persistentAssigns returns the assignments a node makes to the shell's own
// environment — the ones a later word resolves against — and whether the node
// is one that makes any. A call expression with a program carries PREFIX
// assignments, which are scoped to that command and are not persistent.
func persistentAssigns(n syntax.Node) ([]*syntax.Assign, bool) {
	switch x := n.(type) {
	case *syntax.CallExpr:
		if len(x.Args) > 0 {
			return nil, false
		}
		return x.Assigns, true
	case *syntax.DeclClause:
		return x.Args, true
	}
	return nil, false
}

// fileToolHomeChokepoint denies a file-tool event (Read/Write/Edit/…) whose
// operand references an unusable home via a leading `~`. A file-tool operand is
// a raw string with no shell around it, so `~` is the only home spelling it can
// carry — a literal `$HOME` in a file_path is not expanded by anything and
// names no home.
func fileToolHomeChokepoint(paths []string) (Decision, bool) {
	for _, p := range paths {
		if !hasLeadingTilde(p) {
			continue
		}
		if _, ok := processHome(); !ok {
			return denyUnusableHome(p), true
		}
	}
	return Decision{}, false
}

// wordHomeReference reports whether a word references the home directory, and
// with which spelling. These spellings count:
//
//   - a leading `~` or `~/…`, in ANY quoting — the gate's own tilde handling
//     (applyCd, canonicalizeFromResolver) expands the quoted spelling too, so
//     the chokepoint has to see the same set of words those sites do. A
//     `~someone/x` username reference is NOT one: it names another account's
//     home, which no site here resolves (hasLeadingTilde is the shared test).
//   - a `$HOME` / `${HOME}` parameter expansion anywhere in the word.
func wordHomeReference(w *syntax.Word) (string, bool) {
	if w == nil {
		return "", false
	}
	if hasLeadingTilde(wordLeadingLiteral(w)) {
		return printWord(w), true
	}
	found := false
	syntax.Walk(w, func(n syntax.Node) bool {
		if found {
			return false
		}
		if pe, ok := n.(*syntax.ParamExp); ok && pe.Param != nil && pe.Param.Value == "HOME" {
			found = true
			return false
		}
		return true
	})
	if found {
		return printWord(w), true
	}
	return "", false
}

// wordLeadingLiteral returns as much of the word's leading LITERAL text as the
// tilde test needs, stripping one layer of quoting. It is deliberately not an
// expansion: the point is to see the tilde as written, before anything tries to
// resolve it against a home that may not exist.
func wordLeadingLiteral(w *syntax.Word) string {
	if len(w.Parts) == 0 {
		return ""
	}
	switch p := w.Parts[0].(type) {
	case *syntax.Lit:
		return p.Value
	case *syntax.SglQuoted:
		return p.Value
	case *syntax.DblQuoted:
		if len(p.Parts) == 0 {
			return ""
		}
		if lit, ok := p.Parts[0].(*syntax.Lit); ok {
			return lit.Value
		}
	}
	return ""
}

// assignedHomeUsable grades the value an in-script `HOME=` assignment sets. It
// resolves that value with the package's own word resolver (literalWord), so
// `HOME=$HOME/sub` and `HOME=~/sub` resolve exactly as they do everywhere else
// in the gate rather than against a second, stricter notion of "literal". A
// value literalWord cannot resolve EXACTLY leaves the gate unable to place the
// home and is unusable (see bashHomeChokepoint's over-approximations).
//
// The resolution carries no knownVars and an empty cwdCtx, so a value built
// from an in-script variable (`D=/abs; HOME=$D`) or from $PWD is inexact here
// and grades unusable. The scan does hold a knownVars map of its own, and this
// grader is not given it on purpose: an unresolved value here grades unusable,
// which denies, so the nil map can only over-deny — where bareCd's program word
// would UNDER-deny unresolved, and is given the map.
//
// Callers pass only an assignment that carries an `=`. A naked `export HOME`
// sets no value and must leave the home's existing grade alone, which no bool
// this returns can say (see bashHomeChokepoint).
func assignedHomeUsable(a *syntax.Assign, resolver varResolver) bool {
	if a.Append || a.Array != nil || a.Index != nil {
		return false
	}
	if a.Value == nil {
		// `HOME=` — the empty home, which the predicate rejects.
		return false
	}
	val, exact := literalWord(a.Value, nil, resolver, cwdCtx{})
	if !exact {
		return false
	}
	return homeUsable(val, nil)
}

// bareCd reports whether n is a `cd` call carrying no DIRECTORY operand. That is
// the home reference spelled with no home-referencing WORD — bash sends such a
// `cd` to $HOME — so the chokepoint grades it like any other home reference.
//
// The PROGRAM word is resolved with the knownVars the scan holds, so this and
// applyCd call the same calls `cd`: `C=cd; $C` is one at both sites, where
// resolving it against a nil map here left the chokepoint silent and applyCd
// tracking the home on its own.
//
// The OPERANDS are read more strictly here than applyCd reads them. An operand
// is a directory operand unless cdOption grades it an option, so `cd`, `cd -P`,
// `cd -L`, `cd --` and their combinations are all this shape, while `cd x`,
// `cd ~` and `cd -` are not — the first two carry a word of their own for
// gradeWords, and `cd -` names $OLDPWD rather than $HOME. applyCd has no option
// arm and reads `cd -P` as a relative target, which under a usable home tracks
// `<cwd>/-P`; that is a cwd-tracking question and not this predicate's, which
// only decides whether the call references the home.
func bareCd(n syntax.Node, knownVars map[string]string, resolver varResolver) bool {
	call, ok := n.(*syntax.CallExpr)
	if !ok || len(call.Args) == 0 {
		return false
	}
	prog, _ := literalWord(call.Args[0], knownVars, resolver, cwdCtx{})
	if basename(prog) != "cd" {
		return false
	}
	for _, arg := range call.Args[1:] {
		lit, exact := literalWord(arg, knownVars, resolver, cwdCtx{})
		if !exact || !cdOption(lit) {
			return false
		}
	}
	return true
}

// cdOption reports whether a resolved `cd` operand is an OPTION rather than the
// directory operand — every `-`-prefixed word except a lone `-`, which names
// $OLDPWD. It is deliberately wider than bash's own option set (`-L`, `-P`,
// `-e`, `-@`, and the `--` end-of-options marker): a `cd -x` bash rejects
// outright is graded a bare `cd` here and denies under an unusable home, which
// is the deny direction.
func cdOption(lit string) bool {
	return strings.HasPrefix(lit, "-") && lit != "-"
}
