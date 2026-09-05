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
// process-environment-derived variables ($HOME, $USER, $TMPDIR) that
// literalWord/isResolvableParamExp may resolve when a name is absent
// from knownVars. $PWD and $OLDPWD are deliberately NOT resolved through this
// struct — they come from the per-command tracked cwd (simpleCommand.cwd /
// cwdInvalid and their oldCWD counterparts, threaded separately through
// reduceCallExpr), because the hook's process-env $PWD is the EVENT cwd and
// would be wrong after an in-script `cd` (see the "$PWD must NOT come from
// the process environment" note in the var-resolution design).
//
// Fields are injectable funcs (mirroring the `homeDir` resolver for
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
// resolve $PWD/$OLDPWD: the running cwd and its validity (mirroring
// simpleCommand.cwd/cwdInvalid) plus the PRIOR cwd and its validity
// (for $OLDPWD, recorded by applyCd on each `cd`). The zero value (all
// fields empty/invalid) makes $PWD/$OLDPWD fail closed, which is correct
// for any call site that has no tracked cwd to offer (e.g. a RHS assignment
// expansion evaluated before cwd tracking is meaningful).
type cwdCtx struct {
	cwd           string
	cwdInvalid    bool
	oldCWD        string
	oldCWDInvalid bool
	// rc is the resolved git context for the event's cwd (nil when resolution
	// failed, e.g. not inside a work tree). literalWord threads it into anchor
	// resolution so an allowlisted command substitution
	// ($(git rev-parse --show-toplevel), $(git rev-parse --git-common-dir),
	// $(pwd)) resolves WHEREVER it sits in a word — bare, wrapped in double
	// quotes, or embedded inline alongside other parts — instead of only as a
	// whole, unquoted assignment RHS. A nil rc keeps the two git anchors
	// unresolved (fail-closed); $(pwd) resolves from cwd and needs no rc.
	rc *repoContext
}

