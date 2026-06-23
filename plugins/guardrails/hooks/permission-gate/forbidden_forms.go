package main

import (
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// forbiddenForm detects the command shapes that the replaced
// auto-approve-compound-commands.sh denied (rules/git-workflow.md "Forbidden
// command forms"). Both trip harness gates and both have a clean two-call
// alternative, so the gate denies them with a teaching remediation.
//
//	Form 1: `cd <path> && git ...` — the CVE-2025-59536 harness gate prompts
//	        on this regardless of hook approvals. Narrowed to a following
//	        `git` command so the documented subagent carve-out
//	        (`cd <subdir> && <non-git-cmd>`, e.g. `cd frontend && npm run
//	        build`) is preserved — that form is explicitly allowed by
//	        git-workflow.md and must not be denied.
//	Form 2: `git -C <abs-path> <subcommand>` — the harness prompts on these
//	        even when allow-listed (#78).
//
// Form 3 (subshells with `;`) was a harness walker-bug workaround in the old
// regex hook; it is left to the harness, which still mishandles that shape —
// the AST parses it fine, so there is no semantic boundary for the gate to
// enforce there.
//
// Detection is AST-based, so it is not fooled by quoting the way the old
// regex was (a literal `echo 'cd /x && y'` is a single argument word, not a
// BinaryCmd, and does not trigger).
func forbiddenForm(file *syntax.File) (Decision, bool) {
	var found Decision
	var hit bool

	syntax.Walk(file, func(node syntax.Node) bool {
		if hit {
			return false
		}
		switch n := node.(type) {
		case *syntax.BinaryCmd:
			// Form 1: `cd <path> && git ...`. The command immediately to the
			// LEFT of an && is a `cd` with an argument, AND the command on the
			// right starts with `git`. Because && is left-associative
			// (`a && b && c` = `(a && b) && c`), the cd is the RIGHTMOST leaf of
			// the left operand's subtree, and the right command is the LEFTMOST
			// leaf of the right operand's subtree.
			if n.Op == syntax.AndStmt && stmtIsCdWithArg(rightmostLeaf(n.X)) && stmtIsGit(leftmostLeaf(n.Y)) {
				found = deny("forbidden-form:cd-&&-git",
					"Forbidden form 'cd <path> && git ...'. The harness gate (CVE-2025-59536) prompts on this "+
						"regardless of approvals. Use two separate Bash calls instead: first 'cd <path>', then the bare "+
						"'git <subcommand>'. CWD persists across calls in the main session. See rules/git-workflow.md "+
						"\"Forbidden command forms\" and issue #78.")
				hit = true
				return false
			}
		case *syntax.CallExpr:
			// Form 2: `git -C <abs-path> ...`.
			if callIsGitDashCAbs(n) {
				found = deny("forbidden-form:git-C-abs",
					"Forbidden form 'git -C <abs-path> <subcommand>'. The harness prompts on these even when "+
						"allow-listed (#78). Use two separate Bash calls instead: first 'cd <abs-path>', then the bare "+
						"'git <subcommand>'. See rules/git-workflow.md \"Forbidden command forms\".")
				hit = true
				return false
			}
		}
		return true
	})
	return found, hit
}

// rightmostLeaf returns the rightmost (last-executed) statement of a possibly
// nested BinaryCmd subtree. For a plain statement it returns the statement
// itself; for `a && b` (or `a | b`, etc.) it descends into Y. This is what
// "the command immediately before this &&" means for left-associative &&.
func rightmostLeaf(stmt *syntax.Stmt) *syntax.Stmt {
	if stmt == nil {
		return nil
	}
	if bin, ok := stmt.Cmd.(*syntax.BinaryCmd); ok {
		return rightmostLeaf(bin.Y)
	}
	return stmt
}

// leftmostLeaf returns the leftmost (first-executed) statement of a possibly
// nested BinaryCmd subtree by descending into X.
func leftmostLeaf(stmt *syntax.Stmt) *syntax.Stmt {
	if stmt == nil {
		return nil
	}
	if bin, ok := stmt.Cmd.(*syntax.BinaryCmd); ok {
		return leftmostLeaf(bin.X)
	}
	return stmt
}

// stmtIsCdWithArg reports whether a statement is a `cd <arg>` call (bare `cd`
// with no argument changes to $HOME and is not the forbidden form).
func stmtIsCdWithArg(stmt *syntax.Stmt) bool {
	if stmt == nil || stmt.Cmd == nil {
		return false
	}
	call, ok := stmt.Cmd.(*syntax.CallExpr)
	if !ok || len(call.Args) < 2 {
		return false
	}
	prog, _ := literalWord(call.Args[0])
	return basename(prog) == "cd"
}

// stmtIsGit reports whether a statement's command is a `git ...` call.
func stmtIsGit(stmt *syntax.Stmt) bool {
	if stmt == nil || stmt.Cmd == nil {
		return false
	}
	call, ok := stmt.Cmd.(*syntax.CallExpr)
	if !ok || len(call.Args) == 0 {
		return false
	}
	prog, _ := literalWord(call.Args[0])
	return basename(prog) == "git"
}

// callIsGitDashCAbs reports whether a CallExpr is `git -C <abs-path> ...`,
// where <abs-path> is an absolute path. Relative `-C` is left alone (it falls
// through to the normal classifier). The git globals before `-C` are skipped
// the same way classifyGit parses them.
func callIsGitDashCAbs(call *syntax.CallExpr) bool {
	if len(call.Args) < 2 {
		return false
	}
	prog, _ := literalWord(call.Args[0])
	if basename(prog) != "git" {
		return false
	}
	// Collect literal arg values after the program token.
	args := make([]string, 0, len(call.Args)-1)
	for _, w := range call.Args[1:] {
		lit, _ := literalWord(w)
		args = append(args, lit)
	}
	// Scan for a `-C` / `-C<path>` global with an absolute path.
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "-C" {
			if i+1 < len(args) && strings.HasPrefix(args[i+1], "/") {
				return true
			}
		} else if strings.HasPrefix(a, "-C") && len(a) > 2 {
			if strings.HasPrefix(strings.TrimPrefix(a, "-C"), "/") {
				return true
			}
		}
	}
	return false
}
