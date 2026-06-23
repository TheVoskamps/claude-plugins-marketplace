package main

import (
	"fmt"
	"io"
	"strings"

	"mvdan.cc/sh/v3/expand"
	"mvdan.cc/sh/v3/syntax"
)

// classifyBash parses a Bash command to an AST and classifies it. The result
// is the AGGREGATE verdict over every simple command in the line: a single
// DENY beats everything, then ASK, then ALLOW; if every simple command is a
// high-confidence ALLOW the whole line is allowed; otherwise it defers to the
// normal pipeline.
//
// Fail-closed: a parse error or an unhandled AST construct yields ASK (the
// gate cannot prove the line safe, so it escalates to a human), never allow.
func classifyBash(command string, ev *Event) Decision {
	parser := syntax.NewParser(syntax.KeepComments(false))
	file, err := parser.Parse(strings.NewReader(command), "")
	if err != nil {
		// Unparseable command is a §9 fail-closed case. We escalate to a
		// human (ASK) rather than block outright, because an unparseable
		// command is often a human-authored one-liner the human can vet.
		return ask("bash:parse-error", fmt.Sprintf(
			"Blocked: the Bash command could not be parsed (%v), so the permission "+
				"gate cannot classify it. Escalating to a human decision (fail-closed). "+
				"Simplify the command or run its parts separately.", err))
	}

	// Forbidden command shapes (ported from the replaced
	// auto-approve-compound-commands.sh; see rules/git-workflow.md "Forbidden
	// command forms"). These trip harness gates / walker bugs and have a
	// working two-call alternative, so the gate denies them with a teaching
	// remediation rather than letting them through.
	if d, hit := forbiddenForm(file); hit {
		return d
	}

	cmds, extractErr := extractSimpleCommands(file)
	if extractErr != nil {
		return ask("bash:unhandled-construct", fmt.Sprintf(
			"Blocked: the Bash command contains a construct the permission gate "+
				"cannot statically classify (%v). Escalating to a human decision "+
				"(fail-closed).", extractErr))
	}
	if len(cmds) == 0 {
		// Nothing executable (e.g. only assignments / comments). Defer.
		return deferToPipeline()
	}

	worst := BucketAllow
	var worstDecision Decision
	sawNonAllow := false

	for _, sc := range cmds {
		d := classifySimpleCommand(sc, ev)
		switch d.Bucket {
		case BucketDeny:
			// Hard deny short-circuits the whole line.
			return d
		case BucketAsk:
			if worst != BucketAsk {
				worst = BucketAsk
				worstDecision = d
			}
			sawNonAllow = true
		case BucketDefer:
			// This part has no high-confidence allow; the line cannot be a
			// clean allow. Remember that we saw a non-allow.
			sawNonAllow = true
		case BucketAllow:
			// keep scanning
		}
	}

	if worst == BucketAsk {
		return worstDecision
	}
	if sawNonAllow {
		// Some part wasn't a high-confidence allow and wasn't deny/ask either
		// — hand the whole line back to the normal permission pipeline rather
		// than auto-allowing. This keeps the allow track to cheap, certain
		// wins only (§4 posture).
		return deferToPipeline()
	}
	return allow("all command parts are provably read-only / non-mutating")
}

// simpleCommand is a flattened view of one executed command: the program
// name plus its arguments, with leading `env VAR=x` wrappers and assignment
// prefixes stripped. Path-bearing arguments are kept verbatim for Engine B.
type simpleCommand struct {
	// args[0] is the program; args[1:] are its arguments (literal-expanded
	// where statically possible). Empty args means "could not determine the
	// program" → the caller treats it as fail-closed ASK.
	args []string
	// hasUnknownExpansion is true when any word contained a command
	// substitution or an unresolved parameter expansion. Such a command
	// cannot be statically proven safe (#1), so it must not ALLOW.
	hasUnknownExpansion bool
	// hasRedirectToFile is true when the command redirects stdout/stderr to a
	// real file (not /dev/null). Such a command can exfiltrate/clobber and
	// must not ride an allow-listed prefix.
	hasRedirectToFile bool
}

