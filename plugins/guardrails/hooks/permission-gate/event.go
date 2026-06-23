package main

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Event is the PreToolUse hook event read from stdin. Only the fields the
// gate consumes are modeled; unknown fields are ignored by encoding/json.
//
// Field names follow the harness's snake_case payload (verified against the
// existing shell hooks, which read .hook_event_name / .tool_name /
// .tool_input / .cwd). The "issue #78" regression in test-deny-gate.sh is a
// reminder that the camelCase guess is wrong.
type Event struct {
	HookEventName string          `json:"hook_event_name"`
	ToolName      string          `json:"tool_name"`
	ToolInput     json.RawMessage `json:"tool_input"`
	// CWD is the EVENT's working directory. Engine B MUST resolve git context
	// against THIS directory, not the hook process's own cwd (§8).
	CWD string `json:"cwd"`
	// AgentType distinguishes the main session from a subagent. Some rules
	// (#120) are conditioned on the agent being a subagent. The harness has
	// used a few key names across versions; parseEvent normalizes them.
	AgentType string `json:"agent_type"`
}

// bashInput models tool_input for the Bash tool.
type bashInput struct {
	Command string `json:"command"`
}

// fileInput models tool_input for file tools (Read/Write/Edit/MultiEdit/
// NotebookEdit). Different tools spell the path field differently; all known
// spellings are captured so path extraction is fail-closed-complete.
type fileInput struct {
	FilePath     string `json:"file_path"`
	Path         string `json:"path"`
	NotebookPath string `json:"notebook_path"`
}

// parseEvent decodes the stdin payload. A decode failure is a fail-closed
// condition (the caller blocks via exit 2). It also normalizes the several
// agent-type spellings the harness has used.
func parseEvent(raw []byte) (*Event, error) {
	if len(raw) == 0 {
		return nil, errors.New("empty event payload")
	}
	var e Event
	if err := json.Unmarshal(raw, &e); err != nil {
		return nil, fmt.Errorf("decode event: %w", err)
	}
	if e.ToolName == "" {
		return nil, errors.New("event has no tool_name")
	}
	// Normalize agent type from alternate key spellings the harness has
	// shipped across versions, so the subagent-conditioned rules (#120) fire
	// regardless of which key the installed version uses.
	if e.AgentType == "" {
		var alt struct {
			AgentType    string `json:"agentType"`
			SubagentType string `json:"subagent_type"`
			AgentName    string `json:"agent_name"`
		}
		_ = json.Unmarshal(raw, &alt)
		switch {
		case alt.AgentType != "":
			e.AgentType = alt.AgentType
		case alt.SubagentType != "":
			e.AgentType = alt.SubagentType
		case alt.AgentName != "":
			e.AgentType = alt.AgentName
		}
	}
	return &e, nil
}

// bashCommand extracts the Bash command string. A missing command on a Bash
// event is fail-closed (returns an error → block).
func (e *Event) bashCommand() (string, error) {
	var in bashInput
	if err := json.Unmarshal(e.ToolInput, &in); err != nil {
		return "", fmt.Errorf("decode bash tool_input: %w", err)
	}
	if in.Command == "" {
		return "", errors.New("bash event has no command")
	}
	return in.Command, nil
}

// filePaths extracts every path-bearing field from a file tool's input. An
// empty slice means there was nothing to guard (the caller defers).
func (e *Event) filePaths() ([]string, error) {
	var in fileInput
	if err := json.Unmarshal(e.ToolInput, &in); err != nil {
		return nil, fmt.Errorf("decode file tool_input: %w", err)
	}
	var paths []string
	for _, p := range []string{in.FilePath, in.Path, in.NotebookPath} {
		if p != "" {
			paths = append(paths, p)
		}
	}
	return paths, nil
}

// isSubagent reports whether the event originates from a subagent (not the
// main session). Used to scope the #120 conditional rule.
//
// Conservative bias: the gate treats the session as a subagent whenever it
// can detect a worktree context OR an explicit non-main agent_type. The
// subagent-conditioned rules only DENY/ASK on destructive ops, so erring
// toward "subagent" fails safe.
func (e *Event) isSubagent() bool {
	switch e.AgentType {
	case "", "main", "primary", "orchestrator", "general", "general-purpose":
		return false
	default:
		return true
	}
}
