package main

import (
	"fmt"
	"path/filepath"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// The file-work redirect: a Bash line that reads, edits in place, or writes a
// file the way the Read, Edit and Write tools do is denied, and the reason
// names the tool to use instead. Its mode is the operator's
// redirect-bash-file-work setting (operator_carveout.go), worktree unless the
// config sets another; only an explicit `off` turns it off.
//
// Each simple command it covers earns a deny that classifyBash ranks with the
// line's other verdicts, below every other rule's deny.
//
// A read piped into a command other than a reader, a redirect of a program's
// own output, and search and listing (`grep`, `find`, `ls`) are never covered:
// Read, Edit and Write cannot do what those do, so a deny there would leave no
// tool to go to.

// fileWorkMode is the operator's setting for the file-work redirect.
type fileWorkMode string

const (
	// fileWorkOff never fires.
	fileWorkOff fileWorkMode = "off"
	// fileWorkWorktree fires only when the event's cwd is in a linked worktree.
	fileWorkWorktree fileWorkMode = "worktree"
	// fileWorkAlways fires for every caller.
	fileWorkAlways fileWorkMode = "always"
)

// fileWorkReaders are the programs whose file-operand form is a covered read.
// sed is one only in its `-n` form, and awk only with a line-selecting program,
// which fileWorkReader decides.
var fileWorkReaders = map[string]bool{
	"cat":  true,
	"head": true,
	"tail": true,
	"nl":   true,
	"less": true,
	"sed":  true,
	"awk":  true,
}

// stdoutSink is where a command's standard output goes, as far as grading a
// covered read needs to know.
type stdoutSink int

const (
	// sinkUnconsumed: the output reaches the terminal, a file, or another
	// reader, so the read is the whole of what the command does.
	sinkUnconsumed stdoutSink = iota
	// sinkConsumed: the output is piped into a command outside the readers,
	// or captured by a command or process substitution.
	sinkConsumed
)

// fileWorkEnabled reports whether the operator's mode turns the redirect on
// for this event. In worktree mode it is on only when rc, the context the
// event's cwd resolved to, is a linked worktree; a cwd that resolved to no
// repository leaves it off. An unknown mode's warning is logged here, where
// the mode is consulted.
func fileWorkEnabled(ev *Event, rc *repoContext) bool {
	cfg := ev.config()
	if cfg.fileWorkWarning != "" {
		logWarning(ev, "config:"+redirectBashFileWorkKey, cfg.fileWorkWarning)
	}
	switch cfg.fileWork {
	case fileWorkAlways:
		return true
	case fileWorkWorktree:
		return rc != nil && rc.isLinkedWorktree()
	}
	return false
}

// fileWorkDenies returns the deny each covered simple command in the parsed
// line earns, keyed by its call.
func fileWorkDenies(file *syntax.File) map[*syntax.CallExpr]Decision {
	w := &fileWorkWalker{denies: map[*syntax.CallExpr]Decision{}}
	for _, s := range file.Stmts {
		w.stmt(s, sinkUnconsumed, false)
	}
	return w.denies
}

// fileWorkWalker visits every statement of a line, including those inside
// pipelines, lists, subshells, blocks, control flow, function bodies and
// substitutions, carrying where each statement's output goes.
type fileWorkWalker struct {
	denies map[*syntax.CallExpr]Decision
}

// stmt grades s and then every statement beneath it. sink is where s's output
// goes; a stdout redirect to a file on s overrides it, and the left side of a
// pipe takes the sink pipeSink gives it. heredocIn says s's standard input is
// a pipe from a here-document fed to cat.
func (w *fileWorkWalker) stmt(s *syntax.Stmt, sink stdoutSink, heredocIn bool) {
	if _, ok := stdoutFileTarget(s); ok {
		sink = sinkUnconsumed
	}
	if call, ok := s.Cmd.(*syntax.CallExpr); ok {
		if d, ok := gradeFileWorkCall(s, call, sink, heredocIn); ok {
			w.denies[call] = d
		}
	}
	if bc, ok := s.Cmd.(*syntax.BinaryCmd); ok && (bc.Op == syntax.Pipe || bc.Op == syntax.PipeAll) {
		w.stmt(bc.X, pipeSink(bc.Y), false)
		w.stmt(bc.Y, sink, heredocCatStmt(bc.X))
		for _, r := range s.Redirs {
			w.substitutions(r)
		}
		return
	}
	syntax.Walk(s, func(n syntax.Node) bool {
		switch x := n.(type) {
		case *syntax.Stmt:
			if x == s {
				return true
			}
			w.stmt(x, sink, false)
			return false
		case *syntax.CmdSubst:
			for _, st := range x.Stmts {
				w.stmt(st, sinkConsumed, false)
			}
			return false
		case *syntax.ProcSubst:
			for _, st := range x.Stmts {
				w.stmt(st, sinkConsumed, false)
			}
			return false
		}
		return true
	})
}

// substitutions walks the statements of every substitution beneath n.
func (w *fileWorkWalker) substitutions(n syntax.Node) {
	syntax.Walk(n, func(n syntax.Node) bool {
		switch x := n.(type) {
		case *syntax.CmdSubst:
			for _, st := range x.Stmts {
				w.stmt(st, sinkConsumed, false)
			}
			return false
		case *syntax.ProcSubst:
			for _, st := range x.Stmts {
				w.stmt(st, sinkConsumed, false)
			}
			return false
		}
		return true
	})
}

// pipeSink is the sink for a command piped into y: consumed unless the first
// command y runs is itself a reader. A first command the walk cannot name — a
// loop, a conditional — consumes the stream.
func pipeSink(y *syntax.Stmt) stdoutSink {
	call := leftmostCall(y)
	if call == nil {
		return sinkConsumed
	}
	prog, args := fileWorkArgv(call)
	if _, ok := fileWorkReader(prog, args); ok {
		return sinkUnconsumed
	}
	return sinkConsumed
}

// leftmostCall is the first simple command a statement runs, or nil when the
// statement starts with anything else.
func leftmostCall(s *syntax.Stmt) *syntax.CallExpr {
	switch c := s.Cmd.(type) {
	case *syntax.CallExpr:
		return c
	case *syntax.BinaryCmd:
		return leftmostCall(c.X)
	case *syntax.Block:
		if len(c.Stmts) > 0 {
			return leftmostCall(c.Stmts[0])
		}
	case *syntax.Subshell:
		if len(c.Stmts) > 0 {
			return leftmostCall(c.Stmts[0])
		}
	}
	return nil
}

// gradeFileWorkCall grades one statement that runs a simple command: an
// in-place edit or an authored write anywhere, and a covered read whose output
// sink leaves unconsumed. A sed past the parse limit earns the parse-limit deny
// (sedForkLimitDeny) instead. heredocIn is as for fileWorkWalker.stmt. It
// returns the deny the statement earns, and false when it earns none.
func gradeFileWorkCall(s *syntax.Stmt, call *syntax.CallExpr, sink stdoutSink, heredocIn bool) (Decision, bool) {
	prog, args := fileWorkArgv(call)
	if prog == "" {
		return Decision{}, false
	}

	if prog == "sed" {
		if d, hit := sedForkLimitDeny(args); hit {
			return d, true
		}
	}

	if fileWorkInPlace(prog, args) {
		return deny("bash-file-work:edit", fmt.Sprintf(
			"Blocked: `%s` edits a file in place from Bash — use the Edit tool instead. Read the file, then "+
				"give Edit the exact text to replace and its replacement, with replace_all for every "+
				"occurrence.%s", inPlaceSpelling(prog), fileWorkSettingNote())), true
	}

	if target, ok := stdoutFileTarget(s); ok && fileWorkAuthoredWrite(prog, args, s) {
		return deny("bash-file-work:write", fmt.Sprintf(
			"Blocked: `%s` writes text you wrote yourself into %s through a shell redirect — use the Write "+
				"tool instead, which takes the file's path and its whole content. To add to a file that "+
				"already exists, Read it and use Edit.%s", prog, target, fileWorkSettingNote())), true
	}
	if prog == "tee" && (hasHeredoc(s) || heredocIn) {
		if target, ok := teeFileTarget(args); ok {
			return deny("bash-file-work:write", fmt.Sprintf(
				"Blocked: a here-document fed to `tee %s` writes text you wrote yourself into a file — use the "+
					"Write tool instead, which takes the file's path and its whole content. To add to a file "+
					"that already exists, Read it and use Edit.%s", target, fileWorkSettingNote())), true
		}
	}

	if sink == sinkUnconsumed {
		if hasFile, ok := fileWorkReader(prog, args); ok && hasFile {
			return deny("bash-file-work:read", fmt.Sprintf(
				"Blocked: `%s` reads a file from Bash — use the Read tool instead. Read takes the file's path, "+
					"plus an offset and a limit for a range of lines, which covers what head, tail, sed -n, "+
					"nl and a line-selecting awk select. A read piped into a command that consumes it, such as `cat f | jq .`, is not "+
					"refused.%s", prog, fileWorkSettingNote())), true
		}
	}
	return Decision{}, false
}

// fileWorkSettingNote names the setting that controls the redirect, so a human
// reading the deny knows where it comes from, whether or not the config file
// exists.
func fileWorkSettingNote() string {
	return fmt.Sprintf(" This redirect is controlled by %s in %s.", redirectBashFileWorkKey,
		operatorCarveOutConfigDisplayPath)
}

// fileWorkArgv returns a call's program name, with any `env` wrapper and
// assignment prefix stripped and any directory dropped, and its arguments. A
// word the gate cannot pin contributes its leading static text only, which is
// enough to tell a flag from an operand.
func fileWorkArgv(call *syntax.CallExpr) (string, []string) {
	words := make([]string, len(call.Args))
	for i, w := range call.Args {
		words[i] = staticWordPrefix(w)
	}
	words, _ = stripEnvWrapper(words)
	if len(words) == 0 || words[0] == "" {
		return "", nil
	}
	return filepath.Base(words[0]), words[1:]
}

// fileWorkReader reports whether prog with args names at least one file operand
// (readFileOperands, readonly_util.go), and whether it is a reader. sed is
// one only with -n (sedQuiet, readonly_util.go) and not in place, whether or
// not the gate can grade its script whole. awk is one only when awkSelectsLines
// accepts its argv.
func fileWorkReader(prog string, args []string) (hasFile bool, isReader bool) {
	if !fileWorkReaders[prog] {
		return false, false
	}
	if prog == "sed" && (!sedQuiet(args) || fileWorkInPlace(prog, args)) {
		return false, false
	}
	if prog == "awk" && !awkSelectsLines(args) {
		return false, false
	}
	return len(readFileOperands(prog, args)) > 0, true
}

// awkSelectsLines reports whether an awk argv only selects lines of its input,
// which Read with an offset and a limit, or Read of the whole file, also does:
// no option, a program awkLineSelector accepts, and no `var=value` operand.
// Anything more — a field separator, an assignment, printf, a field — is a
// transform whose output Read cannot produce.
func awkSelectsLines(args []string) bool {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") || !awkLineSelector(args[0]) {
		return false
	}
	for _, a := range args[1:] {
		if isAssignment(a) {
			return false
		}
	}
	return true
}

