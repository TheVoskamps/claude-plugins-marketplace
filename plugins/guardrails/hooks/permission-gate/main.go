// Command permission-gate is a compiled PreToolUse hook that adjudicates the
// tool calls Claude Code is about to make. It is the deterministic
// enforcement layer the OS sandbox structurally cannot provide (issue #247).
//
// It reads a single PreToolUse event as JSON on stdin and emits a verdict:
//
//   - Normal path: a structured decision as JSON on stdout, exit 0
//     (allow / deny / ask / defer). See decision.go and emitDecision.
//   - Fail-closed backstop: any crash / parse error / panic / malformed event
//     blocks via exit 2 with a teaching message on stderr (stderr is fed back
//     to the model). See failClosed.
//
// Two engines feed the three-bucket decision:
//
//   - Engine A (engine_a_bash.go, engine_a_mcp.go): command classifier over
//     the Bash AST, plus an MCP tool-name branch.
//   - Engine B (engine_b_containment.go): path-containment via `git rev-parse`
//     against the EVENT's cwd, with symlink canonicalization on both sides and
//     fail-closed subprocess handling.
//
// Posture: ask-defaulting. The explicit allow set and explicit deny set are
// small and authoritative; everything uncertain ASKs (fail toward human
// decision, never toward allow).
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// exitBlock is the fail-closed exit code. The harness feeds stderr back to
// the model on exit 2, so the teaching message must be actionable.
const exitBlock = 2

func main() {
	// Top-level panic recovery: a panic anywhere in classification must
	// fail closed (block), never crash-open. This is the §9 "panic →
	// block" guarantee.
	defer func() {
		if r := recover(); r != nil {
			failClosed(fmt.Sprintf(
				"permission-gate panicked while classifying this call (%v); "+
					"blocking as a fail-closed safety measure. Re-run the operation; "+
					"if it persists, the gate has a bug.", r))
		}
	}()

	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		failClosed(fmt.Sprintf("permission-gate could not read the hook event from stdin (%v); blocking.", err))
	}

	ev, err := parseEvent(raw)
	if err != nil {
		// Malformed / empty / missing-field event is a §9 fail-closed case.
		failClosed(fmt.Sprintf("permission-gate received a malformed PreToolUse event (%v); blocking. "+
			"This is a fail-closed safety measure.", err))
	}

	d := classify(ev)

	// Log every ASK (and every DENY) for rule evolution (§7). Logging failure
	// must never change the verdict, so errors are swallowed inside logEvent.
	if d.Bucket == BucketAsk || d.Bucket == BucketDeny {
		logEvent(ev, d)
	}

	emitDecision(d)
}

// classify routes the event to the right engine and returns a Decision.
// It NEVER returns BucketAllow for an uncertain call: the residual is ASK.
func classify(ev *Event) Decision {
	switch {
	case ev.ToolName == "Bash":
		cmd, err := ev.bashCommand()
		if err != nil {
			// A Bash event we cannot read the command from is fail-closed:
			// ASK rather than allow (we cannot prove it safe).
			return ask("bash:unreadable", fmt.Sprintf(
				"Blocked: could not read the Bash command from this event (%v). "+
					"Escalating to a human decision (fail-closed).", err))
		}
		return classifyBash(cmd, ev)

	case isFileTool(ev.ToolName):
		return classifyFileTool(ev)

	case isMCPTool(ev.ToolName):
		return classifyMCP(ev)

	default:
		// Unknown tool: no opinion, hand back to the normal pipeline.
		return deferToPipeline()
	}
}

// isFileTool reports whether the tool reads or mutates files by path and is
// therefore subject to Engine B containment.
func isFileTool(name string) bool {
	switch name {
	case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
		return true
	default:
		return false
	}
}

// emitDecision writes the verdict on the JSON-stdout / exit-0 channel
// (Resolved decision 1). A defer with no reason still emits a structured
// "defer" so the rest of the pipeline proceeds explicitly.
func emitDecision(d Decision) {
	out := map[string]any{
		"hookSpecificOutput": map[string]any{
			"hookEventName":            "PreToolUse",
			"permissionDecision":       string(d.Bucket),
			"permissionDecisionReason": d.Reason,
		},
	}
	b, err := json.Marshal(out)
	if err != nil {
		// Marshaling the decision itself failed — fail closed.
		failClosed(fmt.Sprintf("permission-gate could not encode its decision (%v); blocking.", err))
	}
	if _, err := os.Stdout.Write(b); err != nil {
		failClosed(fmt.Sprintf("permission-gate could not write its decision (%v); blocking.", err))
	}
	os.Exit(0)
}

// failClosed is the exit-2 + stderr backstop for crash / parse-error / panic /
// malformed-event paths. It never returns.
func failClosed(reason string) {
	fmt.Fprintln(os.Stderr, reason)
	os.Exit(exitBlock)
}
