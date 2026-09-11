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
// The repair is one predicate (homeUsable) applied at one chokepoint: on the
// Bash track the classifier's own walk raises the deny as it goes
// (extractSimpleCommands, engine_a_bash.go), and on the file-tool track
// fileToolHomeChokepoint does. Downstream of it a site that reads home either
// gets a usable absolute home or the event has already been denied, so no site
// does its own emptiness or IsAbs test on a home value.
//
// The Bash half belongs inside the classifier's walk rather than in a scan of
// its own, because grading a home reference needs the three pieces of state
// that walk already carries: the variables assigned so far, the scope depth
// they are recorded at, and the tracked cwd their values resolve against. A
// second walk has to mirror all three to reach the same verdict, and whatever
// it fails to mirror is an escape — a loop-variable binding it does not learn
// hides the `cd` in `for C in cd; do $C; done`, and an assignment RHS it does
// not descend into hides a `HOME=` inside a command substitution. So this file
// holds only the pure predicates, and the walk calls them.

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
// home and is unusable.
//
// The resolution carries no knownVars and an empty cwdCtx even though the walk
// that calls it holds both, so a value built from an in-script variable
// (`D=/abs; HOME=$D`), from $PWD, or from an anchor substitution
// (`HOME=$(pwd)`) is inexact here and grades unusable. Withholding them can
// only make this grader stricter, and stricter here is the deny direction:
// the gate denies a later `~` rather than placing the home on a resolution the
// word itself never gets. bareCd's PROGRAM word is the opposite case — there
// an unresolved word would MISS a `cd` call — so it is given both.
//
// Callers pass only an assignment that carries an `=`. A naked `export HOME`
// sets no value and must leave the home's existing grade alone, which no bool
// this returns can say.
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
// The PROGRAM word is resolved with the knownVars and cwd context the walk
// holds, so this and applyCd recognize the same calls as `cd`: `C=cd; $C` and
// `C=$PWD/cd; $C` are `cd` at both sites.
//
// An operand is a DIRECTORY operand unless it is an option (cdOption) or
// expands to no field at all (wordYieldsNoField), so `cd`, `cd -P`, `cd -L`,
// `cd --`, `X=; cd $X` and their combinations are all this shape, while `cd x`,
// `cd ~`, `cd ""` and `cd -` are not — the first two carry a word of their own
// for the walk to grade, `cd ""` passes bash one empty operand and stays put,
// and `cd -` names $OLDPWD rather than $HOME.
//
// applyCd reads the same operands less strictly: it has no option arm and no
// zero-field arm, so under a usable home `cd -P` tracks `<cwd>/-P` and
// `X=; cd $X` tracks the cwd unchanged where bash goes to $HOME in both. That
// is a cwd-tracking question and not this predicate's, which only decides
// whether the call references the home.
func bareCd(n syntax.Node, knownVars map[string]string, resolver varResolver, cc cwdCtx) bool {
	call, ok := n.(*syntax.CallExpr)
	if !ok || len(call.Args) == 0 {
		return false
	}
	prog, _ := literalWord(call.Args[0], knownVars, resolver, cc)
	if basename(prog) != "cd" {
		return false
	}
	for _, arg := range call.Args[1:] {
		if wordYieldsNoField(arg, knownVars, resolver, cc) {
			continue
		}
		lit, exact := literalWord(arg, knownVars, resolver, cc)
		if !exact || !cdOption(lit) {
			return false
		}
	}
	return true
}

// wordYieldsNoField reports whether a word expands to NO field, rather than to
// one empty field. Bash word-splits an unquoted expansion that came out empty
// into zero fields, so `X=; cd $X` passes `cd` no operand at all and goes to
// $HOME, while any quoted or literal part in the word — `cd ""`, `cd "$X"`,
// `cd $X""` — leaves one empty operand, which bash reads as "stay put".
func wordYieldsNoField(w *syntax.Word, knownVars map[string]string, resolver varResolver, cc cwdCtx) bool {
	lit, exact := literalWord(w, knownVars, resolver, cc)
	if !exact || lit != "" {
		return false
	}
	for _, p := range w.Parts {
		switch p.(type) {
		case *syntax.Lit, *syntax.SglQuoted, *syntax.DblQuoted:
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
