package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
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

	cmds, extractErr := extractSimpleCommands(file, ev.CWD)
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
	// hasInlineAssignment is true when the command carried an inline
	// environment-assignment prefix (`AWS_ENDPOINT_URL=… aws …`,
	// `GIT_SSH_COMMAND=… git …`, `GH_HOST=… gh …`). Such a prefix can redirect
	// egress, swap identity, or inject a pager without ever touching argv, so
	// the git/gh/aws classifiers DENY on it (issue #64 precondition). The
	// prefix is stripped from args[] by stripEnvWrapper so the real program is
	// at args[0]; this flag preserves the fact that it was present.
	hasInlineAssignment bool
	// cwd is the RUNNING working directory this command executes in, tracked
	// through any `cd <arg>` that appeared earlier in the same parsed program
	// (#129). Seeded from ev.CWD and updated left-to-right as the walk crosses a
	// statically-resolvable `cd`. Relative path operands on this command must be
	// resolved against cwd, not blindly against ev.CWD, so `cd <subdir> && cmd
	// ../x` resolves `../x` relative to <subdir> as bash actually would.
	cwd string
	// cwdInvalid is true when a DYNAMIC `cd` (an unresolvable target, or `cd -`)
	// appeared earlier in the program. cwd then holds only the last known-good
	// value and must not be trusted: any relative path operand on this command
	// cannot be safely resolved and must fail closed (treated as unknown), even
	// though absolute operands are unaffected.
	cwdInvalid bool
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
//
// seedCWD is the event's cwd (ev.CWD); it seeds the RUNNING cwd tracked
// through the walk (#129). The walk order is left-to-right / top-to-bottom for
// &&/||/;/newline-separated statements, which is exactly the order bash
// applies `cd` side effects, so a single running-cwd variable updated as the
// walk encounters each `cd` is faithful for the common `cd X && cmd` /
// `cd X; cmd` shapes. Each emitted simpleCommand is stamped with the running
// cwd (and its validity) AT THE POINT it is walked, so containment resolves
// relative operands against the cwd that was actually in effect for that
// command, not the process-wide event cwd.
func extractSimpleCommands(file *syntax.File, seedCWD string) ([]simpleCommand, error) {
	var out []simpleCommand
	var walkErr error

	// runningCWD / runningCWDInvalid track the shell's current directory as the
	// walk crosses `cd` statements (#129). runningCWDInvalid is set by a `cd`
	// whose target cannot be statically resolved (a command substitution, an
	// unresolved variable, or `cd -`) — after that point relative operands
	// cannot be safely resolved and must fail closed, so every later-emitted
	// simpleCommand in that scope carries cwdInvalid=true.
	runningCWD := seedCWD
	runningCWDInvalid := false

	// knownVars accumulates variables assigned to a STATIC literal value
	// (#60) earlier in the same parsed program, in walk order (which is
	// left-to-right / top-to-bottom for &&/||/;/newline-separated
	// statements). A later `cat "$P/x"` whose path is built only from such
	// variables can be resolved to a concrete literal and run through normal
	// containment, instead of failing closed on hasUnknownExpansion. A
	// variable assigned from a command substitution or any other unresolved
	// expansion is deliberately NOT recorded, so genuinely dynamic paths keep
	// escalating (fail-closed). Environment variables not assigned in the
	// program are absent from this map and so also remain unknown.
	knownVars := map[string]string{}

	// scopeDepth tracks how many nested SCOPED constructs the walk is currently
	// inside (#60 follow-up). In real bash an assignment made inside a `( … )`
	// subshell, a function body, or a backgrounded group/subshell runs in a
	// child shell and does NOT persist to the enclosing/program-global scope.
	// While scopeDepth > 0 we therefore DO NOT record assignments into
	// knownVars, so a scoped `P=/abs` cannot resolve a later top-level `$P`.
	// (Uses of an already-known top-level var inside a scope still resolve —
	// that direction is correct shell semantics.) The map is shared across the
	// whole walk, so the depth gate lives on the write side (recordAssign), not
	// the read side (literalWord).
	scopeDepth := 0

	var walkStmt func(stmt *syntax.Stmt)
	var walkCmd func(cmd syntax.Command, redirs []*syntax.Redirect)
	var walkDeclClause func(c *syntax.DeclClause)
	var descendCmdSubsts func(w *syntax.Word)
	var recordAssign func(a *syntax.Assign)
	var applyCd func(call *syntax.CallExpr)

	// recordAssign captures a single assignment into knownVars when its RHS is
	// a static literal. A plain `VAR=` (empty RHS) records the empty string. An
	// append (`VAR+=x`), an array assignment, an indexed assignment, or a
	// dynamic RHS (command substitution / unresolved parameter expansion) is
	// NOT recorded; to be safe we also DELETE any previously-known value for
	// the name, since after such an assignment the variable is no longer
	// statically known.
	recordAssign = func(a *syntax.Assign) {
		if a == nil || a.Name == nil {
			return
		}
		// Inside a subshell / function body / backgrounded group the assignment
		// is scoped to a child shell and must not leak into the program-global
		// knownVars (#60 follow-up). Skip recording entirely; we do NOT delete
		// an existing top-level value either, because the scoped assignment does
		// not actually overwrite the parent's variable in real bash.
		if scopeDepth > 0 {
			return
		}
		name := a.Name.Value
		// Forms we cannot statically resolve: append, array, or indexed
		// assignment. After any of these the prior known value is stale.
		if a.Append || a.Array != nil || a.Index != nil {
			delete(knownVars, name)
			return
		}
		if a.Value == nil {
			// `VAR=` — empty literal value.
			knownVars[name] = ""
			return
		}
		val, exact := literalWord(a.Value, knownVars)
		if !exact {
			// RHS is dynamic (e.g. `D=$(date)`, or built from an
			// unresolved variable). The variable is no longer statically
			// known — drop any stale value so a later use stays fail-closed.
			delete(knownVars, name)
			return
		}
		knownVars[name] = val
	}

	// applyCd updates the running cwd when a walked CallExpr is `cd <arg>`
	// (#129). It reuses stmtIsCdWithArg's detection shape (basename == "cd" with
	// at least one argument) inline, since that helper takes a *syntax.Stmt and
	// this is called from the CallExpr level.
	//
	// Inside a SCOPED construct (scopeDepth > 0 — a `( … )` subshell, a function
	// body, or a backgrounded group) the cd runs in a child shell and must not
	// persist to the enclosing/program-global cwd, mirroring recordAssign's
	// scope discipline exactly. We still return without touching runningCWD /
	// runningCWDInvalid in that case.
	//
	// A statically-resolvable target updates runningCWD (absolute replaces it,
	// relative joins onto it) and clears runningCWDInvalid — a later `cd` can
	// re-anchor cwd after an earlier dynamic one, since bash itself would.
	// `cd` with no argument goes to $HOME. `cd -` (previous directory) is not
	// worth tracking, so it invalidates like any other unresolvable target. A
	// target that is not statically resolvable (command substitution, unknown
	// variable) invalidates: later relative operands in this scope must fail
	// closed rather than resolve against a stale or guessed cwd.
	applyCd = func(call *syntax.CallExpr) {
		if len(call.Args) == 0 {
			return
		}
		prog, _ := literalWord(call.Args[0], knownVars)
		if basename(prog) != "cd" {
			return
		}
		if scopeDepth > 0 {
			return // scoped cd does not persist (mirrors recordAssign)
		}
		if len(call.Args) == 1 {
			// Bare `cd` (no argument) goes to $HOME.
			home, err := os.UserHomeDir()
			if err != nil || home == "" {
				runningCWDInvalid = true
				return
			}
			runningCWD = home
			runningCWDInvalid = false
			return
		}
		lit, exact := literalWord(call.Args[1], knownVars)
		if !exact || lit == "-" {
			// Dynamic target, or `cd -` (previous dir, not worth tracking):
			// invalidate so later relative operands in this scope fail closed.
			runningCWDInvalid = true
			return
		}
		if lit == "" {
			// `cd ""` is a no-op in bash (stays in the current directory).
			return
		}
		switch {
		case filepath.IsAbs(lit):
			runningCWD = lit
		case lit == "~" || strings.HasPrefix(lit, "~/"):
			home, err := os.UserHomeDir()
			if err != nil || home == "" {
				runningCWDInvalid = true
				return
			}
			if lit == "~" {
				runningCWD = home
			} else {
				runningCWD = filepath.Join(home, strings.TrimPrefix(lit, "~/"))
			}
		case runningCWDInvalid:
			// Cannot safely join a relative target onto an already-invalid cwd.
			return
		default:
			runningCWD = filepath.Join(runningCWD, lit)
		}
		runningCWDInvalid = false
	}

	// descendCmdSubsts finds every command substitution inside a word —
	// including a `$(cmd)` nested inside a double-quoted string
	// (`"$(cmd)"`) — and classifies the substituted command(s) by walking
	// their statements. A plain literal / parameter-expansion word has no
	// CmdSubst parts and contributes nothing.
	descendCmdSubsts = func(w *syntax.Word) {
		if w == nil {
			return
		}
		for _, part := range w.Parts {
			switch p := part.(type) {
			case *syntax.CmdSubst:
				for _, s := range p.Stmts {
					walkStmt(s)
				}
			case *syntax.DblQuoted:
				for _, dp := range p.Parts {
					if cs, ok := dp.(*syntax.CmdSubst); ok {
						for _, s := range cs.Stmts {
							walkStmt(s)
						}
					}
				}
			}
		}
	}

	// walkDeclClause walks every assignment of a declaration clause
	// (export/local/declare/readonly/typeset). It contributes no program for
	// the declaration itself (a literal/param-expansion RHS mutates only shell
	// state); it descends into any command substitution in an assignment RHS so
	// the inner command is classified by the normal pipeline.
	walkDeclClause = func(c *syntax.DeclClause) {
		for _, a := range c.Args {
			if a != nil {
				// Record a static `export VAR=literal` / `local VAR=literal`
				// so later uses can resolve it (#60), then descend into any
				// command substitution in the RHS so the inner command is
				// still classified.
				recordAssign(a)
				descendCmdSubsts(a.Value)
			}
		}
	}

	walkCmd = func(cmd syntax.Command, redirs []*syntax.Redirect) {
		if walkErr != nil {
			return
		}
		switch c := cmd.(type) {
		case *syntax.CallExpr:
			// A bare assignment-only CallExpr (`VAR=x` with no program)
			// mutates shell state and persists to later commands in the same
			// program, so record any static assignment for later resolution
			// (#60). A `VAR=x cmd` prefix (with a program) sets env for THAT
			// command only and does NOT persist, so its assigns are not
			// recorded here.
			if len(c.Args) == 0 {
				for _, a := range c.Assigns {
					recordAssign(a)
				}
			}
			sc, err := reduceCallExpr(c, redirs, knownVars)
			if err != nil {
				walkErr = err
				return
			}
			// Stamp the running cwd (and its validity) AT THE POINT this command
			// is walked (#129), BEFORE applying this call's own `cd` side effect
			// (a `cd`'s own arguments, if any, are resolved against the PRIOR
			// cwd, not the directory it is about to change into).
			sc.cwd = runningCWD
			sc.cwdInvalid = runningCWDInvalid
			// A bare assignment-only CallExpr (VAR=x with no program) yields
			// no args; skip it (it mutates only shell state).
			if len(sc.args) > 0 {
				out = append(out, sc)
			}
			// Apply this call's `cd` side effect (if any) so LATER commands in
			// the walk see the updated cwd.
			applyCd(c)
		case *syntax.BinaryCmd:
			// && || | & — descend both sides.
			walkStmt(c.X)
			walkStmt(c.Y)
		case *syntax.Block:
			for _, s := range c.Stmts {
				walkStmt(s)
			}
		case *syntax.Subshell:
			// A `( … )` subshell runs in a child shell; assignments inside it
			// do not persist to the enclosing scope (#60 follow-up). Bump the
			// scope depth so recordAssign skips them.
			scopeDepth++
			for _, s := range c.Stmts {
				walkStmt(s)
			}
			scopeDepth--
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
			// A `for x in <words>; do …; done` whose header is a fully static
			// item list (#131) makes the loop variable's entire value set
			// visible at parse time. When every item resolves to an exact
			// literal via literalWord, fan out: walk c.Do once per item with
			// the loop variable bound to that item's value, so body uses of
			// "$x" resolve instead of staying inexact / fail-closed. Every
			// item is walked — an escaping item later in the list is still
			// reported even if earlier items were safe.
			//
			// Anything else — no `in` clause (`for x; do …`, iterates "$@"),
			// or any dynamic item (`for f in $LIST`, a command substitution,
			// a glob like `*.md`) — cannot be reduced to a known value set, so
			// leave the existing conservative behavior: walk the body once
			// with the loop variable NOT bound, so "$x" stays inexact and
			// fails closed as before.
			if wi, ok := c.Loop.(*syntax.WordIter); ok && wi.InPos.IsValid() && wi.Name != nil {
				items, allStatic := staticForItems(wi, knownVars)
				if allStatic && len(items) <= maxForFanOut {
					loopVar := wi.Name.Value
					prevVal, hadPrev := knownVars[loopVar]
					for _, item := range items {
						knownVars[loopVar] = item
						for _, s := range c.Do {
							walkStmt(s)
						}
					}
					// Restore/remove the binding so it does not leak past the
					// loop or clobber an outer variable of the same name
					// (#131 scopeDepth discipline).
					if hadPrev {
						knownVars[loopVar] = prevVal
					} else {
						delete(knownVars, loopVar)
					}
					break
				}
				// Dynamic item(s), or the fan-out cap was exceeded: fall
				// through to the conservative unbound walk below.
			}
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
			// A function body is a separate scope: `local`/scoped vars and even
			// plain assignments inside it do not persist to the program-global
			// scope merely by the function being declared (#60 follow-up). Bump
			// the scope depth so recordAssign skips its assignments.
			scopeDepth++
			walkStmt(c.Body)
			scopeDepth--
		case *syntax.ArithmCmd:
			// Pure arithmetic; no external command. Ignore.
		case *syntax.LetClause:
			// `let x=1+2` — pure arithmetic, no external command. Ignore
			// (same as the ArithmCmd case). (#35 Fix 2)
		case *syntax.TestClause:
			// `[[ … ]]` — a builtin test; runs no external command. Ignore.
			// (#63, folded into #35 Fix 2)
		case *syntax.TimeClause:
			// `time cmd` — wraps a real command. Descend into the wrapped
			// statement and classify it. (#35 Fix 2)
			walkStmt(c.Stmt)
		case *syntax.CoprocClause:
			// `coproc cmd` — wraps a command in a coprocess. Descend into the
			// wrapped statement and classify it. (#35 Fix 2)
			walkStmt(c.Stmt)
		case *syntax.DeclClause:
			// `export`/`local`/`declare`/`readonly`/`typeset` — walk ALL of its
			// assignments (a single `export A=x B=y` carries multiple). A plain
			// literal/parameter-expansion RHS mutates only shell state, so it
			// contributes no program. When an assignment RHS contains a command
			// substitution (`local d=$(cmd)`, including the quoted `="$(cmd)"`
			// form), descend into the substituted command and classify it.
			// (#59, folded into #35 Fix 2)
			walkDeclClause(c)
		default:
			walkErr = fmt.Errorf("unhandled shell construct %T", c)
		}
	}

	walkStmt = func(stmt *syntax.Stmt) {
		if walkErr != nil || stmt == nil {
			return
		}
		if stmt.Cmd != nil {
			// A backgrounded statement (`cmd &`, `{ … ; } &`, `( … ) &`) runs in
			// a child shell, so any assignment it makes does not persist to the
			// enclosing scope (#60 follow-up). Bump the scope depth around the
			// descent so recordAssign skips those assignments. (A `( … )`
			// Subshell already bumps depth in walkCmd; the extra bump here for a
			// backgrounded subshell is harmless — depth is only ever tested for
			// > 0.)
			if stmt.Background {
				scopeDepth++
				walkCmd(stmt.Cmd, stmt.Redirs)
				scopeDepth--
				return
			}
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
func reduceCallExpr(c *syntax.CallExpr, redirs []*syntax.Redirect, knownVars map[string]string) (simpleCommand, error) {
	sc := simpleCommand{}

	// Detect redirections to real files (anything other than /dev/null).
	// Redirects live on the enclosing *syntax.Stmt, not the CallExpr.
	for _, r := range redirs {
		if r.Word == nil {
			continue
		}
		target, exact := literalWord(r.Word, knownVars)
		// A redirect target built from a command substitution, process
		// substitution, or unresolved expansion (e.g. `wc < <(grep x f)`,
		// `cmd > "$DYNAMIC"`) cannot be statically proven safe — an input
		// process substitution even spawns an unproven command. Such a command
		// must not ride the allow track (#1), so mark it as unknown-expansion.
		// This keeps the allow-aware classifiers (read-only utilities, git, gh,
		// …) from auto-allowing a command whose redirect introduces unprovable
		// behavior, even when its own arg words are all literal.
		if !exact {
			sc.hasUnknownExpansion = true
		}
		switch r.Op {
		case syntax.RdrOut, syntax.AppOut, syntax.RdrAll, syntax.AppAll, syntax.ClbOut:
			if target != "/dev/null" {
				sc.hasRedirectToFile = true
			}
		}
	}

	// An inline environment-assignment prefix on the CallExpr itself
	// (`AWS_ENDPOINT_URL=… aws …`, `GIT_SSH_COMMAND=… git …`) sets env for THIS
	// command only. The parser parks these on c.Assigns (separate from c.Args)
	// when a program token follows. Such a prefix can redirect egress, swap
	// identity, or inject a pager without ever touching argv, so the git/gh/aws
	// classifiers DENY on it (#64). Record its presence; a bare assignment-only
	// CallExpr (no program) has no Args and is handled as a shell-state mutation
	// elsewhere, so the program-bearing guard below is what matters here.
	if len(c.Assigns) > 0 && len(c.Args) > 0 {
		sc.hasInlineAssignment = true
	}

	for _, w := range c.Args {
		lit, exact := literalWord(w, knownVars)
		if !exact {
			sc.hasUnknownExpansion = true
		}
		sc.args = append(sc.args, lit)
	}

	// Strip leading `env` wrapper and its VAR=val args (§10). Repeat in case
	// of `env A=1 env B=2 cmd` (unusual but harmless to handle). The
	// `env VAR=val cmd` form parks the assignment in args (not c.Assigns), so
	// stripEnvWrapper reports whether it removed any assignment so the inline
	// flag is set for that form too.
	var strippedAssign bool
	sc.args, strippedAssign = stripEnvWrapper(sc.args)
	if strippedAssign {
		sc.hasInlineAssignment = true
	}

	return sc, nil
}

// stripEnvWrapper removes a leading `env` and any leading VAR=val tokens so
// the actual program is at args[0]. `env -i`, `env -u VAR`, and `env --` are
// handled by skipping their option args. It also reports whether any VAR=val
// assignment token was stripped, so the caller can flag the command as
// carrying an inline environment-assignment prefix (#64): the `env VAR=val cmd`
// form parks the assignment in args (not on the CallExpr's Assigns), so this is
// the only place that form is observed.
func stripEnvWrapper(args []string) (out []string, strippedAssign bool) {
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
				strippedAssign = true
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
		strippedAssign = true
		args = args[1:]
	}
	return args, strippedAssign
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
// like `"foo"` or `'bar'` or `foo` is exact; `$(date)` is not. A simple
// parameter expansion (`$VAR` / `${VAR}`) is exact ONLY when VAR is present in
// knownVars — i.e. it was assigned to a static literal earlier in the same
// parsed program (#60); otherwise it is inexact (fail-closed for env vars and
// dynamically-assigned vars).
//
// expand.Literal with the knownVars-backed environment resolves quoting,
// tilde, and resolvable parameter expansions but returns an error / partial
// result for command substitutions, which we treat as inexact (#1: quoted
// strings with expansions are first-class, classified, not heuristically
// matched).
func literalWord(w *syntax.Word, knownVars map[string]string) (string, bool) {
	// Fast path: detect any part that is a command substitution or an
	// expansion we cannot statically resolve. A simple `$VAR`/`${VAR}` whose
	// name is in knownVars is resolvable and does NOT make the word inexact.
	exact := true
	for _, part := range w.Parts {
		switch p := part.(type) {
		case *syntax.Lit, *syntax.SglQuoted:
			// fully static
		case *syntax.ParamExp:
			if !isResolvableParamExp(p, knownVars) {
				exact = false
			}
		case *syntax.DblQuoted:
			for _, dp := range p.Parts {
				switch dq := dp.(type) {
				case *syntax.Lit:
				case *syntax.ParamExp:
					if !isResolvableParamExp(dq, knownVars) {
						exact = false
					}
				default:
					exact = false
				}
			}
		default:
			// CmdSubst, ArithmExp, ProcSubst, ExtGlob, etc.
			exact = false
		}
	}

	cfg := &expand.Config{
		// Resolve a variable to its statically-known literal value when we
		// recorded one earlier in the program (#60); unknown names expand to
		// "" (as before) and the fast-path loop above has already marked the
		// word inexact, so such a command cannot ride the allow track and is
		// not run through containment as if resolved.
		Env: expand.FuncEnviron(func(name string) string {
			if v, ok := knownVars[name]; ok {
				return v
			}
			return ""
		}),
		// No command substitution: leave the literal as-is and mark inexact.
		CmdSubst: func(io.Writer, *syntax.CmdSubst) error { return nil },
		// Process substitution (`<(cmd)` / `>(cmd)`): expand.Literal calls
		// cfg.ProcSubst unconditionally when it hits a *syntax.ProcSubst part,
		// so leaving this nil panics with a nil-pointer deref (#5). The inner
		// command of a process substitution is not statically resolvable, so we
		// expand it to an empty string and rely on the fast-path loop above
		// having already marked the word inexact (ProcSubst hits the default
		// case there) — the command can never ride the allow track.
		ProcSubst: func(*syntax.ProcSubst) (string, error) { return "", nil },
	}
	lit, err := expand.Literal(cfg, w)
	if err != nil {
		// Could not expand — fall back to the raw printed form and mark
		// inexact so the command cannot ride the allow track.
		return printWord(w), false
	}
	return lit, exact
}

// maxForFanOut bounds how many items a static `for x in <words>` fan-out
// (#131) will expand. A pathologically long static item list would otherwise
// walk the loop body once per item; above this cap we fall back to the
// conservative unbound walk (fail-closed on body uses of the loop variable)
// rather than doing unbounded work.
const maxForFanOut = 64

// staticForItems reports the resolved literal value of every item word in a
// `for x in <words>` header, and whether ALL of them are exact (#131). A
// single dynamic item (command substitution, unresolved parameter expansion,
// a glob that requires runtime word-splitting/expansion) makes the whole
// list non-static, since the loop variable's value set is no longer fully
// known at parse time.
func staticForItems(wi *syntax.WordIter, knownVars map[string]string) ([]string, bool) {
	items := make([]string, 0, len(wi.Items))
	for _, w := range wi.Items {
		val, exact := literalWord(w, knownVars)
		if !exact {
			return nil, false
		}
		// A literal item containing a glob metacharacter (`*.md`, `file?.txt`,
		// `[abc]`) is exact as an AST literal — the shell parser does not
		// distinguish "looks like a glob" from a plain string, since matching
		// happens at runtime, not parse time — but its actual expansion
		// (zero, one, or many paths, entirely dependent on the CWD's
		// directory contents at the time bash runs it) is not statically
		// knowable here (#131). Treat it as non-static so the loop var is not
		// bound and the body keeps failing closed.
		if hasGlobMeta(val) {
			return nil, false
		}
		items = append(items, val)
	}
	return items, true
}

// hasGlobMeta reports whether s contains a shell glob metacharacter
// (`*`, `?`, `[`) that bash would expand via pathname expansion. Used only to
// keep a static `for x in <words>` fan-out (#131) conservative about items
// that merely LOOK like literals but actually depend on runtime directory
// contents; it is not a general-purpose literalWord change.
func hasGlobMeta(s string) bool {
	return strings.ContainsAny(s, "*?[")
}

// isResolvableParamExp reports whether a parameter expansion is a plain
// `$VAR` / `${VAR}` whose name was statically assigned earlier in the same
// program (present in knownVars). Anything with extra logic — default
// (`${VAR:-x}`), length (`${#VAR}`), indirection (`${!VAR}`), array index,
// slice, replacement, modifiers, or special parameters ($1, $@, $?) — is NOT
// resolvable here and keeps the word inexact (fail-closed). A name absent from
// knownVars (an env var, or a var assigned dynamically) is also not resolvable.
func isResolvableParamExp(p *syntax.ParamExp, knownVars map[string]string) bool {
	if p == nil || p.Param == nil {
		return false
	}
	// Reject every non-plain form. This mirrors the upstream (unexported)
	// ParamExp.simple() predicate; we replicate it because it is not exported.
	if p.Flags != nil || p.Excl || p.Length || p.Width || p.IsSet ||
		p.NestedParam != nil || p.Index != nil || len(p.Modifiers) > 0 ||
		p.Slice != nil || p.Repl != nil || p.Names != 0 || p.Exp != nil {
		return false
	}
	_, ok := knownVars[p.Param.Value]
	return ok
}

// printWord prints a word back to source text (used only as the inexact
// fallback for messages / matching when expansion fails).
func printWord(w *syntax.Word) string {
	var sb strings.Builder
	_ = syntax.NewPrinter().Print(&sb, w)
	return sb.String()
}
