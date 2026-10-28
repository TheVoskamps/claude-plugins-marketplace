package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// logEnvVar overrides the evolution-log path (used by tests). When set, the
// gate appends to that file instead of the default location.
const logEnvVar = "PERMISSION_GATE_LOG"

// logRecord is one structured, append-only evolution-log entry. It
// carries enough to evolve the rule set: when, who, what tool, the classified
// operation, the gate's own analysis of that operation, the resolved
// repo/worktree context, the bucket, and the raw command/target.
//
// Analysis is the Decision's Reason — the gate's account of what it could and
// could not establish ("the destination is built from an expansion or command
// substitution"). The operation label alone says which taxonomy row was
// hit; the analysis says WHY, which is what makes a DEFER record usable as a
// tuning input for the downstream automode evaluator rather than a bare tally.
// It is empty for a bare deferToPipeline, which by construction has no account
// to give. A warning record (logWarning) carries the warning text there instead,
// under the logWarningBucket bucket.
type logRecord struct {
	Timestamp string `json:"ts"`
	AgentType string `json:"agent_type"`
	ToolName  string `json:"tool_name"`
	Operation string `json:"operation"`
	Bucket    string `json:"bucket"`
	Analysis  string `json:"analysis"`
	CWD       string `json:"cwd"`
	Raw       string `json:"raw"`
}

// logEvent appends one record for an ASK, DENY or DEFER decision. Any
// failure to log is swallowed: logging MUST NEVER change the verdict or crash
// the gate. (A logging failure that bubbled up would otherwise turn an allow
// into a fail-closed block, or worse.)
func logEvent(ev *Event, d Decision) {
	defer func() { _ = recover() }()

	appendLogRecord(logRecord{
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		AgentType: ev.AgentType,
		ToolName:  ev.ToolName,
		Operation: d.Operation,
		Bucket:    string(d.Bucket),
		Analysis:  d.Reason,
		CWD:       ev.CWD,
		Raw:       string(ev.ToolInput),
	})
}

// logWarningBucket is the bucket a warning record carries. It is no verdict:
// a warning is about the gate's own input, not about the call it rode on.
const logWarningBucket = "warning"

// logWarning appends a warning record to the evolution log, under the same
// never-change-the-verdict rule as logEvent. A panic while writing it is
// reported on stderr, which neither the exit status nor the stdout decision
// carries, and the gate goes on to its verdict.
func logWarning(ev *Event, operation string, warning string) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "permission-gate could not log the warning %q (%v)\n", warning, r)
		}
	}()

	appendLogRecord(logRecord{
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		AgentType: ev.AgentType,
		ToolName:  ev.ToolName,
		Operation: operation,
		Bucket:    logWarningBucket,
		Analysis:  warning,
		CWD:       ev.CWD,
		Raw:       string(ev.ToolInput),
	})
}

// appendLogRecord writes one record as a line of the evolution log, swallowing
// every failure.
func appendLogRecord(rec logRecord) {
	line, err := json.Marshal(rec)
	if err != nil {
		return
	}

	path := logPath()
	if path == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return
	}
	// Cleaning the path as given would drop a `..` lexically, before the
	// kernel follows a symlink ahead of it, and so move the log. Resolving the
	// directory's symlinks first leaves a path that cleans to the file the
	// kernel opens for the path as given.
	dir, file := filepath.Split(path)
	dir, err = filepath.EvalSymlinks(dir)
	if err != nil {
		return
	}
	f, err := os.OpenFile(filepath.Clean(filepath.Join(dir, file)), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer func() { _ = f.Close() }()
	_, _ = f.Write(append(line, '\n'))
}

// logPath returns the evolution-log file path: the PERMISSION_GATE_LOG
// override if set, else ~/.claude/logs/permission-gate.jsonl. Returns "" when
// the path it would compose is one the gate cannot place (logging is then
// skipped).
//
// The override is graded with the same predicate as a home, for the same
// reason: an override that is not an absolute path composes against whatever
// directory the gate happens to be running in — the worktree — which is the
// outcome the home predicate exists to prevent. An ABSOLUTE override is the
// operator's own explicit destination and reads no home, so an unusable home
// does not withhold it.
func logPath() string {
	if p := os.Getenv(logEnvVar); p != "" {
		if !homeUsable(p, nil) {
			return ""
		}
		return p
	}
	home, ok := processHome()
	if !ok {
		return ""
	}
	return filepath.Join(home, ".claude", "logs", "permission-gate.jsonl")
}
