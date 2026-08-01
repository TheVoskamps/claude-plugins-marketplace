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

// varResolver supplies the authoritative sources for the closed allowlist of
// process-environment-derived variables ($HOME, $USER, $TMPDIR) that #156
// widens literalWord/isResolvableParamExp to resolve when a name is absent
// from knownVars. $PWD and $OLDPWD are deliberately NOT resolved through this
// struct — they come from the per-command tracked cwd (simpleCommand.cwd /
// cwdInvalid and their oldCWD counterparts, threaded separately through
// reduceCallExpr), because the hook's process-env $PWD is the EVENT cwd and
// would be wrong after an in-script `cd` (see the "$PWD must NOT come from
// the process environment" note in issue #156).
//
// Fields are injectable funcs (mirroring PR #139's `homeDir` resolver for
// `~`) so the fail-closed branches (homeDir erroring/empty, a var absent from
// the process env) are deterministically testable rather than dependent on
// ambient environment.
type varResolver struct {
	// homeDir returns the process's home directory, or an error/empty string
	// when it cannot be determined. Authoritative for $HOME — the same source
	// applyCd's `cd ~` handling and claudeConfigRoot already use.
	homeDir func() (string, error)
	// lookupEnv returns the process-environment value of name and whether it
	// was set. Authoritative for $USER / $TMPDIR — variables that do not
	// change mid-script, so the hook's own env matches the command's.
	lookupEnv func(name string) (string, bool)
}

// defaultVarResolver returns a varResolver backed by the real OS: os.UserHomeDir
// for $HOME, os.LookupEnv for $USER/$TMPDIR.
func defaultVarResolver() varResolver {
	return varResolver{
		homeDir:   os.UserHomeDir,
		lookupEnv: os.LookupEnv,
	}
}

// envResolvableNames is the closed, explicit allowlist of variable names
// resolved via varResolver's process-environment source ($HOME, $USER,
// $TMPDIR). $PWD and $OLDPWD are handled separately (see varResolver's doc
// comment) because they need the per-command tracked cwd, not the process
// env. Any other env var (e.g. $FOO, $PATH) stays unresolvable — the gate
// must not resolve arbitrary environment state whose relationship to the
// command's environment is unverified.
var envResolvableNames = map[string]bool{
	"HOME":   true,
	"USER":   true,
	"TMPDIR": true,
}

// cwdResolvableNames is the closed allowlist of variable names resolved from
// the per-command tracked cwd rather than the process environment.
var cwdResolvableNames = map[string]bool{
	"PWD":    true,
	"OLDPWD": true,
}

// cwdCtx carries the per-command tracked-cwd state literalWord needs to
// resolve $PWD/$OLDPWD (#156): the running cwd and its validity (mirroring
// simpleCommand.cwd/cwdInvalid, #129) plus the PRIOR cwd and its validity
// (for $OLDPWD, recorded by applyCd on each `cd`). The zero value (all
// fields empty/invalid) makes $PWD/$OLDPWD fail closed, which is correct
// for any call site that has no tracked cwd to offer (e.g. a RHS assignment
// expansion evaluated before cwd tracking is meaningful).
type cwdCtx struct {
	cwd           string
	cwdInvalid    bool
	oldCWD        string
	oldCWDInvalid bool
}

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

	// Resolve the git context once, up front, so recordAssign can recognize
	// the #132 command-substitution anchors ($(git rev-parse
	// --show-toplevel), $(git rev-parse --git-common-dir)). A resolution
	// failure (not inside a git work tree, git missing, timeout) leaves rc
	// nil; every anchor-recognition call below treats a nil rc as "cannot
	// resolve this anchor" and keeps the existing fail-closed behavior — it
	// does NOT abort classification of the rest of the line.
	rc, _ := resolveRepoContext(ev.CWD)

	cmds, extractErr := extractSimpleCommands(file, ev.CWD, defaultVarResolver(), rc)
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
	// Every part earned BucketAllow. The reason must state the bar that bucket
	// actually holds (decision.go, BucketAllow) — POSITIVE GROUNDS, not
	// "provably read-only / non-mutating". That older wording was falsified by
	// the allow track's own write classifiers: `tee <scratchpad-file>` and an
	// in-worktree `cp` both reach here with BucketAllow while plainly mutating,
	// so the line claimed something the gate had not established. Restated
	// rather than deleted, because a reason surfaced to the model should say
	// why the call was blessed.
	return allow("every command part has positive grounds to be safe: the operation itself cannot write, " +
		"or its targets are confined to a region designated safe by construction (this worktree, or the " +
		"harness scratchpad)")
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
	// redirectTargets holds those real-file redirect destinations, verbatim, in
	// the order they appeared. They are NOT argv operands, so neither Engine B
	// operand walk (containPathOperands / containWriteOperands) ever sees them;
	// recording them is what lets redirectVetoesAllow grade the destination
	// instead of vetoing on the bare bool (#193). A `/dev/null` target is not
	// recorded — it does not set hasRedirectToFile either.
	redirectTargets []string
	// inputRedirectTargets holds the files an INPUT redirect opens for reading
	// (`cmd < f`, and the read half of `cmd <> f`), verbatim, in the order they
	// appeared. Deliberately a separate field from redirectTargets: a read is not
	// a write, and conflating the two would either wrongly veto reads (an input
	// redirect is not the exfiltration/clobber risk the write veto guards) or
	// wrongly permit writes (a read-eligible carve-out region is not
	// write-eligible). An input redirect reads a file WITHOUT that file ever
	// becoming an argv operand, so neither operand walk sees it either; recording
	// it is what lets the read tracks put it through the same containment that
	// grades their operands, so `cat < ../sibling-repo/.env` earns the same deny
	// as `cat ../sibling-repo/.env`. A `/dev/null` source is not recorded (it
	// discloses nothing, and containment would read it as an out-of-repo path).
	inputRedirectTargets []string
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
	// oldCWD / oldCWDInvalid are $OLDPWD's tracked source (#156): the running
	// cwd's value immediately BEFORE the most recent statically-resolvable
	// `cd` that preceded this command in the walk. Stamped alongside cwd at
	// the same point (before this call's own `cd` side effect, if any).
	// oldCWDInvalid is true when no `cd` has happened yet in this scope, or
	// the prior cwd was itself invalid — either way $OLDPWD must fail closed.
	oldCWD        string
	oldCWDInvalid bool
}