// allowEligible reports whether a command is eligible for the high-confidence
// ALLOW track. A command with a real-file redirect (exfiltration/clobber risk)
// or an unresolved expansion / command substitution (#1: cannot be proven
// safe statically) is NOT eligible and must defer to the normal pipeline
// instead of auto-allowing.
func (sc simpleCommand) allowEligible() bool {
	return !sc.hasRedirectToFile && !sc.hasUnknownExpansion
}

// extractSimpleCommands walks the AST and returns every CallExpr-bearing
// simple command, descending through &&/||/;, pipelines, subshells, blocks,
// and basic control flow. It returns an error for constructs that cannot be
// statically reduced to a set of commands (the fail-closed signal).
func extractSimpleCommands(file *syntax.File) ([]simpleCommand, error) {
	var out []simpleCommand
	var walkErr error

	var walkStmt func(stmt *syntax.Stmt)
	var walkCmd func(cmd syntax.Command, redirs []*syntax.Redirect)

	walkCmd = func(cmd syntax.Command, redirs []*syntax.Redirect) {
		if walkErr != nil {
			return
		}
		switch c := cmd.(type) {
		case *syntax.CallExpr:
			sc, err := reduceCallExpr(c, redirs)
			if err != nil {
				walkErr = err
				return
			}
			// A bare assignment-only CallExpr (VAR=x with no program) yields
			// no args; skip it (it mutates only shell state).
			if len(sc.args) > 0 {
				out = append(out, sc)
			}
		case *syntax.BinaryCmd:
			// && || | & — descend both sides.
			walkStmt(c.X)
			walkStmt(c.Y)
		case *syntax.Block:
			for _, s := range c.Stmts {
				walkStmt(s)
			}
		case *syntax.Subshell:
			for _, s := range c.Stmts {
				walkStmt(s)
			}
		case *syntax.IfClause:
			for _, s := range c.Cond {
				walkStmt(s)
			}
			for _, s := range c.Then {
				walkStmt(s)
			}
			if c.Else != nil {
				walkCmd(c.Else, nil)
			}
		case *syntax.ForClause:
			for _, s := range c.Do {
				walkStmt(s)
			}
		case *syntax.WhileClause:
			for _, s := range c.Cond {
				walkStmt(s)
			}
			for _, s := range c.Do {
				walkStmt(s)
			}
		case *syntax.CaseClause:
			for _, item := range c.Items {
				for _, s := range item.Stmts {
					walkStmt(s)
				}
			}
		case *syntax.FuncDecl:
			walkStmt(c.Body)
		case *syntax.ArithmCmd:
			// Pure arithmetic; no external command. Ignore.
		case *syntax.DeclClause, *syntax.LetClause, *syntax.TestClause,
			*syntax.TimeClause, *syntax.CoprocClause:
			// These either mutate only shell state or wrap a command we can't
			// statically reduce safely. Be fail-closed: signal unhandled.
			walkErr = fmt.Errorf("unhandled shell construct %T", c)
		default:
			walkErr = fmt.Errorf("unhandled shell construct %T", c)
		}
	}

	walkStmt = func(stmt *syntax.Stmt) {
		if walkErr != nil || stmt == nil {
			return
		}
		if stmt.Cmd != nil {
			walkCmd(stmt.Cmd, stmt.Redirs)
		}
	}

	for _, stmt := range file.Stmts {
		walkStmt(stmt)
	}
	if walkErr != nil {
		return nil, walkErr
	}
	return out, nil
}

// reduceCallExpr turns a single CallExpr into a simpleCommand. It expands
// each word to a literal where statically possible; words containing command
// substitution or unresolved parameter expansion mark hasUnknownExpansion.
// Leading `env VAR=val` wrappers and assignment prefixes are stripped so the
// real program lands at args[0] (§10: `env VAR=x <cmd>`).
func reduceCallExpr(c *syntax.CallExpr, redirs []*syntax.Redirect) (simpleCommand, error) {
	sc := simpleCommand{}

	// Detect redirections to real files (anything other than /dev/null).
	// Redirects live on the enclosing *syntax.Stmt, not the CallExpr.
	for _, r := range redirs {
		if r.Word == nil {
			continue
		}
		target, _ := literalWord(r.Word)
		switch r.Op {
		case syntax.RdrOut, syntax.AppOut, syntax.RdrAll, syntax.AppAll, syntax.ClbOut:
			if target != "/dev/null" {
				sc.hasRedirectToFile = true
			}
		}
	}

	for _, w := range c.Args {
		lit, exact := literalWord(w)
		if !exact {
			sc.hasUnknownExpansion = true
		}
		sc.args = append(sc.args, lit)
	}

	// Strip leading `env` wrapper and its VAR=val args (§10). Repeat in case
	// of `env A=1 env B=2 cmd` (unusual but harmless to handle).
	sc.args = stripEnvWrapper(sc.args)

	return sc, nil
}

