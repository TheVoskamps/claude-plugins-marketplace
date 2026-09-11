package main

import (
	"fmt"
	"os"
	"path/filepath"

	"mvdan.cc/sh/v3/syntax"
)

// Home-directory usability, decided ONCE for the whole gate.
//
// The gate reads the home directory from a dozen places — `~` expansion in a
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
// A bare `cd` (bareCd) is a home reference too: bash sends it to $HOME, so it
// denies here under an unusable home like any `~`-spelling would, and nothing
// downstream is left to track a home the gate cannot place.
//
// Deliberate over-approximations, each in the deny direction:
//
//   - An in-script `HOME=` whose value literalWord cannot resolve EXACTLY is
//     graded unusable, because the gate cannot place the home the later words
//     resolve against. That set is an append, an array, a command substitution
//     outside the anchor allowlist, and an expansion this scan cannot resolve —
//     `$PWD`, or a variable assigned earlier in the same program, neither of
//     which it tracks (assignedHomeUsable). It does NOT include `HOME=$HOME/sub`
//     or `HOME=~/sub`: literalWord resolves both against the PROCESS home — the
//     resolution threads no in-script value, so a second `HOME=` built from the
//     first resolves against the process home too — and under a usable process
//     home each sets a usable home and denies nothing. This arm
//     therefore does move with both homes usable — `HOME=$(pwd); cat ~/x` denies
//     though bash would have placed that home fine.
//   - The scan is flat: an assignment inside a subshell, a function body or a
//     backgrounded group is graded as if it persisted, where recordAssign
//     scopes it. A scoped `HOME=<relative>` therefore denies later home words
//     that real bash would resolve against the process home — which, when the
//     process home is itself usable, is the only case this arm moves.
func bashHomeChokepoint(file *syntax.File, resolver varResolver) (Decision, bool) {
	_, homeOK := resolveHome(resolver.homeDir)
	scriptHomeSeen := false
	scriptHomeOK := false

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

	syntax.Walk(file, func(n syntax.Node) bool {
		if hit {
			return false
		}
		// A bare `cd` references the home directory with no word that carries
		// a `~` or a `$HOME`, so it is graded here rather than by gradeWords.
		if bareCd(n, resolver) && !effectiveOK() {
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
			return true
		}
		for _, a := range assigns {
			// The right-hand side is expanded with the home in effect BEFORE
			// the assignment, so it is graded first — `HOME=~/sub` references
			// the old home — and only then does the new value take effect.
			gradeWords(a)
			if hit {
				return false
			}
			if a.Name != nil && a.Name.Value == "HOME" {
				scriptHomeSeen = true
				scriptHomeOK = assignedHomeUsable(a, resolver)
			}
		}
		// Everything beneath has just been graded, in assignment order.
		return false
	})
	return d, hit
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
// The resolution carries no knownVars and an empty cwdCtx: this scan runs
// before the classifier that tracks assignments and the cwd, so a value built
// from an in-script variable (`D=/abs; HOME=$D`) or from $PWD is inexact here
// and grades unusable.
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

// bareCd reports whether n is a `cd` call carrying no operand. That is the one
// home reference spelled with no home-referencing WORD — bash sends a bare `cd`
// to $HOME — so the chokepoint grades it like any other home reference. The
// detection mirrors applyCd's own bare-cd arm: a call whose single argument has
// basename `cd`. A `cd` carrying any operand, an option among them, is not this
// shape; its operand is graded as the word it is.
func bareCd(n syntax.Node, resolver varResolver) bool {
	call, ok := n.(*syntax.CallExpr)
	if !ok || len(call.Args) != 1 {
		return false
	}
	prog, _ := literalWord(call.Args[0], nil, resolver, cwdCtx{})
	return basename(prog) == "cd"
}