// awkLineSelector reports whether an awk program is a pattern alone, or a
// pattern followed by `{print}` or `{print $0}`, either one optionally ending
// in `;`. The pattern is a selector, or a range of two selectors joined by a
// comma; a selector is a comparison of NR with a decimal number, or a bare
// /re/.
func awkLineSelector(prog string) bool {
	rest, ok := awkSelector(strings.TrimSpace(prog))
	if !ok {
		return false
	}
	rest = strings.TrimSpace(rest)
	if strings.HasPrefix(rest, ",") {
		if rest, ok = awkSelector(strings.TrimSpace(rest[1:])); !ok {
			return false
		}
		rest = strings.TrimSpace(rest)
	}
	if rest == "" {
		return true
	}
	if !strings.HasPrefix(rest, "{") || !strings.HasSuffix(rest, "}") {
		return false
	}
	body := strings.TrimSpace(rest[1 : len(rest)-1])
	body = strings.TrimSpace(strings.TrimSuffix(body, ";"))
	if !strings.HasPrefix(body, "print") {
		return false
	}
	arg := strings.TrimSpace(body[len("print"):])
	return arg == "" || arg == "$0"
}

// awkSelector consumes one selector from the front of s — `NR` compared with a
// decimal number, or a /re/ — and returns what follows it.
func awkSelector(s string) (string, bool) {
	if strings.HasPrefix(s, "/") {
		return awkRegexEnd(s)
	}
	if !strings.HasPrefix(s, "NR") {
		return "", false
	}
	s = strings.TrimSpace(s[len("NR"):])
	op := ""
	for _, o := range []string{"==", "!=", "<=", ">=", "<", ">"} {
		if strings.HasPrefix(s, o) {
			op = o
			break
		}
	}
	if op == "" {
		return "", false
	}
	s = strings.TrimSpace(s[len(op):])
	n := 0
	for n < len(s) && s[n] >= '0' && s[n] <= '9' {
		n++
	}
	if n == 0 {
		return "", false
	}
	return s[n:], true
}