// stripEnvWrapper removes a leading `env` and any leading VAR=val tokens so
// the actual program is at args[0]. `env -i`, `env -u VAR`, and `env --` are
// handled by skipping their option args.
func stripEnvWrapper(args []string) []string {
	for len(args) > 0 && args[0] == "env" {
		args = args[1:]
		// Skip env's own options and var assignments until the program token.
		for len(args) > 0 {
			a := args[0]
			switch {
			case a == "--":
				args = args[1:]
				goto doneEnvOpts
			case a == "-i" || a == "--ignore-environment":
				args = args[1:]
			case a == "-u" || a == "--unset":
				// consumes the next arg (a var name)
				args = args[1:]
				if len(args) > 0 {
					args = args[1:]
				}
			case strings.HasPrefix(a, "-"):
				args = args[1:]
			case isAssignment(a):
				args = args[1:]
			default:
				goto doneEnvOpts
			}
		}
	doneEnvOpts:
	}
	// Strip any remaining leading VAR=val assignment prefixes (e.g.
	// `FOO=bar cmd`); these set env for the command, not the program.
	for len(args) > 0 && isAssignment(args[0]) {
		args = args[1:]
	}
	return args
}

// isAssignment reports whether a token looks like NAME=value (a shell
// assignment), as opposed to a flag or a program name.
func isAssignment(tok string) bool {
	eq := strings.IndexByte(tok, '=')
	if eq <= 0 {
		return false
	}
	name := tok[:eq]
	for i, r := range name {
		if r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
			continue
		}
		if i > 0 && r >= '0' && r <= '9' {
			continue
		}
		return false
	}
	return true
}

// literalWord returns the static literal value of a word and whether it is
// EXACT (no command substitution, no unresolved parameter expansion). A word
// like `"foo"` or `'bar'` or `foo` is exact; `$(date)` or `$VAR` is not.
//
// expand.Literal with a no-op environment resolves quoting and tilde but
// returns an error / partial result for command substitutions, which we treat
// as inexact (#1: quoted strings with expansions are first-class, classified,
// not heuristically matched).
func literalWord(w *syntax.Word) (string, bool) {
	// Fast path: detect any part that is a command substitution or an
	// expansion we cannot statically resolve.
	exact := true
	for _, part := range w.Parts {
		switch p := part.(type) {
		case *syntax.Lit, *syntax.SglQuoted:
			// fully static
		case *syntax.DblQuoted:
			for _, dp := range p.Parts {
				switch dp.(type) {
				case *syntax.Lit:
				default:
					exact = false
				}
			}
		default:
			// ParamExp, CmdSubst, ArithmExp, ProcSubst, ExtGlob, etc.
			exact = false
		}
	}

	cfg := &expand.Config{
		Env: expand.FuncEnviron(func(string) string { return "" }),
		// No command substitution: leave the literal as-is and mark inexact.
		CmdSubst: func(io.Writer, *syntax.CmdSubst) error { return nil },
	}
	lit, err := expand.Literal(cfg, w)
	if err != nil {
		// Could not expand — fall back to the raw printed form and mark
		// inexact so the command cannot ride the allow track.
		return printWord(w), false
	}
	return lit, exact
}

// printWord prints a word back to source text (used only as the inexact
// fallback for messages / matching when expansion fails).
func printWord(w *syntax.Word) string {
	var sb strings.Builder
	_ = syntax.NewPrinter().Print(&sb, w)
	return sb.String()
}