// allowEligible reports whether a command is eligible for the high-confidence
// ALLOW track. A command with a real-file redirect (exfiltration/clobber risk)
// or an unresolved expansion / command substitution (#1: cannot be proven
// safe statically) is NOT eligible and must defer to the normal pipeline
// instead of auto-allowing.
//
// Its redirect half is ABSOLUTE, which is why the two path-classifier allow
// tracks no longer call it: classifyReadOnlyUtility and classifyInRepoWrite
// ask redirectVetoesAllow instead, so a redirect whose every destination is a
// session-shaped harness scratchpad can still allow (#193), and they spell out
// the unknown-expansion half themselves. Calling this helper there would
// re-apply the ungraded veto and undo that. It remains the right gate for
// classifyAcli, whose concern is credentialed command output rather than where
// a scratch file lands.
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
//
// resolver supplies the authoritative sources for $HOME/$USER/$TMPDIR (#156);
// it is threaded down into every literalWord call the walk makes.
//
// rc is the resolved git context for the event's cwd (nil when resolution
// failed, e.g. not inside a work tree). recordAssign threads it into
// resolveAnchorCmdSubst (#132) so an assignment RHS that is EXACTLY
// `$(git rev-parse --show-toplevel)` / `$(git rev-parse --git-common-dir)`
// can be recorded as a known literal instead of always being dropped as an
// unresolvable command substitution.
func extractSimpleCommands(file *syntax.File, seedCWD string, resolver varResolver, rc *repoContext) ([]simpleCommand, error) {
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

	// runningOldCWD / runningOldCWDInvalid track $OLDPWD (#156): the value of
	// runningCWD immediately before the most recent statically-resolvable
	// `cd`. Starts invalid — before any `cd` has happened, $OLDPWD is not
	// tracked and must fail closed. applyCd updates these BEFORE it mutates
	// runningCWD, so they always hold the PRIOR value.
	runningOldCWD := ""
	runningOldCWDInvalid := true

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
		// The RHS of an assignment is resolved with the SAME cwdCtx/resolver
		// as any other word — a static `P=$PWD/sub` should resolve $PWD from
		// the running cwd just like a direct use would.
		cc := cwdCtx{cwd: runningCWD, cwdInvalid: runningCWDInvalid, oldCWD: runningOldCWD, oldCWDInvalid: runningOldCWDInvalid}
		val, exact := literalWord(a.Value, knownVars, resolver, cc)
		if !exact {
			// #132: before giving up on a dynamic RHS, check whether it is
			// EXACTLY one of the allowlisted anchor command substitutions
			// ($(git rev-parse --show-toplevel), $(git rev-parse
			// --git-common-dir), $(pwd)/`pwd`). Those substitutions' output is
			// a known, resolvable filesystem location, so recording it lets a
			// later use of the variable run through normal containment
			// instead of failing closed. Anything else (a compound
			// substitution, a non-allowlisted command, a substitution
			// embedded alongside other word parts) is NOT an anchor and falls
			// through to the existing drop-and-delete behavior.
			if anchor, ok := resolveAnchorCmdSubst(a.Value, rc, runningCWD, runningCWDInvalid); ok {
				knownVars[name] = anchor
				return
			}
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
	//
	// Before mutating runningCWD, it records the PRIOR value into
	// runningOldCWD/runningOldCWDInvalid (#156, $OLDPWD's source) — mirroring
	// real bash, which sets $OLDPWD to the directory `cd` is leaving. Every
	// exit path that goes on to change (or invalidate) runningCWD does this
	// capture first, including the invalidating paths: bash still updates
	// $OLDPWD on a `cd` whose target turns out to be unusable in ways we
	// cannot statically distinguish, so treating the pre-cd cwd as the new
	// $OLDPWD source (rather than leaving the OLDER $OLDPWD in place) is the
	// conservative, fail-closed-compatible choice.
	applyCd = func(call *syntax.CallExpr) {
		if len(call.Args) == 0 {
			return
		}
		cc := cwdCtx{cwd: runningCWD, cwdInvalid: runningCWDInvalid, oldCWD: runningOldCWD, oldCWDInvalid: runningOldCWDInvalid}
		prog, _ := literalWord(call.Args[0], knownVars, resolver, cc)
		if basename(prog) != "cd" {
			return
		}
		if scopeDepth > 0 {
			return // scoped cd does not persist (mirrors recordAssign)
		}
		if len(call.Args) == 1 {
			// Bare `cd` (no argument) goes to $HOME.
			runningOldCWD, runningOldCWDInvalid = runningCWD, runningCWDInvalid
			home, err := resolver.homeDir()
			if err != nil || home == "" {
				runningCWDInvalid = true
				return
			}
			runningCWD = home
			runningCWDInvalid = false
			return
		}
		lit, exact := literalWord(call.Args[1], knownVars, resolver, cc)
		if !exact || lit == "-" {
			// Dynamic target, or `cd -` (previous dir, not worth tracking):
			// invalidate so later relative operands in this scope fail closed.
			runningOldCWD, runningOldCWDInvalid = runningCWD, runningCWDInvalid
			runningCWDInvalid = true
			return
		}
		if lit == "" {
			// `cd ""` is a no-op in bash (stays in the current directory) —
			// $OLDPWD is not updated by a no-op.
			return
		}
		runningOldCWD, runningOldCWDInvalid = runningCWD, runningCWDInvalid
		switch {
		case filepath.IsAbs(lit):
			runningCWD = lit
		case lit == "~" || strings.HasPrefix(lit, "~/"):
			home, err := resolver.homeDir()
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
			// Stamp the running cwd (and its validity) AT THE POINT this command
			// is walked (#129/#156), BEFORE applying this call's own `cd` side
			// effect (a `cd`'s own arguments, if any, are resolved against the
			// PRIOR cwd, not the directory it is about to change into).
			cc := cwdCtx{cwd: runningCWD, cwdInvalid: runningCWDInvalid, oldCWD: runningOldCWD, oldCWDInvalid: runningOldCWDInvalid}
			sc, err := reduceCallExpr(c, redirs, knownVars, resolver, cc)
			if err != nil {
				walkErr = err
				return
			}
			sc.cwd = runningCWD
			sc.cwdInvalid = runningCWDInvalid
			sc.oldCWD = runningOldCWD
			sc.oldCWDInvalid = runningOldCWDInvalid
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
			// literal (directly, via brace expansion, via a known-variable
			// expansion, or via a glob's containment-relevant directory
			// prefix — see staticForItems), fan out: walk c.Do once per item
			// with the loop variable bound to that item's value, so body uses
			// of "$x" resolve instead of staying inexact / fail-closed. Every
			// item is walked — an escaping item later in the list is still
			// reported even if earlier items were safe.
			//
			// Anything else — no `in` clause (`for x; do …`, iterates "$@"),
			// or any irreducibly dynamic item (`for f in $UNKNOWN`, a command
			// substitution, a glob while the running cwd is invalid) — cannot
			// be reduced to a known value set, so leave the existing
			// conservative behavior: walk the body once with the loop
			// variable NOT bound, so "$x" stays inexact and fails closed as
			// before.
			if wi, ok := c.Loop.(*syntax.WordIter); ok && wi.InPos.IsValid() && wi.Name != nil {
				cc := cwdCtx{cwd: runningCWD, cwdInvalid: runningCWDInvalid, oldCWD: runningOldCWD, oldCWDInvalid: runningOldCWDInvalid}
				items, allStatic := staticForItems(wi, knownVars, runningCWDInvalid, resolver, cc)
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
//
// resolver and cc thread the #156 var-resolution sources (process env for
// $HOME/$USER/$TMPDIR, the tracked cwd for $PWD/$OLDPWD) into every
// literalWord call this reduction makes.
func reduceCallExpr(c *syntax.CallExpr, redirs []*syntax.Redirect, knownVars map[string]string, resolver varResolver, cc cwdCtx) (simpleCommand, error) {
	sc := simpleCommand{}

	// Detect redirections to real files (anything other than /dev/null).
	// Redirects live on the enclosing *syntax.Stmt, not the CallExpr.
	for _, r := range redirs {
		if r.Word == nil {
			continue
		}
		target, exact := literalWord(r.Word, knownVars, resolver, cc)
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
				// Record the destination so a classifier can GRADE it (#193)
				// rather than only knowing that some redirect exists. A
				// non-exact target is recorded too, so a caller that walks the
				// list still sees every destination; it can never widen
				// anything, because !exact has already set hasUnknownExpansion
				// and redirectVetoesAllow refuses to lift on that.
				sc.redirectTargets = append(sc.redirectTargets, target)
			}
		case syntax.RdrIn:
			// `cmd < f` READS f, and f never becomes an argv operand, so without
			// this the operand walk has nothing to contain and a read-only
			// utility allows the line outright — `cat < /etc/passwd` reached the
			// classifier with ZERO operands. Recorded on the read side only: it
			// sets no write flag, because an input redirect writes nothing.
			if target != "/dev/null" {
				sc.inputRedirectTargets = append(sc.inputRedirectTargets, target)
			}
		case syntax.RdrInOut:
			// `cmd <> f` opens f for reading and writing on the same fd. Its READ
			// half is the same disclosure `<` is, so the target is graded here
			// exactly like an input redirect. It deliberately does NOT set
			// hasRedirectToFile: that flag is checked BEFORE containment on the
			// allow tracks, so setting it would replace this read's DENY with the
			// veto's defer — strictly worse than the pre-#193 status quo, in which
			// `<>` was ungraded on both axes. Its write half stays where it
			// already was: unmodelled, and unreachable without a further
			// fd-duplication redirect (`>&0`) the gate does not model either.
			if target != "/dev/null" {
				sc.inputRedirectTargets = append(sc.inputRedirectTargets, target)
			}
		}
		// Heredocs and herestrings (`<<`, `<<-`, `<<<`) are deliberately absent:
		// their word is inline text (or a delimiter), not a file the command
		// reads, so grading it as a path would deny ordinary `cat <<EOF` scripts.
		// Descriptor duplications (`<&`, `>&`) name a descriptor, not a file.
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
		lit, exact := literalWord(w, knownVars, resolver, cc)
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

// resolveVar resolves a bare variable name to its value and whether
// resolution succeeded, applying the #156 precedence: an in-script static
// assignment (knownVars) always wins over any environment/engine-derived
// source, so `HOME=/tmp cat "$HOME/x"` resolves $HOME to /tmp, not the
// process env. Only when the name is ABSENT from knownVars does resolution
// fall through to the closed allowlists:
//
//   - cwdResolvableNames ($PWD, $OLDPWD): resolved from the tracked cwd (cc),
//     never the process env — the hook's own $PWD is the EVENT cwd, which
//     diverges from the shell's actual $PWD after an in-script `cd`.
//   - envResolvableNames ($HOME, $USER, $TMPDIR): resolved from the
//     resolver's injectable sources (os.UserHomeDir / os.LookupEnv by
//     default).
//
// Any other name (not in knownVars, not in either allowlist) fails to
// resolve — the gate must not resolve arbitrary environment state.
func resolveVar(name string, knownVars map[string]string, resolver varResolver, cc cwdCtx) (string, bool) {
	if v, ok := knownVars[name]; ok {
		return v, true
	}
	if cwdResolvableNames[name] {
		switch name {
		case "PWD":
			if cc.cwdInvalid || cc.cwd == "" {
				return "", false
			}
			return cc.cwd, true
		case "OLDPWD":
			if cc.oldCWDInvalid || cc.oldCWD == "" {
				return "", false
			}
			return cc.oldCWD, true
		}
	}
	if envResolvableNames[name] {
		switch name {
		case "HOME":
			home, err := resolver.homeDir()
			if err != nil || home == "" {
				return "", false
			}
			return home, true
		case "USER", "TMPDIR":
			v, ok := resolver.lookupEnv(name)
			if !ok || v == "" {
				return "", false
			}
			return v, true
		}
	}
	return "", false
}

// anchorCommand describes one allowlisted command substitution whose output
// is a known, resolvable filesystem location (#132). match reports whether
// args (the substituted command's argv, program name included) is EXACTLY
// this anchor's recognized form — no extra flags, no extra arguments.
// resolve computes the anchor's value from the current repoContext / tracked
// cwd; it returns ok=false when the needed source is unavailable (e.g. rc is
// nil, or rc.commonDir is empty), which keeps the caller fail-closed rather
// than guessing.
type anchorCommand struct {
	match   func(args []string) bool
	resolve func(rc *repoContext, runningCWD string, runningCWDInvalid bool) (string, bool)
}

// anchorCommands is the closed, explicit allowlist of command substitutions
// resolveAnchorCmdSubst recognizes (#132). Matching is exact: the substituted
// command's argv must equal one of these forms precisely, with no additional
// arguments or flags — anything else is not an anchor and stays unresolved
// (fail-closed), preserving the conservative default for arbitrary
// substitutions.
var anchorCommands = []anchorCommand{
	{
		// $(git rev-parse --show-toplevel) → this worktree's root. A path
		// built on it is contained by construction — the safest possible
		// anchor.
		match: func(args []string) bool {
			return len(args) == 3 && args[0] == "git" && args[1] == "rev-parse" && args[2] == "--show-toplevel"
		},
		resolve: func(rc *repoContext, _ string, _ bool) (string, bool) {
			if rc == nil || rc.topLevel == "" {
				return "", false
			}
			return rc.topLevel, true
		},
	},
	{
		// $(git rev-parse --git-common-dir) → the shared git dir. A path
		// anchored here lands under .git/ and is subject to the isUnderGitDir
		// deny once resolved — resolving it makes that deny deterministic
		// instead of a fail-closed ASK. It is NOT treated as a
		// writable/contained anchor.
		match: func(args []string) bool {
			return len(args) == 3 && args[0] == "git" && args[1] == "rev-parse" && args[2] == "--git-common-dir"
		},
		resolve: func(rc *repoContext, _ string, _ bool) (string, bool) {
			if rc == nil || rc.commonDir == "" {
				return "", false
			}
			return rc.commonDir, true
		},
	},
	{
		// $(pwd) / `pwd` (bare, no arguments) → the CD-TRACKED running cwd
		// (#129's runningCWD), NOT ev.CWD — a preceding `cd` changes what a
		// real `pwd` would print. An invalid tracked cwd (a prior dynamic
		// `cd`) keeps this unresolved.
		match: func(args []string) bool {
			return len(args) == 1 && args[0] == "pwd"
		},
		resolve: func(_ *repoContext, runningCWD string, runningCWDInvalid bool) (string, bool) {
			if runningCWDInvalid || runningCWD == "" {
				return "", false
			}
			return runningCWD, true
		},
	},
}

// resolveAnchorCmdSubst reports whether word is EXACTLY a single command
// substitution matching one of anchorCommands, and if so, its resolved value
// (#132). "Exactly" means: the word has one part, that part is a *CmdSubst,
// its substituted program is a SINGLE statement (no `;`/`&&`/pipeline inside
// the substitution), and that statement is a plain CallExpr with no
// assignments/redirects whose argv matches an anchor form precisely. Any
// other shape (a word with additional literal/expansion parts around the
// substitution, a compound substitution, a non-allowlisted command) is not
// recognized and returns ok=false, so the caller falls back to its existing
// fail-closed behavior.
func resolveAnchorCmdSubst(word *syntax.Word, rc *repoContext, runningCWD string, runningCWDInvalid bool) (string, bool) {
	if word == nil || len(word.Parts) != 1 {
		return "", false
	}
	cs, ok := word.Parts[0].(*syntax.CmdSubst)
	if !ok || len(cs.Stmts) != 1 {
		return "", false
	}
	stmt := cs.Stmts[0]
	// Reject anything beyond a plain command: a background marker, redirects,
	// or (implicitly, since we only accept a *CallExpr below) any other
	// command construct.
	if stmt.Background || stmt.Negated || len(stmt.Redirs) > 0 {
		return "", false
	}
	call, ok := stmt.Cmd.(*syntax.CallExpr)
	if !ok || len(call.Assigns) > 0 {
		return "", false
	}
	args := make([]string, 0, len(call.Args))
	for _, w := range call.Args {
		lit, exact := literalWord(w, nil, varResolver{}, cwdCtx{})
		if !exact {
			return "", false
		}
		args = append(args, lit)
	}
	for _, anchor := range anchorCommands {
		if anchor.match(args) {
			return anchor.resolve(rc, runningCWD, runningCWDInvalid)
		}
	}
	return "", false
}

// literalWord returns the static literal value of a word and whether it is
// EXACT (no command substitution, no unresolved parameter expansion). A word
// like `"foo"` or `'bar'` or `foo` is exact; `$(date)` is not. A simple
// parameter expansion (`$VAR` / `${VAR}`) is exact when VAR is present in
// knownVars — i.e. it was assigned to a static literal earlier in the same
// parsed program (#60) — OR when VAR is one of the closed allowlist of names
// (#156: $HOME, $USER, $TMPDIR, $PWD, $OLDPWD) resolveVar can resolve from
// its authoritative source; otherwise it is inexact (fail-closed for every
// other env var and for dynamically-assigned vars).
//
// expand.Literal with the resolveVar-backed environment resolves quoting,
// tilde, and resolvable parameter expansions but returns an error / partial
// result for command substitutions, which we treat as inexact (#1: quoted
// strings with expansions are first-class, classified, not heuristically
// matched).
func literalWord(w *syntax.Word, knownVars map[string]string, resolver varResolver, cc cwdCtx) (string, bool) {
	// Fast path: detect any part that is a command substitution or an
	// expansion we cannot statically resolve. A simple `$VAR`/`${VAR}` that
	// isResolvableParamExp accepts is resolvable and does NOT make the word
	// inexact.
	exact := true
	for _, part := range w.Parts {
		switch p := part.(type) {
		case *syntax.Lit, *syntax.SglQuoted:
			// fully static
		case *syntax.ParamExp:
			if !isResolvableParamExp(p, knownVars, resolver, cc) {
				exact = false
			}
		case *syntax.DblQuoted:
			for _, dp := range p.Parts {
				switch dq := dp.(type) {
				case *syntax.Lit:
				case *syntax.ParamExp:
					if !isResolvableParamExp(dq, knownVars, resolver, cc) {
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
		// recorded one earlier in the program (#60), or to its
		// authoritative-source value for the closed #156 allowlist; unknown
		// names expand to "" (as before) and the fast-path loop above has
		// already marked the word inexact, so such a command cannot ride the
		// allow track and is not run through containment as if resolved.
		Env: expand.FuncEnviron(func(name string) string {
			v, _ := resolveVar(name, knownVars, resolver, cc)
			return v
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
// `for x in <words>` header, and whether ALL of them are exact (#131). It
// expands every statically-knowable form — brace expansion, a bare
// known-variable word (split on IFS the way bash word-splits an unquoted
// expansion), and a glob's containment-relevant directory prefix — and fans
// out to the cross product of item words. A single irreducibly dynamic item
// (command substitution, an unresolved parameter expansion, or a relative
// glob while cwdInvalid) makes the WHOLE list non-static, since the loop
// variable's value set is no longer fully known at parse time.
//
// cwdInvalid is whether the running cwd tracked through the walk (#129) is
// currently invalid; used to fail closed on a relative glob item (case 3,
// see globDirPrefix) that cannot be safely anchored. The resolved directory
// prefix itself is left relative and resolved later, at containment time,
// against the command's own tracked cwd (globDirPrefix's doc comment).
func staticForItems(wi *syntax.WordIter, knownVars map[string]string, cwdInvalid bool, resolver varResolver, cc cwdCtx) ([]string, bool) {
	items := make([]string, 0, len(wi.Items))
	for _, w := range wi.Items {
		expanded, ok := staticExpandItem(w, knownVars, cwdInvalid, resolver, cc)
		if !ok {
			return nil, false
		}
		items = append(items, expanded...)
	}
	return items, true
}

// staticExpandItem resolves ONE `for … in` item word to zero or more
// concrete literal values (#131). It handles, in order:
//
//  1. Brace expansion (`{a,b}.md`, `{a,b}$X.md`) via the upstream
//     syntax.SplitBraces + expand.Braces pair, which performs the
//     cross-product fan-out itself. mvdan.cc/sh does NOT pre-expand braces
//     during parsing (that is correct upstream behavior — matching happens
//     at expansion time, not parse time), so this step is required even for
//     the simplest `{a,b}` case.
//  2. A bare unquoted known-variable word (`$LIST` / `${LIST}`, no other
//     word parts): resolved from knownVars, then split on the default IFS
//     the way bash word-splits an unquoted expansion. A quoted `"$LIST"` is
//     a single DblQuoted word part, not a bare ParamExp, so it is NOT
//     word-split here — that already resolves correctly as a single literal
//     via literalWord/case 3 below, matching bash's no-split-when-quoted
//     semantics.
//  3. Every other resolved sub-word: literalWord — a straight literal, or a
//     glob against the tracked running cwd (globDirPrefix), or (if none of
//     the above apply) irreducibly dynamic → fail closed.
//
// mvdan.cc/sh's own syntax.SplitBraces declines to split any brace element
// containing "..", as a guard against ambiguity with the `{x..y}` sequence
// form. Real bash has no such hesitation: `{a,../../../etc/passwd}` splits
// cleanly into "a" and "../../../etc/passwd" (verified live:
// `bash -c 'for f in {a,../../../etc/passwd}; do echo "$f"; done'`).
// Empirically, upstream's decline is not merely "leave literal braces in the
// text" — for 3+-member lists it can silently DROP members instead
// (`{a,b,../c}` expands to only "a","b", quietly losing "../c"; see
// staticExpandBraceFallback's doc comment for the full probe). A silent drop
// is worse than a residual `{}`: it would let the fan-out walk the body over
// an incomplete item set, an ALLOW-shaped false negative. So whenever a
// sub-word's resolved text still contains "{"/"}" (declined, residual
// braces) OR the raw pre-split word contains a ".."-bearing top-level
// brace-comma-list (declined, silently short — the residual check alone
// would miss this), staticExpandBraceFallback below does the comma-list
// split itself, so every member (including the escaping one) still flows
// through the existing containment pipeline and gets worst-wins DENY/ASK
// rather than being silently dropped or bulk-ASKed. staticExpandBraceFallback
// only understands the single unnested `{x,y,z}` comma-list grammar; a
// range form (`{1..9}`, `{a..z}`) it does not recognize is left to fail
// closed exactly as before — the issue's carve-out ("if you hit a range
// form you don't handle, fall closed").
func staticExpandItem(w *syntax.Word, knownVars map[string]string, cwdInvalid bool, resolver varResolver, cc cwdCtx) ([]string, bool) {
	// Bare unquoted known-variable word: exactly one ParamExp part, no braces.
	// Must be checked BEFORE brace-splitting/literalWord so its IFS-split
	// semantics (case 2) are not shadowed by literalWord's own $VAR
	// resolution (which would return the whole unsplit value as one item).
	if len(w.Parts) == 1 {
		if p, ok := w.Parts[0].(*syntax.ParamExp); ok && isResolvableParamExp(p, knownVars, resolver, cc) {
			val, _ := resolveVar(p.Param.Value, knownVars, resolver, cc)
			return expand.ReadFields(&expand.Config{}, val, -1, true), true
		}
	}

	// Capture the raw, pre-mutation printed form for the dotdot-comma-list
	// cross-check below; SplitBraces mutates w's Parts in place.
	raw := printWord(w)

	syntax.SplitBraces(w)
	subWords := expand.Braces(w)

	declined := false
	items := make([]string, 0, len(subWords))
	for _, sw := range subWords {
		val, exact := literalWord(sw, knownVars, resolver, cc)
		if !exact {
			return nil, false
		}
		if strings.ContainsAny(val, "{}") {
			// A brace that syntax.SplitBraces declined to split leaves
			// literal brace syntax in the resolved text — the clean signal
			// that upstream punted on this word.
			declined = true
			break
		}
		items = append(items, val)
	}

	// Even when no residual "{"/"}" survived, upstream can still have
	// silently dropped a ".."-bearing member (the 3+-element case above).
	// Cross-check independently of subWords' shape: if the raw word (before
	// SplitBraces ran) contains a ".."-bearing top-level brace-comma-list,
	// never trust the count/content upstream returned — always resolve via
	// our own splitter for this item, whether upstream declined outright or
	// quietly under-counted.
	if !declined && hasDotDotBraceMember(raw) {
		declined = true
	}

	if declined {
		fallbackItems, ok := staticExpandBraceFallback(raw, cwdInvalid)
		if !ok {
			// Not a form our narrow fallback splitter understands (nested
			// braces, a range form, multiple brace groups, malformed
			// syntax, …) — fail closed rather than guess.
			return nil, false
		}
		return fallbackItems, true
	}

	final := make([]string, 0, len(items))
	for _, val := range items {
		if hasGlobMeta(val) {
			dir, ok := globDirPrefix(val, cwdInvalid)
			if !ok {
				return nil, false
			}
			final = append(final, dir)
			continue
		}
		final = append(final, val)
	}
	return final, true
}

// hasDotDotBraceMember reports whether raw contains a top-level (unnested)
// brace-comma-list `{...,...}` with at least one comma-separated member
// containing "..". This is a cheap textual pre-check used purely to decide
// whether to distrust upstream's expand.Braces output shape (#131 follow-up)
// — it does not itself resolve anything. A false positive here just means
// staticExpandBraceFallback gets consulted and, if the form is anything more
// exotic than a single unnested comma-list, correctly declines (fail closed).
func hasDotDotBraceMember(raw string) bool {
	start := strings.IndexByte(raw, '{')
	if start < 0 {
		return false
	}
	depth := 0
	memberHasDotDot := false
	sawComma := false
	for i := start; i < len(raw); i++ {
		switch raw[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				if sawComma && memberHasDotDot {
					return true
				}
				// Continue scanning past this closed group in case a LATER
				// top-level group in the same word is the dotdot offender
				// (e.g. literal text between two separate brace groups).
				memberHasDotDot = false
				sawComma = false
			}
		case ',':
			if depth == 1 {
				sawComma = true
			}
		case '.':
			if depth >= 1 && i+1 < len(raw) && raw[i+1] == '.' {
				memberHasDotDot = true
			}
		}
	}
	return false
}

// staticExpandBraceFallback splits ONE `for … in` item's raw printed text
// when upstream's syntax.SplitBraces/expand.Braces declined (or, worse,
// silently under-counted — see staticExpandItem's doc comment) on a
// ".."-bearing member. It handles exactly the single, unnested comma-list
// grammar `<prefix>{a,b,c}<suffix>`, matching bash's actual comma-list
// brace-expansion semantics for that shape (verified live: `bash -c 'for f
// in {a,../b,c}; do echo "$f"; done'` prints all three members unchanged).
// It deliberately does NOT attempt: a range form (`{1..9}`, `{a..z}` — ok is
// false, e.g. because the sole group's members don't contain a comma, so
// depth-1 commaCount stays 0), nested braces (`{a,{b,c}}` — ok is false
// because a nested "{" is found at depth 1), or more than one top-level
// brace group in the same word. Any of those returns ok=false so the caller
// fails closed to ASK rather than guess at bash's grammar.
//
// $VAR / other non-literal word parts around the brace group (e.g.
// `{a,../b}$X.md`) are not visible in raw's flat text once mutated by
// SplitBraces, so this fallback is only invoked on the word's raw
// PRE-mutation text captured in staticExpandItem — meaning a brace group
// combined with an adjacent $VAR is out of scope for this fallback and
// naturally falls to ok=false (the raw text still contains the unresolved
// "$X" token, which literalWord would already have marked inexact on the
// upstream path; this fallback does not re-resolve variables at all, it
// only pattern-matches a pure-literal comma-list). In practice this means:
// when a ".."-bearing brace group is combined with a variable, the whole
// item fails closed — a narrower guarantee than the brace-only case,
// but consistent with the "fall back to fail-closed on forms you don't
// handle" carve-out.
func staticExpandBraceFallback(raw string, cwdInvalid bool) ([]string, bool) {
	start := strings.IndexByte(raw, '{')
	if start < 0 {
		return nil, false
	}
	end := -1
	depth := 0
	for i := start; i < len(raw); i++ {
		switch raw[i] {
		case '{':
			depth++
			if depth > 1 {
				// Nested brace group — not this fallback's grammar.
				return nil, false
			}
		case '}':
			depth--
			if depth == 0 {
				end = i
			}
		}
		if end >= 0 {
			break
		}
	}
	if end < 0 {
		return nil, false
	}
	// Reject a second top-level brace group in the same word (e.g.
	// `{a,../b}{c,d}`) — out of scope for this narrow fallback.
	if strings.IndexByte(raw[end+1:], '{') >= 0 {
		return nil, false
	}

	prefix := raw[:start]
	body := raw[start+1 : end]
	suffix := raw[end+1:]

	members := strings.Split(body, ",")
	if len(members) < 2 {
		// No comma at the top level: either a range form (`{1..9}`) or a
		// malformed/degenerate group. Not this fallback's grammar.
		return nil, false
	}
	for _, m := range members {
		if strings.ContainsAny(m, "{}") {
			// Shouldn't happen given the depth check above, but guard
			// defensively rather than emit a bogus literal.
			return nil, false
		}
	}

	// unescape undoes the minimal escaping the printer/parser round trip can
	// leave on a Lit's Value for characters that are syntactically
	// significant to the shell (a literal comma or brace inside a brace
	// group must itself have been escaped in the source for SplitBraces to
	// have treated this as a group boundary at all); at this narrow scope
	// (pure-literal comma-list) a backslash immediately before a shell
	// metacharacter is the only escape form that can appear.
	unescape := func(s string) string {
		return strings.NewReplacer(`\{`, "{", `\}`, "}", `\,`, ",").Replace(s)
	}

	items := make([]string, 0, len(members))
	for _, m := range members {
		val := unescape(prefix) + unescape(m) + unescape(suffix)
		if hasGlobMeta(val) {
			dir, ok := globDirPrefix(val, cwdInvalid)
			if !ok {
				return nil, false
			}
			items = append(items, dir)
			continue
		}
		items = append(items, val)
	}
	return items, true
}

// hasGlobMeta reports whether s contains a shell glob metacharacter
// (`*`, `?`, `[`) that bash would expand via pathname expansion. Used to
// detect a static `for x in <words>` item (#131) that merely LOOKS like a
// literal but actually depends on runtime directory contents; it is not a
// general-purpose literalWord change.
func hasGlobMeta(s string) bool {
	return strings.ContainsAny(s, "*?[")
}

// globDirPrefix resolves a glob pattern's containment-relevant directory
// prefix (#131 case 3), without reading the filesystem. Containment is pure
// path arithmetic: every path a glob like `*.md` or `src/*.go` can possibly
// match is a child of the pattern's directory prefix (the portion before the
// first path segment that itself contains a glob metacharacter), so binding
// the loop variable to that prefix directory makes every possible match
// share the prefix's own containment verdict — whichever containmentResult it
// earns — via the existing pathUnder equal-or-nested check.
//
// The #193 scratchpad carve-out is the one verdict that is not purely
// pathUnder: inside <system-tmp>/claude-<uid> the verdict also depends on
// whether the remainder matches the per-session shape. It cannot fail open
// here, because the shape is closed under descent — a remainder that matches
// keeps matching with more segments appended, so a session-shaped prefix
// implies session-shaped matches, while a prefix that stops short of a session
// directory earns the more conservative unshaped-remainder region (never the
// carve-out ALLOW its matches might individually have earned).
//
// The returned prefix is deliberately left
// relative (e.g. ".", "src", ".."): the caller feeds it through knownVars
// into the loop body, and the EXISTING containment pipeline
// (containPathOperands -> testContainmentFrom) already resolves a relative
// operand against the command's own tracked running cwd (#129, sc.cwd) at
// classification time — resolving it again here would be redundant, not more
// correct. This resolves the containment QUESTION without ever asking "which
// files actually exist".
//
// ok is false when the prefix cannot be safely resolved: cwdInvalid (an
// earlier dynamic `cd` invalidated the running cwd, #129) means a RELATIVE
// glob cannot be safely anchored, so the caller fails the whole for-list
// closed (ASK), matching cdInvalidAsk's fail-closed posture for every other
// relative operand. An absolute glob (`/abs/*.md`) is unaffected by
// cwdInvalid, since it needs no cwd to resolve.
func globDirPrefix(pattern string, cwdInvalid bool) (string, bool) {
	segs := strings.Split(pattern, "/")
	var prefix []string
	for _, seg := range segs {
		if hasGlobMeta(seg) {
			break
		}
		prefix = append(prefix, seg)
	}
	dir := strings.Join(prefix, "/")
	if dir == "" {
		dir = "."
	}
	if filepath.IsAbs(dir) {
		return dir, true
	}
	if cwdInvalid {
		return "", false
	}
	return dir, true
}

// isResolvableParamExp reports whether a parameter expansion is a plain
// `$VAR` / `${VAR}` whose name is resolvable — either because it was
// statically assigned earlier in the same program (present in knownVars,
// #60) or because it is one of the closed #156 allowlist of names
// ($HOME, $USER, $TMPDIR, $PWD, $OLDPWD) resolveVar can resolve from its
// authoritative source (in-script assignment always takes precedence over
// these — see resolveVar's doc comment). Anything with extra logic — default
// (`${VAR:-x}`), length (`${#VAR}`), indirection (`${!VAR}`), array index,
// slice, replacement, modifiers, or special parameters ($1, $@, $?) — is NOT
// resolvable here and keeps the word inexact (fail-closed): this issue widens
// WHICH NAMES resolve, not which expansion forms are accepted. A name
// resolvable by neither source (an arbitrary env var, or a var assigned
// dynamically) stays unresolvable.
func isResolvableParamExp(p *syntax.ParamExp, knownVars map[string]string, resolver varResolver, cc cwdCtx) bool {
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
	_, ok := resolveVar(p.Param.Value, knownVars, resolver, cc)
	return ok
}

// printWord prints a word back to source text (used only as the inexact
// fallback for messages / matching when expansion fails).
func printWord(w *syntax.Word) string {
	var sb strings.Builder
	_ = syntax.NewPrinter().Print(&sb, w)
	return sb.String()
}