// awkRegexEnd consumes a /re/ from the front of s, which starts with its
// opening slash, and returns what follows the closing one. A backslash escapes
// the next character, and a slash inside a bracket expression does not close
// the regex.
func awkRegexEnd(s string) (string, bool) {
	inBracket := false
	for i := 1; i < len(s); i++ {
		switch c := s[i]; {
		case c == '\\':
			i++
		case c == '[' && !inBracket:
			inBracket = true
			if i+1 < len(s) && s[i+1] == ']' {
				i++
			}
		case c == ']' && inBracket:
			inBracket = false
		case c == '/' && !inBracket:
			return s[i+1:], true
		}
	}
	return "", false
}

// fileWorkInPlace reports whether prog with args edits a file in place: sed's
// in-place form (sedInPlace, readonly_util.go), `perl -i`, or gawk's
// `-i inplace`.
func fileWorkInPlace(prog string, args []string) bool {
	switch prog {
	case "sed":
		return sedInPlace(args)
	case "perl":
		return perlInPlace(args)
	case "awk":
		return awkInPlace(args)
	}
	return false
}

// awkInPlace reports whether awk's options, which end at the first argument
// that is not one, load gawk's inplace extension: `-i inplace`, `-iinplace`,
// `--include inplace` or `--include=inplace`, the library also spelled
// `inplace.awk`.
func awkInPlace(args []string) bool {
	inplace := func(lib string) bool { return lib == "inplace" || lib == "inplace.awk" }
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" || !strings.HasPrefix(a, "-") || a == "-" {
			return false
		}
		switch {
		case a == "-i" || a == "--include":
			if i+1 < len(args) && inplace(args[i+1]) {
				return true
			}
			i++
		case strings.HasPrefix(a, "--include="):
			if inplace(strings.TrimPrefix(a, "--include=")) {
				return true
			}
		case strings.HasPrefix(a, "-i"):
			if inplace(a[2:]) {
				return true
			}
		case awkOperandValueFlags[a]:
			i++
		}
	}
	return false
}

