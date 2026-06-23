package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// logEnvVar overrides the evolution-log path (used by tests). When set, the
// gate appends to that file instead of the default location.
const logEnvVar = "PERMISSION_GATE_LOG"

// logRecord is one structured, append-only evolution-log entry (§7). It
// carries enough to evolve the rule set: when, who, what tool, the classified
// operation, the resolved repo/worktree context, the bucket, and the raw
// command/target.
type logRecord struct {
	Timestamp string `json:"ts"`
	AgentType string `json:"agent_type"`
	ToolName  string `json:"tool_name"`
	Operation string `json:"operation"`
	Bucket    string `json:"bucket"`
	CWD       string `json:"cwd"`
	Raw       string `json:"raw"`
}

// logEvent appends one record for an ASK or DENY decision (§7). Any failure
// to log is swallowed: logging MUST NEVER change the verdict or crash the
// gate. (A logging failure that bubbled up would otherwise turn an allow into
// a fail-closed block, or worse.)
func logEvent(ev *Event, d Decision) {
	defer func() { _ = recover() }()

	rec := logRecord{
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		AgentType: ev.AgentType,
		ToolName:  ev.ToolName,
		Operation: d.Operation,
		Bucket:    string(d.Bucket),
		CWD:       ev.CWD,
		Raw:       string(ev.ToolInput),
	}

	line, err := json.Marshal(rec)
	if err != nil {
		return
	}

	path := logPath()
	if path == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.Write(append(line, '\n'))
}

// logPath returns the evolution-log file path: the PERMISSION_GATE_LOG
// override if set, else ~/.claude/logs/permission-gate.jsonl. Returns "" when
// no home directory can be determined (logging is then skipped).
func logPath() string {
	if p := os.Getenv(logEnvVar); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".claude", "logs", "permission-gate.jsonl")
}
