package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// The file-work redirect: a Bash line that reads, edits in place, or writes a
// file the way the Read, Edit and Write tools do is denied, and the reason
// names the tool to use instead. It is off unless the operator's config turns
// it on (loadRedirectBashFileWork, operator_carveout.go).
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
// sed is one only in its `-n` form, which fileWorkReader decides.
var fileWorkReaders = map[string]bool{
	"cat":  true,
	"head": true,
	"tail": true,
	"nl":   true,
	"less": true,
	"sed":  true,
}

// fileWorkShortValueFlags lists, per reader, the short options that take a
// value, so the value is not counted as a file operand.
var fileWorkShortValueFlags = map[string]string{
	"cat":  "",
	"head": "nc",
	"tail": "ncbs",
	"nl":   "bdfhilnsvw",
	"less": "bhjkoOpPtTxyz#",
	"sed":  "efl",
}

// fileWorkLongValueFlags lists, per reader, the long options that take their
// value as the next token when it is not joined with `=`.
var fileWorkLongValueFlags = map[string]map[string]bool{
	"head": {"--lines": true, "--bytes": true},
	"tail": {"--lines": true, "--bytes": true, "--sleep-interval": true, "--pid": true,
		"--max-unchanged-stats": true},
	"nl": {"--body-numbering": true, "--section-delimiter": true, "--footer-numbering": true,
		"--header-numbering": true, "--line-increment": true, "--join-blank-lines": true,
		"--number-format": true, "--number-separator": true, "--starting-line-number": true,
		"--number-width": true},
	"less": {"--pattern": true, "--tag": true, "--tabs": true, "--shift": true, "--window": true,
		"--log-file": true, "--LOG-FILE": true, "--tag-file": true, "--jump-target": true},
	"sed": {"--expression": true, "--file": true, "--line-length": true},
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

// redirectBashFileWork returns the file-work deny for a Bash line when the
// operator's mode enables it for this event and the line holds a covered
// shape. In worktree mode it fires only when the event's cwd resolves to a
// linked worktree; a cwd that resolves to no repository does not fire.
func redirectBashFileWork(command string, ev *Event) (Decision, bool) {
	switch loadRedirectBashFileWork(operatorCarveOutConfigPath(), os.Stderr) {
	case fileWorkAlways:
	case fileWorkWorktree:
		rc, err := resolveRepoContext(ev.CWD)
		if err != nil || !rc.isLinkedWorktree() {
			return Decision{}, false
		}
	default:
		return Decision{}, false
	}
	file, err := syntax.NewParser(syntax.KeepComments(false)).Parse(strings.NewReader(command), "")
	if err != nil {
		return Decision{}, false
	}
	return findFileWork(file)
}

// findFileWork returns the deny for the first covered shape in the parsed line.
func findFileWork(file *syntax.File) (Decision, bool) {
	w := &fileWorkWalker{}
	for _, s := range file.Stmts {
		w.stmt(s, sinkUnconsumed)
	}
	return w.found, w.hit
}

// fileWorkWalker visits every statement of a line, including those inside
// pipelines, lists, subshells, blocks, control flow, function bodies and
// substitutions, carrying where each statement's output goes.
type fileWorkWalker struct {
	found Decision
	hit   bool
}

// stmt grades s and then every statement beneath it, recording the first
// covered shape and visiting nothing after it. sink is where s's output goes; a
// stdout redirect to a file on s overrides it, and the left side of a pipe
// takes the sink pipeSink gives it.
func (w *fileWorkWalker) stmt(s *syntax.Stmt, sink stdoutSink) {
	if w.hit {
		return
	}
	if _, ok := stdoutFileTarget(s); ok {
		sink = sinkUnconsumed
	}
	if d, ok := gradeFileWorkStmt(s, sink); ok {
		w.found, w.hit = d, true
		return
	}
	if bc, ok := s.Cmd.(*syntax.BinaryCmd); ok && (bc.Op == syntax.Pipe || bc.Op == syntax.PipeAll) {
		w.stmt(bc.X, pipeSink(bc.Y))
		w.stmt(bc.Y, sink)
		for _, r := range s.Redirs {
			w.substitutions(r)
		}
		return
	}
	syntax.Walk(s, func(n syntax.Node) bool {
		if w.hit {
			return false
		}
		switch x := n.(type) {
		case *syntax.Stmt:
			if x == s {
				return true
			}
			w.stmt(x, sink)
			return false
		case *syntax.CmdSubst:
			for _, st := range x.Stmts {
				w.stmt(st, sinkConsumed)
			}
			return false
		case *syntax.ProcSubst:
			for _, st := range x.Stmts {
				w.stmt(st, sinkConsumed)
			}
			return false
		}
		return true
	})
}

// substitutions walks the statements of every substitution beneath n.
func (w *fileWorkWalker) substitutions(n syntax.Node) {
	syntax.Walk(n, func(n syntax.Node) bool {
		if w.hit {
			return false
		}
		switch x := n.(type) {
		case *syntax.CmdSubst:
			for _, st := range x.Stmts {
				w.stmt(st, sinkConsumed)
			}
			return false
		case *syntax.ProcSubst:
			for _, st := range x.Stmts {
				w.stmt(st, sinkConsumed)
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

// gradeFileWorkStmt grades one statement that runs a simple command: an
// in-place edit or an authored write anywhere, and a covered read whose output
// sink leaves unconsumed.
func gradeFileWorkStmt(s *syntax.Stmt, sink stdoutSink) (Decision, bool) {
	call, ok := s.Cmd.(*syntax.CallExpr)
	if !ok {
		return Decision{}, false
	}
	prog, args := fileWorkArgv(call)
	if prog == "" {
		return Decision{}, false
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
	if prog == "tee" && hasHeredoc(s) {
		if target, ok := teeFileOperand(args); ok {
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
					"plus an offset and a limit for a range of lines, which covers what head, tail, sed -n and "+
					"nl select. A read piped into a command that consumes it, such as `cat f | jq .`, is not "+
					"refused.%s", prog, fileWorkSettingNote())), true
		}
	}
	return Decision{}, false
}

// fileWorkSettingNote names the setting that turned the redirect on, so a
// human reading the deny knows where it comes from.
func fileWorkSettingNote() string {
	return fmt.Sprintf(" This redirect is enabled by %s in %s.", redirectBashFileWorkKey,
		operatorCarveOutConfigPath())
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

// fileWorkReader reports whether prog with args is a reader, and whether it
// names at least one file operand. `-` names standard input, not a file.
func fileWorkReader(prog string, args []string) (hasFile bool, isReader bool) {
	if !fileWorkReaders[prog] {
		return false, false
	}
	if prog == "sed" && (!sedQuiet(args) || fileWorkInPlace(prog, args)) {
		return false, false
	}
	operands := fileWorkOperands(prog, args)
	if prog == "sed" && !sedScriptFromFlag(args) && len(operands) > 0 {
		operands = operands[1:]
	}
	for _, op := range operands {
		if op == "-" {
			continue
		}
		if (prog == "less" || prog == "tail") && strings.HasPrefix(op, "+") {
			continue
		}
		return true, true
	}
	return false, true
}

// fileWorkOperands returns a reader's non-option arguments, skipping the values
// of the options fileWorkShortValueFlags and fileWorkLongValueFlags list.
func fileWorkOperands(prog string, args []string) []string {
	var out []string
	shortValue := fileWorkShortValueFlags[prog]
	longValue := fileWorkLongValueFlags[prog]
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--":
			return append(out, args[i+1:]...)
		case strings.HasPrefix(a, "--"):
			if !strings.Contains(a, "=") && longValue[a] {
				i++
			}
		case strings.HasPrefix(a, "-") && a != "-":
			for j := 1; j < len(a); j++ {
				if strings.IndexByte(shortValue, a[j]) >= 0 {
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

// sedQuiet reports whether a sed invocation carries -n (or --quiet/--silent).
func sedQuiet(args []string) bool {
	return sedHasShortFlag(args, "n") || sedHasLongFlag(args, "--quiet", "--silent")
}

// sedScriptFromFlag reports whether sed's script comes from -e or -f, so its
// first operand is a file rather than the script.
func sedScriptFromFlag(args []string) bool {
	return sedHasShortFlag(args, "ef") || sedHasLongFlag(args, "--expression", "--file")
}

// sedHasShortFlag reports whether any of the letters appears as a sed short
// option, reading each cluster up to the first option that takes a value.
func sedHasShortFlag(args []string, letters string) bool {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			return false
		}
		if !strings.HasPrefix(a, "-") || strings.HasPrefix(a, "--") || a == "-" {
			continue
		}
		for j := 1; j < len(a); j++ {
			if strings.IndexByte(letters, a[j]) >= 0 {
				return true
			}
			if strings.IndexByte(fileWorkShortValueFlags["sed"], a[j]) >= 0 {
				if j == len(a)-1 {
					i++
				}
				break
			}
			if a[j] == 'i' || a[j] == 'I' {
				// -i's suffix is the rest of the cluster.
				break
			}
		}
	}
	return false
}

// sedHasLongFlag reports whether any of the long options appears, bare or
// joined with `=`.
func sedHasLongFlag(args []string, names ...string) bool {
	for _, a := range args {
		if a == "--" {
			return false
		}
		for _, n := range names {
			if a == n || strings.HasPrefix(a, n+"=") {
				return true
			}
		}
	}
	return false
}

// fileWorkInPlace reports whether prog with args edits a file in place:
// `sed -i` (and BSD `-I`, and --in-place) or `perl -i`.
func fileWorkInPlace(prog string, args []string) bool {
	switch prog {
	case "sed":
		return sedHasShortFlag(args, "iI") || sedHasLongFlag(args, "--in-place")
	case "perl":
		return perlInPlace(args)
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
	if prog == "perl" {
		return "perl -i"
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
		return hasHeredoc(s) && len(fileWorkOperands(prog, args)) == 0
	}
	return false
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

// teeFileOperand returns tee's first operand that names a file: not an option
// and not a /dev/* path.
func teeFileOperand(args []string) (string, bool) {
	endOpts := false
	for _, a := range args {
		if !endOpts && a == "--" {
			endOpts = true
			continue
		}
		if !endOpts && strings.HasPrefix(a, "-") {
			continue
		}
		if a == "" || strings.HasPrefix(a, "/dev/") {
			continue
		}
		return a, true
	}
	return "", false
}