// classifyBash parses a Bash command to an AST and classifies it. The result
// is the AGGREGATE verdict over every simple command in the line: a single
// DENY beats everything, then ASK, then ALLOW; if every simple command is a
// high-confidence ALLOW the whole line is allowed; otherwise it defers to the
// normal pipeline.
//
// Fail-closed: a parse error DENIES (bash would refuse the same string — see
// the arm below) and an unhandled AST construct yields a DEFER carrying that as
// its analysis (the gate cannot prove the line safe), never allow.
func classifyBash(command string, ev *Event) Decision {
	parser := syntax.NewParser(syntax.KeepComments(false))
	file, err := parser.Parse(strings.NewReader(command), "")
	if err != nil {
		// A parse failure is NOT a classification the gate is unsure about — it
		// is a command bash itself would refuse. The parser runs mvdan/sh's
		// default LangBash, so bash parity is the design intent; approving here
		// would run a string bash rejects, and denying reaches that same outcome
		// one click sooner. It also fires on a PreToolUse event, i.e. on a
		// command the MODEL authored: a human cannot repair broken syntax by
		// clicking Yes, so there is no human decision to escalate.
		//
		// Accepted risk: if mvdan/sh ever rejects a string bash accepts, this
		// deny leaves no escape hatch. That is deliberate — a divergence then
		// surfaces as a loud, fixable bug instead of being absorbed into a
		// habitual approval click.
		//
		// The reason carries the parser's own position and, where the cause is a
		// recognizable class, names it, so the agent's next attempt is a fix
		// rather than a retry.
		return deny("bash:parse-error", fmt.Sprintf(
			"Blocked: this is not valid shell syntax — the parser failed at %v. %sReal bash rejects the same "+
				"string, so there is nothing to approve: fix the quoting/escaping and re-run.",
			err, parseErrorCauseSentence(command, err)))
	}

	// Forbidden command shapes (ported from the replaced
	// auto-approve-compound-commands.sh). Each has a working two-call
	// alternative, so the gate denies them with a teaching remediation rather
	// than letting them through.
	if d, hit := forbiddenForm(file); hit {
		return d
	}

	// Resolve the git context once, up front, so recordAssign can recognize
	// the command-substitution anchors ($(git rev-parse
	// --show-toplevel), $(git rev-parse --git-common-dir)). A resolution
	// failure (not inside a git work tree, git missing, timeout) leaves rc
	// nil; every anchor-recognition call below treats a nil rc as "cannot
	// resolve this anchor" and keeps the existing fail-closed behavior — it
	// does NOT abort classification of the rest of the line.
	rc, _ := resolveRepoContext(ev.CWD)

	cmds, extractErr := extractSimpleCommands(file, ev.CWD, defaultVarResolver(), rc)
	if extractErr != nil {
		return deferJudgment("bash:unhandled-construct", fmt.Sprintf(
			"the Bash command contains a construct the permission gate cannot statically classify (%v), so no "+
				"command part could be extracted for grading.", extractErr))
	}
	if len(cmds) == 0 {
		// Nothing executable (e.g. only assignments / comments). Defer.
		return deferToPipeline()
	}

	worst := BucketAllow
	var worstDecision Decision
	sawNonAllow := false
	// The FIRST defer that carries an analysis (deferJudgment) is kept so the
	// whole line's defer reaches the §7 log with an account of why, instead of
	// collapsing to a bare, unloggable deferToPipeline. A defer is not "worse"
	// than another defer, so first-wins is the whole rule; an ASK anywhere in
	// the line still outranks every defer below.
	//
	// The no-specific-rule residual (deferResidualOp) is the one exception to
	// first-wins, and it is a ranking rather than a discard: it is kept
	// separately and used only when NO other defer analysis was seen. Its
	// account is "the gate has no table for this program", which every
	// unrecognized program produces, so letting it win a line by position would
	// hide the informative analysis behind it (`npm test && git reset --hard`
	// would log the npm residual instead of the reset).
	var deferDecision Decision
	haveDeferAnalysis := false
	var residualDefer Decision
	haveResidualDefer := false

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
			switch {
			case d.Operation == deferResidualOp:
				if !haveResidualDefer {
					residualDefer = d
					haveResidualDefer = true
				}
			case !haveDeferAnalysis && d.Operation != "":
				deferDecision = d
				haveDeferAnalysis = true
			}
			sawNonAllow = true
		case BucketAllow:
			// keep scanning
		}
	}

	if worst == BucketAsk {
		return worstDecision
	}
	if sawNonAllow {
		// Some part was not a high-confidence allow and was not a deny or a hard ask
		// — hand the whole line back to the normal permission pipeline rather
		// than auto-allowing. This keeps the allow track to cheap, certain
		// wins only (§4 posture).
		if haveDeferAnalysis {
			return deferDecision
		}
		if haveResidualDefer {
			return residualDefer
		}
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

// parseErrorCauseSentence names the syntax defect behind a parser error when it
// belongs to a recognizable class, as a sentence ready to splice into the
// parse-error deny (empty string when the class is not recognized, so the
// message degrades to the parser's bare position).
//
// mvdan/sh reports WHERE the parser ran out of input, which for an unterminated
// construct is the opening delimiter — not the token that broke it. The common
// real-world case is an unescaped backtick or `$(` inside a double-quoted
// string: both open a command substitution that swallows the closing quote, and
// the parser then reports only "reached EOF without closing quote". Naming the
// swallower is what turns the message into a fix.
func parseErrorCauseSentence(command string, err error) string {
	cause := parseErrorCause(command, err)
	if cause == "" {
		return ""
	}
	return "The cause is " + cause + ". "
}

// parseErrorCause returns the recognized cause phrase for a parser error, or ""
// when the error is outside the recognized classes. Split from
// parseErrorCauseSentence so tests can assert the phrase itself.
func parseErrorCause(command string, err error) string {
	msg := err.Error()
	switch {
	case strings.Contains(msg, "closing quote `\"`"):
		switch {
		case containsUnescapedByte(command, '`'):
			return "an unescaped ` inside a double-quoted string, which opens a command substitution and " +
				"swallows the closing quote — escape it as \\` or switch the surrounding string to single quotes"
		case strings.Contains(command, "$("):
			return "an unbalanced $( inside a double-quoted string, which swallows the closing quote — " +
				"close the substitution, or escape the $ as \\$"
		}
		return "an unbalanced double quote"
	case strings.Contains(msg, "closing quote `'`"):
		return "an unbalanced single quote"
	case strings.Contains(msg, "matching `$(` with `)`"):
		return "an unclosed $( … ) command substitution"
	case strings.Contains(msg, "matching `${` with `}`"):
		return "an unclosed ${ … } parameter expansion"
	case strings.Contains(msg, "matching `(` with `)`"):
		return "an unbalanced parenthesis"
	case strings.Contains(msg, "matching `{` with `}`"):
		return "an unbalanced brace"
	}
	return ""
}

// containsUnescapedByte reports whether s contains c not preceded by a
// backslash. Deliberately a cheap scan rather than a re-lex: it feeds a
// diagnostic hint, never a verdict, so a false positive costs one imprecise
// sentence in a message that already carries the parser's own position.
func containsUnescapedByte(s string, c byte) bool {
	for i := 0; i < len(s); i++ {
		if s[i] != c {
			continue
		}
		if i > 0 && s[i-1] == '\\' {
			continue
		}
		return true
	}
	return false
}

// simpleCommand is a flattened view of one executed command: the program
// name plus its arguments, with leading `env VAR=x` wrappers and assignment
// prefixes stripped. Path-bearing arguments are kept verbatim for Engine B.
type simpleCommand struct {
	// args[0] is the program; args[1:] are its arguments (literal-expanded
	// where statically possible). Empty args means "could not determine the
	// program" → the caller defers with that as the analysis; it never allows.
	args []string
	// hasUnknownExpansion is true when any word contained a command
	// substitution or an unresolved parameter expansion. Such a command
	// cannot be statically proven safe, so it must not ALLOW.
	hasUnknownExpansion bool
	// argMeta is parallel to args, one entry per token. hasUnknownExpansion
	// answers "was anything dynamic?"; this answers "WHICH token was, and where
	// inside it", which is what lets the credentialed-tool precondition ask
	// whether the dynamic token could occupy a classification-bearing position
	// (the noun, the verb, the endpoint, a value-taking global) rather than
	// denying every command that carries one anywhere. A redirect word's
	// dynamism sets hasUnknownExpansion but occupies no argv slot, so the two
	// are deliberately not redundant.
	//
	// It is empty on a hand-built simpleCommand (tests, the synthetic
	// redirect-only command); every reader checks the length against args and
	// falls back to hasUnknownExpansion, so an absent slice is fail-closed.
	argMeta []argMeta
	// hasRedirectToFile is true when the command redirects stdout/stderr to a
	// real file (not /dev/null). Such a command can exfiltrate/clobber and
	// must not ride an allow-listed prefix.
	hasRedirectToFile bool
	// redirectTargets holds those real-file redirect destinations, verbatim, in
	// the order they appeared. They are NOT argv operands, so neither Engine B
	// operand walk (containPathOperands / containWriteOperands) ever sees them;
	// recording them is what lets redirectVetoesAllow grade the destination
	// instead of vetoing on the bare bool. A `/dev/null` target is not
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
	// redirectOnly marks a synthetic command that carries NOTHING BUT redirects:
	// the statement they were attached to runs no program at all (a bare `> f`,
	// `[[ -f x ]] > f`, `(( i++ )) > f`, `let n=1 > f`, `export A=1 > f`,
	// `case q in esac > f`, a bare `A=1 > f` assignment). The shell still performs
	// the redirect — the file is created, truncated, or opened for reading — so the
	// paths it names must still be graded, and before this existed they were graded
	// nowhere: the construct emitted no simpleCommand, so a line like
	// `[[ -f x ]] > <out-of-repo> && echo hi` reduced to a lone allow-eligible
	// `echo hi` and ALLOWed while the shell performed the out-of-repo write.
	// args[0] carries a display name for the decision text only, never a real
	// program; classifySimpleCommand branches on this flag BEFORE any program
	// dispatch, so the name is never matched against a rule table.
	redirectOnly bool
	// hasInlineAssignment is true when the command carried an inline
	// environment-assignment prefix (`AWS_ENDPOINT_URL=… aws …`,
	// `GIT_SSH_COMMAND=… git …`, `GH_HOST=… gh …`). Such a prefix can redirect
	// egress, swap identity, or inject a pager without ever touching argv, so
	// the git/gh/aws classifiers DENY on it (a stated precondition). The
	// prefix is stripped from args[] by stripEnvWrapper so the real program is
	// at args[0]; this flag preserves the fact that it was present.
	hasInlineAssignment bool
	// cwd is the RUNNING working directory this command executes in, tracked
	// through any `cd <arg>` that appeared earlier in the same parsed program.
	// Seeded from ev.CWD and updated left-to-right as the walk crosses a
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
	// oldCWD / oldCWDInvalid are $OLDPWD's tracked source: the running
	// cwd's value immediately BEFORE the most recent statically-resolvable
	// `cd` that preceded this command in the walk. Stamped alongside cwd at
	// the same point (before this call's own `cd` side effect, if any).
	// oldCWDInvalid is true when no `cd` has happened yet in this scope, or
	// the prior cwd was itself invalid — either way $OLDPWD must fail closed.
	oldCWD        string
	oldCWDInvalid bool
}

// argMeta carries the per-argument facts about ONE argv token that the
// whole-command hasUnknownExpansion bool cannot express.
type argMeta struct {
	// exact reports whether the token expanded to a static literal.
	exact bool
	// staticPrefix is the literal text contributed by the word's LEADING fully
	// static parts, up to the first part the gate cannot pin. For `itemId=$ID`
	// it is "itemId="; for `"$X"itemId=` it is "" — the dynamic part comes
	// first, so nothing about that token is statically pinned.
	//
	// It exists so the precondition can tell a dynamic FIELD VALUE from a
	// dynamic FIELD NAME. `gh api graphql -F itemId=$ID` is harmless: the key is
	// literal, and the value can never become a subcommand or a second query
	// document. `-F "$K"=v` is not: at run time $K could be `query`, which for
	// `gh api graphql` IS the document the gate classifies. An inexact word's
	// unresolvable parts expand to "", so any character present in the expansion
	// came from a part the gate DID pin — but only a leading run of pinned parts
	// proves the KEY specifically is pinned, which is what this records.
	staticPrefix string
}

// staticWordPrefix returns the literal text of a word's leading fully-static
// parts, stopping at the first part the gate cannot pin (see
// argMeta.staticPrefix). A fully static word yields its whole literal text.
func staticWordPrefix(w *syntax.Word) string {
	var b strings.Builder
	if w == nil {
		return ""
	}
	for _, part := range w.Parts {
		switch p := part.(type) {
		case *syntax.Lit:
			b.WriteString(p.Value)
		case *syntax.SglQuoted:
			b.WriteString(p.Value)
		case *syntax.DblQuoted:
			for _, dp := range p.Parts {
				lit, ok := dp.(*syntax.Lit)
				if !ok {
					return b.String()
				}
				b.WriteString(lit.Value)
			}
		default:
			return b.String()
		}
	}
	return b.String()
}

// allowEligible reports whether a command is eligible for the high-confidence
// ALLOW track. A command with a real-file redirect (exfiltration/clobber risk)
// or an unresolved expansion / command substitution (which cannot be proven
// safe statically) is NOT eligible and must defer to the normal pipeline
// instead of auto-allowing.
//
// Its redirect half is ABSOLUTE, which is why the two path-classifier allow
// tracks no longer call it: classifyReadOnlyUtility and classifyInRepoWrite
// ask redirectVetoesAllow instead, so a redirect whose every destination is a
// session-shaped harness scratchpad can still allow, and they spell out
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
// through the walk. The walk order is left-to-right / top-to-bottom for
// &&/||/;/newline-separated statements, which is exactly the order bash
// applies `cd` side effects, so a single running-cwd variable updated as the
// walk encounters each `cd` is faithful for the common `cd X && cmd` /
// `cd X; cmd` shapes. Each emitted simpleCommand is stamped with the running
// cwd (and its validity) AT THE POINT it is walked, so containment resolves
// relative operands against the cwd that was actually in effect for that
// command, not the process-wide event cwd.
//
// resolver supplies the authoritative sources for $HOME/$USER/$TMPDIR;
// it is threaded down into every literalWord call the walk makes.
//
// rc is the resolved git context for the event's cwd (nil when resolution
// failed, e.g. not inside a work tree). recordAssign threads it into
// resolveAnchorCmdSubst so an assignment RHS that is EXACTLY
// `$(git rev-parse --show-toplevel)` / `$(git rev-parse --git-common-dir)`
// can be recorded as a known literal instead of always being dropped as an
// unresolvable command substitution.
func extractSimpleCommands(file *syntax.File, seedCWD string, resolver varResolver, rc *repoContext) ([]simpleCommand, error) {
	var out []simpleCommand
	var walkErr error

	// runningCWD / runningCWDInvalid track the shell's current directory as the
	// walk crosses `cd` statements. runningCWDInvalid is set by a `cd`
	// whose target cannot be statically resolved (a command substitution, an
	// unresolved variable, or `cd -`) — after that point relative operands
	// cannot be safely resolved and must fail closed, so every later-emitted
	// simpleCommand in that scope carries cwdInvalid=true.
	runningCWD := seedCWD
	runningCWDInvalid := false

	// runningOldCWD / runningOldCWDInvalid track $OLDPWD: the value of
	// runningCWD immediately before the most recent statically-resolvable
	// `cd`. Starts invalid — before any `cd` has happened, $OLDPWD is not
	// tracked and must fail closed. applyCd updates these BEFORE it mutates
	// runningCWD, so they always hold the PRIOR value.
	runningOldCWD := ""
	runningOldCWDInvalid := true

	// curCC snapshots everything literalWord resolves a word against at the
	// point of the call: the tracked cwd pair ($PWD/$OLDPWD) plus the resolved
	// git context the anchor allowlist needs. One constructor rather than five
	// repeated struct literals, so a future field cannot be threaded into some
	// call sites and forgotten at others.
	curCC := func() cwdCtx {
		return cwdCtx{
			cwd: runningCWD, cwdInvalid: runningCWDInvalid,
			oldCWD: runningOldCWD, oldCWDInvalid: runningOldCWDInvalid,
			rc: rc,
		}
	}

	// knownVars accumulates variables assigned to a STATIC literal value
	// earlier in the same parsed program, in walk order (which is
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
	// inside. In real bash an assignment made inside a `( … )`
	// subshell, a function body, or a backgrounded group/subshell runs in a
	// child shell and does NOT persist to the enclosing/program-global scope.
	// While scopeDepth > 0 we therefore DO NOT record assignments into
	// knownVars, so a scoped `P=/abs` cannot resolve a later top-level `$P`.
	// (Uses of an already-known top-level var inside a scope still resolve —
	// that direction is correct shell semantics.) The map is shared across the
	// whole walk, so the depth gate lives on the write side (recordAssign), not
	// the read side (literalWord).
	scopeDepth := 0

	// walkStmt's second parameter is the set of redirects INHERITED from an
	// enclosing statement — see mergeRedirs and walkCmd for why a compound
	// command's redirects have to travel down to the simple commands inside it.
	var walkStmt func(stmt *syntax.Stmt, inherited []*syntax.Redirect)
	var walkCmd func(cmd syntax.Command, redirs []*syntax.Redirect)
	var walkDeclClause func(c *syntax.DeclClause)
	var descendCmdSubsts func(n syntax.Node)
	var descendProcSubsts func(n syntax.Node)
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
		// knownVars. Skip recording entirely; we do NOT delete
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
		// the running cwd just like a direct use would, and an allowlisted
		// anchor substitution ($(git rev-parse --show-toplevel), …) resolves
		// here because literalWord resolves it in EVERY word position, not
		// because this call site checks for one. That is why there is no
		// anchor-specific fallback below: `R=$(git rev-parse --show-toplevel)`,
		// `R="$(…)"` and `R=$(…)/sub` all come back exact already.
		cc := curCC()
		val, exact := literalWord(a.Value, knownVars, resolver, cc)
		if !exact {
			// RHS is dynamic (e.g. `D=$(date)`, or built from an
			// unresolved variable). The variable is no longer statically
			// known — drop any stale value so a later use stays fail-closed.
			delete(knownVars, name)
			return
		}
		knownVars[name] = val
	}

	// applyCd updates the running cwd when a walked CallExpr is `cd <arg>`.
	// It reuses stmtIsCdWithArg's detection shape (basename == "cd" with
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
	// runningOldCWD/runningOldCWDInvalid ($OLDPWD's source) — mirroring
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
		cc := curCC()
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

	// descendCmdSubsts classifies the command inside every command substitution
	// that belongs to one AST node, by walking its statements as ordinary
	// commands. Both spellings are covered — `$(cmd)` and the backtick
	// `` `cmd` `` — because the parser reports one *syntax.CmdSubst for each.
	//
	// The inner statements inherit NO redirects. A command substitution is
	// expanded during word expansion, which bash performs BEFORE it applies the
	// enclosing command's redirections, so in `echo "$(cat)" < f` the `cat` reads
	// the shell's stdin, not f. Passing the enclosing redirects down here would
	// attribute a read/write to a command that never performs it.
	//
	// They are walked at scopeDepth+1, matching descendProcSubsts: a substitution
	// runs in a CHILD shell, so `P=/safe; export D=$(P=/etc; echo); cat "$P/x"`
	// reads /safe/x in real bash. Recording the inner assignment would have the
	// gate grade /etc/x instead — a path the command never touches.
	//
	// SCOPE: like descendProcSubsts it takes a NODE, not a word, and finds every
	// substitution beneath it with syntax.Walk, so it covers every word position
	// of that node at once. That matters because a non-anchor `$(…)` leaves its
	// word INEXACT, and inexactness stops the allow track only where the inexact
	// word rides a command the walk emits: a `for`/`select` item list, a `case`
	// subject or pattern, and a `VAR=… cmd` prefix emit no command of their own,
	// so before this took a node, `for f in $(cat ../sib/.env); do echo x; done`
	// and `FOO=$(cat ../sib/.env) echo hi` ALLOWed on their remaining parts while
	// bash ran the substituted command. Hand-listing the positions was tried on
	// the sibling process-substitution class and did not converge — successive
	// review rounds each found one more — so the reach is a property of the
	// traversal instead.
	//
	// The walk STOPS at any nested *syntax.Stmt: the main walk reaches those on
	// its own (a `for` body, a `case` arm, a substitution's own statements), and a
	// substitution nested inside one is reached when that statement is walked. So
	// each substitution is graded exactly once however deeply the spellings nest
	// (`echo $(echo $(cmd))`, `echo "$(cat <(cmd))"`, `cat <(echo "$(cmd)")`).
	//
	// The ONE deliberate exception is an allowlisted ANCHOR substitution
	// ($(git rev-parse --show-toplevel), $(git rev-parse --git-common-dir),
	// $(pwd) — anchorCommands). Those are skipped, not graded. resolveAnchorCmdSubst
	// admits only a single plain CallExpr whose argv equals one of those forms
	// EXACTLY, with no assignments, redirects or background marker, so the command
	// is already known in full and is read-only; there is nothing left to decide,
	// and the resolved value still runs through normal containment, so skipping
	// the descent widens nothing.
	//
	// $(pwd) is what makes the exception load-bearing rather than merely tidy.
	// Measured by deleting this skip and re-running: the two git anchors grade as
	// ALLOW and cost nothing, but bare `pwd` earns no high-confidence allow of its
	// own, so descending into $(pwd) turns `cat "$(pwd)/a.txt"`,
	// `case "$(pwd)" in …` and `FOO=$(pwd) echo hi` from allows into prompts —
	// the anchor idiom itself, back to the escalation anchors exist to remove.
	// The skip is
	// applied uniformly across the allowlist anyway, because "an anchor is not an
	// ordinary substitution" is one rule and three rules would rot.
	//
	// When an anchor CANNOT resolve (no repoContext, or an invalidated tracked
	// cwd) it is not an anchor here either, and the descent grades it like any
	// other substitution.
	//
	// Positions where bash does NOT run a substitution need no exception, because
	// the parser reports no CmdSubst node for them either (measured against
	// mvdan.cc/sh v3.13.1): a single-quoted `'$(cmd)'`, and a QUOTED here-document
	// body (`<<'EOF'`). The unquoted here-document body is the opposite — bash
	// does expand it, the parser does report the node, and walking a whole
	// *syntax.Redirect grades it. A parameter expansion's word (`${Q:-$(cmd)}`)
	// IS reported, in both the quoted and unquoted spellings, and bash runs both
	// when the parameter is unset; grading it whether or not the default branch is
	// taken is the fail-closed direction.
	descendCmdSubsts = func(node syntax.Node) {
		if node == nil {
			return
		}
		cc := curCC()
		syntax.Walk(node, func(n syntax.Node) bool {
			switch x := n.(type) {
			case nil:
				// Walk calls f(nil) after a node's children.
				return false
			case *syntax.Stmt:
				return false
			case *syntax.CmdSubst:
				if _, ok := anchorValue(x, cc); ok {
					return false
				}
				scopeDepth++
				for _, s := range x.Stmts {
					walkStmt(s, nil)
				}
				scopeDepth--
				return false
			}
			return true
		})
	}

	// descendProcSubsts classifies the command inside every process substitution
	// that belongs to one AST node, by walking its statements as ordinary
	// commands.
	//
	// It is what makes the `<(cmd)` word's exactness safe: the word itself no
	// longer marks the enclosing command unprovable (a /dev/fd pipe is not a
	// path — see procSubstFD), so the substituted command has to be judged on
	// its own terms instead of riding the enclosing command's verdict. Both
	// operators are descended into: `>(cmd)` really does run cmd too, and
	// classifying it can only add a deny or an escalation, never an allow.
	//
	// The inner statements inherit NO redirects, for the same reason
	// descendCmdSubsts passes none: the substitution is set up during word
	// expansion, before the enclosing command's own redirections are applied.
	// They are walked at scopeDepth+1: a substitution runs in a CHILD shell, so
	// an assignment or a `cd` inside it must not leak into the enclosing
	// program's knownVars / running cwd, exactly as for a `( … )` subshell.
	//
	// SCOPE: it takes a NODE, not a word, and finds every substitution beneath
	// it with syntax.Walk — so it covers every word position of that node at
	// once (argv, an assignment RHS and its array elements, a `for`/`select`
	// item list, a `case` subject word and its patterns, a `[[ … ]]` operand, a
	// redirect target) instead of a hand-listed few. Enumerating the positions by
	// hand did not converge: each review round found a position the round
	// before had missed — first a redirect target, then `for f in <(cmd)`,
	// `case <(cmd) in` and `x=<(cmd)` — so the reach is now a property of the
	// traversal rather than of a list someone has to keep complete.
	//
	// The walk STOPS at any nested *syntax.Stmt: the main walk reaches those on
	// its own (a `for` body, a `case` arm, a substitution's own statements), and a
	// substitution nested inside one is reached when that statement is walked. So
	// each substitution is graded exactly once, no matter how deeply the
	// spellings nest (`cat <(cat <(cmd))`).
	//
	// The sibling command-substitution class is descendCmdSubsts', and walkStmt
	// calls both over the same nodes, so a `$(…)` body is graded there and this
	// function never needs to reach one. That split is what keeps each
	// substitution graded exactly once when the two nest
	// (`echo "$(cat <(cmd))"`, `cat <(echo "$(cmd)")`).
	//
	// An input `<(…)` is the only construct that keeps its word EXACT while
	// carrying a command — inexactness could never have caught it in any
	// position — which is exactly why grading it in every position is this
	// function's job.
	//
	// One position where bash DOES run a process substitution is unreachable from
	// here, because the parser reports no ProcSubst node for it at all (measured
	// against mvdan.cc/sh v3.13.1): a parameter expansion's word, in its
	// unquoted spelling — real bash runs `: ${Q:-<(cmd)}` and does NOT run
	// `: "${Q:-<(cmd)}"` (re-measured, identically, on bash 3.2.57 and 5.3.15).
	// isResolvableParamExp rejects every non-plain expansion, so the word is
	// inexact, and inexactness stops the allow track only where the inexact word
	// rides a command the walk emits — so a NON-emitting position keeps allowing:
	// `for f in ${Q:-<(cat ../sib/.env)}; do echo x; done` ALLOWs, here and at
	// the merge base this descent landed on. This is the one measured hole left
	// in either
	// substitution class, and it is unclosable without a node to hang the descent
	// on; the `$(…)` spelling of the same shape (`${Q:-$(cmd)}`) IS reported and
	// IS graded, by descendCmdSubsts.
	//
	// A here-document body is not a PROCESS-substitution position at all: bash
	// takes `<(cmd)` there literally and the parser agrees, so walking a whole
	// *syntax.Redirect (Hdoc included) grades nothing bash would not run. The
	// `$(…)` spelling is the opposite on both counts and is graded — see
	// descendCmdSubsts.
	descendProcSubsts = func(node syntax.Node) {
		if node == nil {
			return
		}
		syntax.Walk(node, func(n syntax.Node) bool {
			switch x := n.(type) {
			case nil:
				// Walk calls f(nil) after a node's children.
				return false
			case *syntax.Stmt:
				return false
			case *syntax.ProcSubst:
				scopeDepth++
				for _, s := range x.Stmts {
					walkStmt(s, nil)
				}
				scopeDepth--
				return false
			}
			return true
		})
	}

	// walkDeclClause walks every assignment of a declaration clause
	// (export/local/declare/readonly/typeset). It contributes no program for
	// the declaration itself (a literal/param-expansion RHS mutates only shell
	// state), so all it does is record a static `export VAR=literal` /
	// `local VAR=literal` for later uses to resolve.
	//
	// It deliberately does NOT descend into a command substitution in the RHS.
	// It used to be the single call site of descendCmdSubsts, back when that
	// took a word; now walkStmt runs the descent over the whole statement, which
	// reaches this clause's assignment values along with every other word
	// position. Descending here as well would grade those inner commands twice.
	walkDeclClause = func(c *syntax.DeclClause) {
		for _, a := range c.Args {
			if a != nil {
				recordAssign(a)
			}
		}
	}

	// walkCmd classifies one command node. redirs is the EFFECTIVE redirect set
	// for it: the redirects written on its own statement, plus every redirect
	// inherited from an enclosing statement (mergeRedirs builds it).
	//
	// Every compound arm below forwards redirs to the statements it descends
	// into, because a redirect attached to a compound command applies to EVERY
	// command inside it — `{ cat; } < /etc/passwd` really does hand /etc/passwd to
	// cat, and `{ echo x; } > <out-of-repo>` really does perform that write.
	// Forwarding is what makes a redirect grade identically whether it is written
	// on a simple command or on a compound one; dropping it (which is what these
	// arms used to do, since only the CallExpr arm consumed redirs) reduced the
	// line to a bare non-path-bearing `echo` or an operand-less `cat` and ALLOWed
	// it, bypassing containment on both the read and the write side.
	walkCmd = func(cmd syntax.Command, redirs []*syntax.Redirect) {
		if walkErr != nil {
			return
		}
		switch c := cmd.(type) {
		case *syntax.CallExpr:
			// A bare assignment-only CallExpr (`VAR=x` with no program)
			// mutates shell state and persists to later commands in the same
			// program, so record any static assignment for later resolution.
			// A `VAR=x cmd` prefix (with a program) sets env for THAT
			// command only and does NOT persist, so its assigns are not
			// recorded here.
			if len(c.Args) == 0 {
				for _, a := range c.Assigns {
					recordAssign(a)
				}
			}
			// Stamp the running cwd (and its validity) AT THE POINT this command
			// is walked, BEFORE applying this call's own `cd` side
			// effect (a `cd`'s own arguments, if any, are resolved against the
			// PRIOR cwd, not the directory it is about to change into).
			cc := curCC()
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
			// The command inside every substitution, process or command — in argv,
			// in an assignment prefix, or in a bare assignment's RHS — is classified
			// on its own terms by the statement-level descent in walkStmt, which runs
			// before this arm and before applyCd.
			//
			// Apply this call's `cd` side effect (if any) so LATER commands in
			// the walk see the updated cwd.
			applyCd(c)
		case *syntax.BinaryCmd:
			// && || | & — descend both sides, each inheriting this statement's
			// redirects. In practice the parser parks a redirect written after
			// `a && b` on b's own statement, so this arm rarely inherits
			// anything; forwarding is the fail-closed direction either way,
			// since an over-attributed redirect can only cost a defer.
			walkStmt(c.X, redirs)
			walkStmt(c.Y, redirs)
		case *syntax.Block:
			for _, s := range c.Stmts {
				walkStmt(s, redirs)
			}
		case *syntax.Subshell:
			// A `( … )` subshell runs in a child shell; assignments inside it
			// do not persist to the enclosing scope. Bump the
			// scope depth so recordAssign skips them.
			scopeDepth++
			for _, s := range c.Stmts {
				walkStmt(s, redirs)
			}
			scopeDepth--
		case *syntax.IfClause:
			for _, s := range c.Cond {
				walkStmt(s, redirs)
			}
			for _, s := range c.Then {
				walkStmt(s, redirs)
			}
			if c.Else != nil {
				// The `else`/`elif` branch is part of the SAME statement, so it
				// inherits that statement's redirects exactly as the `then`
				// branch does. Passing nil here dropped them.
				walkCmd(c.Else, redirs)
			}
		case *syntax.ForClause:
			// A `for x in <words>; do …; done` whose header is a fully static
			// item list makes the loop variable's entire value set
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
				cc := curCC()
				items, allStatic := staticForItems(wi, knownVars, runningCWDInvalid, resolver, cc)
				if allStatic && len(items) <= maxForFanOut {
					loopVar := wi.Name.Value
					prevVal, hadPrev := knownVars[loopVar]
					for _, item := range items {
						knownVars[loopVar] = item
						for _, s := range c.Do {
							walkStmt(s, redirs)
						}
					}
					// Restore/remove the binding so it does not leak past the
					// loop or clobber an outer variable of the same name
					// (scopeDepth discipline).
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
				walkStmt(s, redirs)
			}
		case *syntax.WhileClause:
			for _, s := range c.Cond {
				walkStmt(s, redirs)
			}
			for _, s := range c.Do {
				walkStmt(s, redirs)
			}
		case *syntax.CaseClause:
			for _, item := range c.Items {
				for _, s := range item.Stmts {
					walkStmt(s, redirs)
				}
			}
		case *syntax.FuncDecl:
			// A function body is a separate scope: `local`/scoped vars and even
			// plain assignments inside it do not persist to the program-global
			// scope merely by the function being declared. Bump
			// the scope depth so recordAssign skips its assignments.
			//
			// A redirect on the DECLARATION (`f() { … ; } > log`) is applied
			// every time the function is called, so the body inherits it.
			scopeDepth++
			walkStmt(c.Body, redirs)
			scopeDepth--
		case *syntax.ArithmCmd:
			// Pure arithmetic; no external command. Ignore. Any redirect written
			// on it is still performed by the shell, and is graded by
			// walkStmt's redirect-only fallback because nothing is emitted here.
		case *syntax.LetClause:
			// `let x=1+2` — pure arithmetic, no external command. Ignore
			// (same as the ArithmCmd case, redirect fallback included).
		case *syntax.TestClause:
			// `[[ … ]]` — a builtin test; runs no external command. Ignore
			// (same as the ArithmCmd case, redirect fallback included).
		case *syntax.TimeClause:
			// `time cmd` — wraps a real command. Descend into the wrapped
			// statement and classify it.
			walkStmt(c.Stmt, redirs)
		case *syntax.CoprocClause:
			// `coproc cmd` — wraps a command in a coprocess. Descend into the
			// wrapped statement and classify it.
			walkStmt(c.Stmt, redirs)
		case *syntax.DeclClause:
			// `export`/`local`/`declare`/`readonly`/`typeset` — walk ALL of its
			// assignments (a single `export A=x B=y` carries multiple). A plain
			// literal/parameter-expansion RHS mutates only shell state, so it
			// contributes no program. A substitution in an assignment RHS
			// (`local d=$(cmd)`, including the quoted `="$(cmd)"` form) is graded by
			// walkStmt's statement-level descent, not here.
			walkDeclClause(c)
		default:
			walkErr = fmt.Errorf("unhandled shell construct %T", c)
		}
	}

	walkStmt = func(stmt *syntax.Stmt, inherited []*syntax.Redirect) {
		if walkErr != nil || stmt == nil {
			return
		}
		// This statement's own redirects PLUS everything inherited from an
		// enclosing (compound) statement. Nesting composes: an inner redirect
		// does not cancel an outer one, because bash performs both opens — in
		// `{ cat < a; } < b` the block opens b on fd 0 and cat then opens a on
		// its own fd 0, so both files are read and both must be graded.
		redirs := mergeRedirs(stmt.Redirs, inherited)

		// A substitution — process or command — can sit in any word this statement
		// owns, not just argv: a REDIRECT target (`cat < <(cat ../sibling-repo/.env)`,
		// `cat > >(tee x)`, `true > $(cmd)`), a `for`/`select` item list, a `case`
		// subject word or pattern, an assignment RHS or array element, a `[[ … ]]`
		// operand, an inline `FOO=… cmd` prefix. Neither class is caught by the
		// enclosing command's own verdict there: literalWord reduces an INPUT process
		// substitution to procSubstFD — a token the containment walks skip — and a
		// non-anchor `$(…)` only makes its word inexact, which stops the allow track
		// solely where that word rides a command the walk emits. Descend over the
		// statement's whole command node and its own redirects with both functions, so
		// every position is classified on the same terms.
		//
		// Keyed on stmt.Redirs, not the merged set, and placed BEFORE `emitted` is
		// captured and before walkCmd runs: keying on the merged set would classify
		// an inherited substitution once per statement inside the construct, the
		// early capture keeps the redirect-only fallback's "the descent produced no
		// command" test about stmt.Cmd (`[[ -f <(echo hi) ]] > out.log` must still
		// grade the write), and descending before walkCmd resolves the inner command
		// against the cwd in effect BEFORE this statement's own `cd` (bash sets the
		// substitution's pipe up during word expansion).
		for _, r := range stmt.Redirs {
			descendProcSubsts(r)
			descendCmdSubsts(r)
		}
		if stmt.Cmd != nil {
			descendProcSubsts(stmt.Cmd)
			descendCmdSubsts(stmt.Cmd)
		}

		emitted := len(out)

		// A statement can be redirects and NOTHING else: bare `> f` (the
		// truncate idiom) parses to a Stmt with no Cmd at all. The shell still
		// creates/truncates f, so it must not fall out of the walk here — the
		// redirect-only fallback below grades it.
		if stmt.Cmd != nil {
			// A backgrounded statement (`cmd &`, `{ … ; } &`, `( … ) &`) runs in
			// a child shell, so any assignment it makes does not persist to the
			// enclosing scope. Bump the scope depth around the
			// descent so recordAssign skips those assignments. (A `( … )`
			// Subshell already bumps depth in walkCmd; the extra bump here for a
			// backgrounded subshell is harmless — depth is only ever tested for
			// > 0.)
			if stmt.Background {
				scopeDepth++
				walkCmd(stmt.Cmd, redirs)
				scopeDepth--
			} else {
				walkCmd(stmt.Cmd, redirs)
			}
		}

		// Redirect-only fallback. If this statement wrote redirects of its own
		// but the descent produced no command for them to ride on, the shell
		// still performs them and nothing else would grade them. That covers a
		// bare `> f`, and every construct that runs no external command —
		// `[[ … ]]`, `(( … ))`, `let`, `export A=1`, an empty `case`, a bare
		// `A=1` assignment. It is a real hole, not a curiosity:
		// `[[ -f x ]] > <out-of-repo> && echo hi` reduced to the single
		// allow-eligible `echo hi` and ALLOWed while the shell created the
		// out-of-repo file. Emit a synthetic redirect-only command so the paths
		// are graded on their own merits.
		//
		// Keyed on stmt.Redirs, not the merged set: when the redirects are
		// inherited, the enclosing statement that wrote them runs this same
		// check and covers the whole construct in one go.
		if walkErr == nil && len(stmt.Redirs) > 0 && len(out) == emitted {
			cc := curCC()
			sc := simpleCommand{}
			applyRedirs(&sc, redirs, knownVars, resolver, cc)
			// Nothing gradeable (every target was /dev/null and statically
			// resolvable, or the statement carried only heredocs / descriptor
			// duplications): emitting here would cost an otherwise-clean line a
			// defer for a redirect that names no file.
			if sc.hasRedirectToFile || len(sc.inputRedirectTargets) > 0 || sc.hasUnknownExpansion {
				sc.redirectOnly = true
				sc.args = []string{redirectOnlyProgram}
				sc.cwd = runningCWD
				sc.cwdInvalid = runningCWDInvalid
				sc.oldCWD = runningOldCWD
				sc.oldCWDInvalid = runningOldCWDInvalid
				out = append(out, sc)
			}
		}
	}

	for _, stmt := range file.Stmts {
		walkStmt(stmt, nil)
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
// resolver and cc thread the var-resolution sources (process env for
// $HOME/$USER/$TMPDIR, the tracked cwd for $PWD/$OLDPWD) into every
// literalWord call this reduction makes.
func reduceCallExpr(c *syntax.CallExpr, redirs []*syntax.Redirect, knownVars map[string]string, resolver varResolver, cc cwdCtx) (simpleCommand, error) {
	sc := simpleCommand{}

	applyRedirs(&sc, redirs, knownVars, resolver, cc)

	// An inline environment-assignment prefix on the CallExpr itself
	// (`AWS_ENDPOINT_URL=… aws …`, `GIT_SSH_COMMAND=… git …`) sets env for THIS
	// command only. The parser parks these on c.Assigns (separate from c.Args)
	// when a program token follows. Such a prefix can redirect egress, swap
	// identity, or inject a pager without ever touching argv, so the git/gh/aws
	// classifiers DENY on it. Record its presence; a bare assignment-only
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
		sc.argMeta = append(sc.argMeta, argMeta{exact: exact, staticPrefix: staticWordPrefix(w)})
	}

	// Strip leading `env` wrapper and its VAR=val args (§10). Repeat in case
	// of `env A=1 env B=2 cmd` (unusual but harmless to handle). The
	// `env VAR=val cmd` form parks the assignment in args (not c.Assigns), so
	// stripEnvWrapper reports whether it removed any assignment so the inline
	// flag is set for that form too.
	var strippedAssign bool
	before := len(sc.args)
	sc.args, strippedAssign = stripEnvWrapper(sc.args)
	// stripEnvWrapper only ever removes LEADING tokens, so dropping the same
	// count off the front keeps argMeta aligned with args.
	sc.argMeta = sc.argMeta[before-len(sc.args):]
	if strippedAssign {
		sc.hasInlineAssignment = true
	}

	return sc, nil
}

// mergeRedirs returns the effective redirect set for a statement: the redirects
// written on the statement itself, followed by those inherited from an enclosing
// compound statement. A redirect attached to a compound command applies to every
// command inside it, and nesting composes — bash performs BOTH opens, so the
// inner redirect does not cancel the outer one and both targets are graded.
//
// It always returns a fresh slice (or nil): appending onto stmt.Redirs directly
// could write into the parser's own backing array and leak one statement's
// inherited redirects into a sibling.
func mergeRedirs(own, inherited []*syntax.Redirect) []*syntax.Redirect {
	switch {
	case len(inherited) == 0:
		return own
	case len(own) == 0:
		return inherited
	}
	merged := make([]*syntax.Redirect, 0, len(own)+len(inherited))
	merged = append(merged, own...)
	merged = append(merged, inherited...)
	return merged
}

// redirectOnlyProgram is the display name carried in args[0] of a synthetic
// redirect-only command (simpleCommand.redirectOnly). It is deliberately not a
// real program name — it appears only in a decision message, where naming the
// shell redirect is what makes the message actionable ("'shell redirect' would
// read '/etc/passwd'"), and classifySimpleCommand branches on the redirectOnly
// flag before any program dispatch, so it is never matched against a rule table.
const redirectOnlyProgram = "shell redirect"

// applyRedirs grades one statement's redirects into sc: it sets
// hasRedirectToFile / hasUnknownExpansion and records the write destinations and
// input sources. Extracted from reduceCallExpr so the synthetic redirect-only
// command (a construct that runs no program yet still performs its redirects)
// grades them through EXACTLY this logic rather than a second, drifting copy.
//
// Redirects live on the enclosing *syntax.Stmt, not the CallExpr, and a compound
// statement's redirects reach here through mergeRedirs.
func applyRedirs(sc *simpleCommand, redirs []*syntax.Redirect, knownVars map[string]string, resolver varResolver, cc cwdCtx) {
	// Detect redirections to real files (anything other than /dev/null).
	for _, r := range redirs {
		if r.Word == nil {
			continue
		}
		target, exact := literalWord(r.Word, knownVars, resolver, cc)
		// A redirect target built from a non-anchor command substitution, an
		// OUTPUT process substitution, or an unresolved expansion (e.g.
		// `cmd > "$DYNAMIC"`) cannot be statically proven safe. Such a command
		// must not ride the allow track, so mark it as unknown-expansion.
		// This keeps the allow-aware classifiers (read-only utilities, git, gh,
		// …) from auto-allowing a command whose redirect introduces unprovable
		// behavior, even when its own arg words are all literal.
		//
		// An INPUT process substitution (`wc < <(grep x f)`) is deliberately not
		// one of those: literalWord reduces it to procSubstFD, the /dev/fd pipe
		// bash passes, so it stays exact here and the operand walks skip the
		// token. What keeps that sound is that walkStmt descends into every
		// redirect word's substitution, so the substituted command earns its own
		// verdict — `cat < <(cat ../sibling-repo/.env)` denies on the inner read,
		// the same as the argv spelling `comm -3 <(cat ../sibling-repo/.env) x`.
		if !exact {
			sc.hasUnknownExpansion = true
		}
		switch r.Op {
		case syntax.RdrOut, syntax.AppOut, syntax.RdrAll, syntax.AppAll, syntax.ClbOut:
			if target != "/dev/null" {
				sc.hasRedirectToFile = true
				// Record the destination so a classifier can GRADE it
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
			// veto's defer — strictly worse than the earlier status quo, in which
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
}

// stripEnvWrapper removes a leading `env` and any leading VAR=val tokens so
// the actual program is at args[0]. `env -i`, `env -u VAR`, and `env --` are
// handled by skipping their option args. It also reports whether any VAR=val
// assignment token was stripped, so the caller can flag the command as
// carrying an inline environment-assignment prefix: the `env VAR=val cmd`
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
// resolution succeeded, applying the documented precedence: an in-script static
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
// is a known, resolvable filesystem location. match reports whether
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
// resolveAnchorCmdSubst recognizes. Matching is exact: the substituted
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
		// instead of an unpinnable-path DEFER. It is NOT treated as a
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
		// (the tracked runningCWD), NOT ev.CWD — a preceding `cd` changes what a
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

// resolveAnchorCmdSubst reports whether a single command substitution matches
// one of anchorCommands, and if so, its resolved value. "Matches" means: the
// substituted program is a SINGLE statement (no `;`/`&&`/pipeline inside the
// substitution), and that statement is a plain CallExpr with no
// assignments/redirects whose argv equals an anchor form precisely. Any other
// shape (a compound substitution, a non-allowlisted command) is not recognized
// and returns ok=false, so the caller keeps its fail-closed behavior.
//
// It grades the SUBSTITUTION, not the word around it. That is what lets
// literalWord consult it per word-part, so an anchor resolves wherever it sits
// — bare (`$(git rev-parse --show-toplevel)`), wrapped in double quotes
// (`"$(…)"`, the spelling every style guide asks for because it survives a
// space in the path), embedded inline in a larger word (`"$(…)/.claude"`), or
// as a `cd` target. Recognizing more PLACES never widens what an anchor
// authorizes: the resolved value still runs through normal containment and the
// .git/ deny, exactly as when only a bare assignment RHS was recognized.
func resolveAnchorCmdSubst(cs *syntax.CmdSubst, rc *repoContext, runningCWD string, runningCWDInvalid bool) (string, bool) {
	if cs == nil || len(cs.Stmts) != 1 {
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

// anchorValue is resolveAnchorCmdSubst spelled against the cwdCtx literalWord
// already carries, so its per-word-part call sites read as one lookup.
func anchorValue(cs *syntax.CmdSubst, cc cwdCtx) (string, bool) {
	return resolveAnchorCmdSubst(cs, cc.rc, cc.cwd, cc.cwdInvalid)
}

// procSubstFD is the literal an INPUT process substitution (`<(cmd)`) reduces
// to. Bash replaces it with a `/dev/fd/N` pipe — never a filesystem path — so
// grading it as a path operand is a category error: the read tracks used to
// report `comm -3 <(…) <(…)` as "a path argument built from an expansion the
// gate cannot resolve statically" when there was no path to resolve at all.
//
// The two operand-containment walks (containPathOperands, containWriteOperands)
// skip this token, which is the single choke point every per-program operand
// grammar funnels through, so no grammar needs its own process-substitution
// case. The token is deliberately not a syntactically valid path (it carries
// `<` and `>`), so a command spelling it literally loses nothing by skipping
// containment on it.
//
// An OUTPUT process substitution (`>(cmd)`) keeps its conservative handling: it
// stays inexact, so its command can never ride the allow track.
const procSubstFD = "/dev/fd/<process-substitution>"

// literalWord returns the static literal value of a word and whether it is
// EXACT (no command substitution, no unresolved parameter expansion). A word
// like `"foo"` or `'bar'` or `foo` is exact; `$(date)` is not. A simple
// parameter expansion (`$VAR` / `${VAR}`) is exact when VAR is present in
// knownVars — i.e. it was assigned to a static literal earlier in the same
// parsed program — OR when VAR is one of the closed allowlist of names
// ($HOME, $USER, $TMPDIR, $PWD, $OLDPWD) resolveVar can resolve from
// its authoritative source; otherwise it is inexact (fail-closed for every
// other env var and for dynamically-assigned vars).
//
// expand.Literal with the resolveVar-backed environment resolves quoting,
// tilde, and resolvable parameter expansions but returns an error / partial
// result for command substitutions, which we treat as inexact (quoted
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
		case *syntax.CmdSubst:
			// An allowlisted anchor substitution resolves to a known filesystem
			// location, so the word stays exact and flows into normal
			// containment. Every other substitution is inexact as before.
			if _, ok := anchorValue(p, cc); !ok {
				exact = false
			}
		case *syntax.ProcSubst:
			// `<(cmd)` is a /dev/fd pipe, not a path — exact by construction (see
			// procSubstFD). `>(cmd)` keeps the conservative inexact handling.
			if p.Op != syntax.CmdIn {
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
				case *syntax.CmdSubst:
					// The quoted spelling of an anchor — `"$(git rev-parse
					// --show-toplevel)"`, alone or inline in a larger word — is
					// the one every style guide asks for, and it used to be the
					// one that failed.
					if _, ok := anchorValue(dq, cc); !ok {
						exact = false
					}
				default:
					exact = false
				}
			}
		default:
			// ArithmExp, ExtGlob, etc.
			exact = false
		}
	}

	cfg := &expand.Config{
		// Resolve a variable to its statically-known literal value when we
		// recorded one earlier in the program, or to its
		// authoritative-source value for the closed allowlist; unknown
		// names expand to "" (as before) and the fast-path loop above has
		// already marked the word inexact, so such a command cannot ride the
		// allow track and is not run through containment as if resolved.
		Env: expand.FuncEnviron(func(name string) string {
			v, _ := resolveVar(name, knownVars, resolver, cc)
			return v
		}),
		// Command substitution: an allowlisted anchor substitutes its resolved
		// filesystem location (the fast-path loop above kept the word exact for
		// exactly these); every other one substitutes nothing and the word is
		// already marked inexact.
		CmdSubst: func(w io.Writer, cs *syntax.CmdSubst) error {
			if v, ok := anchorValue(cs, cc); ok {
				_, err := io.WriteString(w, v)
				return err
			}
			return nil
		},
		// Process substitution (`<(cmd)` / `>(cmd)`): expand.Literal calls
		// cfg.ProcSubst unconditionally when it hits a *syntax.ProcSubst part,
		// so leaving this nil panics with a nil-pointer deref. An INPUT
		// substitution stands in as procSubstFD — the /dev/fd pipe bash actually
		// passes, which the operand walks skip rather than test as a path. An
		// OUTPUT substitution expands to nothing and stays inexact, so the
		// command can never ride the allow track.
		ProcSubst: func(ps *syntax.ProcSubst) (string, error) {
			if ps.Op == syntax.CmdIn {
				return procSubstFD, nil
			}
			return "", nil
		},
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
// will expand. A pathologically long static item list would otherwise
// walk the loop body once per item; above this cap we fall back to the
// conservative unbound walk (fail-closed on body uses of the loop variable)
// rather than doing unbounded work.
const maxForFanOut = 64

// staticForItems reports the resolved literal value of every item word in a
// `for x in <words>` header, and whether ALL of them are exact. It
// expands every statically-knowable form — brace expansion, a bare
// known-variable word (split on IFS the way bash word-splits an unquoted
// expansion), and a glob's containment-relevant directory prefix — and fans
// out to the cross product of item words. A single irreducibly dynamic item
// (command substitution, an unresolved parameter expansion, or a relative
// glob while cwdInvalid) makes the WHOLE list non-static, since the loop
// variable's value set is no longer fully known at parse time.
//
// cwdInvalid is whether the running cwd tracked through the walk is
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
// concrete literal values. It handles, in order:
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
// through the existing containment pipeline and gets its own worst-wins
// verdict rather than being silently dropped or bulk-escalated. staticExpandBraceFallback
// only understands the single unnested `{x,y,z}` comma-list grammar; a
// range form (`{1..9}`, `{a..z}`) it does not recognize is left to fail
// closed exactly as before — the accepted carve-out: a brace form the
// fallback does not handle falls closed rather than being guessed at.
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
// whether to distrust upstream's expand.Braces output shape — it does not
// itself resolve anything. A false positive here just means
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
// keeps the word inexact — it cannot ride the allow track, and lands on the
// unpinnable-path DEFER — rather than guess at bash's grammar.
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
// detect a static `for x in <words>` item that merely LOOKS like a
// literal but actually depends on runtime directory contents; it is not a
// general-purpose literalWord change.
func hasGlobMeta(s string) bool {
	return strings.ContainsAny(s, "*?[")
}

// globDirPrefix resolves a glob pattern's containment-relevant directory
// prefix, without reading the filesystem. Containment is pure
// path arithmetic: every path a glob like `*.md` or `src/*.go` can possibly
// match is a child of the pattern's directory prefix (the portion before the
// first path segment that itself contains a glob metacharacter), so binding
// the loop variable to that prefix directory makes every possible match
// share the prefix's own containment verdict — whichever containmentResult it
// earns — via the existing pathUnder equal-or-nested check.
//
// The scratchpad carve-out is the one verdict that is not purely
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
// operand against the command's own tracked running cwd (sc.cwd) at
// classification time — resolving it again here would be redundant, not more
// correct. This resolves the containment QUESTION without ever asking "which
// files actually exist".
//
// ok is false when the prefix cannot be safely resolved: cwdInvalid (an
// earlier dynamic `cd` invalidated the running cwd) means a RELATIVE
// glob cannot be safely anchored, so the caller keeps the whole for-list
// inexact and off the allow track, matching cdInvalidDefer's posture for every
// other relative operand. An absolute glob (`/abs/*.md`) is unaffected by
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
// or because it is one of the closed allowlist of names
// ($HOME, $USER, $TMPDIR, $PWD, $OLDPWD) resolveVar can resolve from its
// authoritative source (in-script assignment always takes precedence over
// these — see resolveVar's doc comment). Anything with extra logic — default
// (`${VAR:-x}`), length (`${#VAR}`), indirection (`${!VAR}`), array index,
// slice, replacement, modifiers, or special parameters ($1, $@, $?) — is NOT
// resolvable here and keeps the word inexact (fail-closed): the closed
// allowlist widens WHICH NAMES resolve, not which expansion forms are
// accepted. A name
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