// perlInPlace reports whether perl's switches, which end at the first argument
// that is not one, carry -i. A switch whose value is the rest of its cluster
// or the next argument ends the cluster.
func perlInPlace(args []string) bool {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" || !strings.HasPrefix(a, "-") || a == "-" {
			return false
		}
		for j := 1; j < len(a); j++ {
			c := a[j]
			if c == 'i' {
				return true
			}
			if c == 'e' || c == 'E' {
				if j == len(a)-1 {
					i++
				}
				break
			}
			if strings.IndexByte("IMmxdFC", c) >= 0 {
				break
			}
		}
	}
	return false
}

// inPlaceSpelling is how the edit deny names the command.
func inPlaceSpelling(prog string) string {
	switch prog {
	case "perl":
		return "perl -i"
	case "awk":
		return "awk -i inplace"
	}
	return "sed -i"
}

// fileWorkAuthoredWrite reports whether a statement whose output goes to a
// file writes text the agent supplied: echo or printf, or cat reading a
// here-document.
func fileWorkAuthoredWrite(prog string, args []string, s *syntax.Stmt) bool {
	switch prog {
	case "echo", "printf":
		return true
	case "cat":
		return heredocCat(prog, args, s)
	}
	return false
}

// heredocCat reports whether a statement runs cat on a here-document and on
// no file.
func heredocCat(prog string, args []string, s *syntax.Stmt) bool {
	return prog == "cat" && hasHeredoc(s) && len(readFileOperands(prog, args)) == 0
}

// heredocCatStmt reports whether s is a cat of a here-document whose output
// goes down the pipe it sits on rather than to a file of its own.
func heredocCatStmt(s *syntax.Stmt) bool {
	call, ok := s.Cmd.(*syntax.CallExpr)
	if !ok {
		return false
	}
	if _, ok := stdoutFileTarget(s); ok {
		return false
	}
	prog, args := fileWorkArgv(call)
	return heredocCat(prog, args, s)
}

// stdoutFileTarget returns the file a statement's own redirect sends its
// standard output to. A stderr redirect, a descriptor duplication, a /dev/*
// target and a target with no static leading text are not files here.
func stdoutFileTarget(s *syntax.Stmt) (string, bool) {
	for _, r := range s.Redirs {
		switch r.Op {
		case syntax.RdrOut, syntax.AppOut, syntax.RdrClob, syntax.RdrAll, syntax.AppAll:
		default:
			continue
		}
		if r.N != nil && r.N.Value != "1" {
			continue
		}
		target := staticWordPrefix(r.Word)
		if target == "" || strings.HasPrefix(target, "/dev/") {
			continue
		}
		return target, true
	}
	return "", false
}

// hasHeredoc reports whether a statement reads a here-document.
func hasHeredoc(s *syntax.Stmt) bool {
	for _, r := range s.Redirs {
		if r.Op == syntax.Hdoc || r.Op == syntax.DashHdoc {
			return true
		}
	}
	return false
}

// teeFileTarget returns the first of tee's write destinations
// (teeTargets, classify_inrepo_write.go) that is not a /dev/* path.
func teeFileTarget(args []string) (string, bool) {
	for _, t := range teeTargets(args) {
		if t != "" && !strings.HasPrefix(t, "/dev/") {
			return t, true
		}
	}
	return "", false
}
