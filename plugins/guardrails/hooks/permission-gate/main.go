// Command permission-gate is a compiled PreToolUse hook that adjudicates the
// tool calls Claude Code is about to make. It is the deterministic
// enforcement layer the OS sandbox structurally cannot provide.
//
// It reads a single PreToolUse event as JSON on stdin and emits a verdict:
//
//   - Normal path: a structured decision as JSON on stdout, exit 0
//     (allow / deny / ask, or a defer spelled as the envelope with no
//     permissionDecision field). See decision.go and emitDecision.
//   - Fail-closed backstop: any crash / parse error / panic / malformed event
//     blocks via exit 2 with a teaching message on stderr (stderr is fed back
//     to the model). See failClosed.
//
// The engines that produce that verdict:
//
//   - Engine A (engine_a_bash.go, engine_a_mcp.go): command classifier over
//     the Bash AST, plus an MCP tool-name branch.
//   - Engine B (engine_b_containment.go): path-containment via `git rev-parse`
//     against the EVENT's cwd, with symlink canonicalization on both sides and
//     fail-closed subprocess handling.
//
// Posture: three tiers plus a defer middle. The gate buckets a call by
// what it can do BETTER than the downstream tuned automode evaluator, not by
// how confident it is:
//
//   - DENY with teaching — a known-bad call for which a prescriptive redirect
//     exists. This tier keeps its value BECAUSE of automode: a defer that
//     automode denies produces a generic denial, while the gate's deny carries
//     the redirect prose the model self-corrects on.
//   - ALLOW with positive grounds — proven read-only operations and contained
//     writes. This is what keeps the hot path off the evaluator entirely.
//   - Hard ASK — a short, enumerated human-click tier: publish verbs,
//     history-destroying pushes, credential/secret reads and mints. Policy, not
//     classification; an LLM must not be able to waive these. (That the ask
//     survives a downstream allow is design intent, not a measured fact — see
//     README.md, "The hard-ask tier's precedence is unpinned".)
//
// Everything else — the whole judgment middle, including every "the gate
// cannot statically classify this" arm — DEFERS, carrying the gate's analysis
// into the evolution log for the evaluator's tuning. The old ask-default is
// gone: a gate ask is a guaranteed hard prompt that BYPASSES the smartest layer
// in the stack, so spending one on uncertainty bought prompt fatigue rather
// than safety.
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
	// fail closed (block), never crash-open. This is the "panic → block"
	// guarantee.
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
		// Malformed / empty / missing-field event is a fail-closed case.
		failClosed(fmt.Sprintf("permission-gate received a malformed PreToolUse event (%v); blocking. "+
			"This is a fail-closed safety measure.", err))
	}

	d := classify(ev)

	// Log every ASK, DENY and DEFER for rule evolution. DEFER is logged because
	// it is now the judgment middle's terminal, and the log is the feed for
	// tuning the evaluator those calls land in: a deferred call that appears
	// nowhere is a call nobody can tune for. Logging failure must never change
	// the verdict, so errors are swallowed inside logEvent.
	if d.Bucket == BucketAsk || d.Bucket == BucketDeny || d.Bucket == BucketDefer {
		logEvent(ev, d)
	}

	emitDecision(d)
}

// classify routes the event to the right engine and returns a Decision.
// It NEVER returns BucketAllow for an uncertain call: the residual is DEFER.
func classify(ev *Event) Decision {
	switch {
	case ev.ToolName == "Bash":
		cmd, err := ev.bashCommand()
		if err != nil {
			// A Bash event we cannot read the command from: the gate has no
			// command to classify, so it has nothing a human click would be
			// better informed by. Defer with the read error as the analysis.
			return deferJudgment("bash:unreadable", fmt.Sprintf(
				"could not read the Bash command from this event (%v), so the gate has no command text to "+
					"classify.", err))
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
// (Resolved decision 1).
//
// A defer emits the envelope with NO permissionDecision field, which is the
// documented per-call abstention: the hook takes no position and the normal
// permission pipeline resolves the call. It must NOT emit the literal
// "defer" — Claude Code gave that wire value different semantics (it PAUSES
// the tool call for later resumption, added for headless-resume workflows).
// Inside a subagent a paused tool call never resolves, the tool use ends with
// no result, and the harness tears the agent session down.
//
// The empty envelope is still non-empty JSON, which the hooks.json wrapper
// requires: it reads "exit 0 with empty stdout" as an unrunnable gate binary
// and fails closed, so the no-output spelling of abstention is
// unavailable to this gate. decision_stdout_test.go pins both halves.
//
// A defer's reason is DROPPED here — with the decision field gone there is no
// field to carry it, and there never was one to fill. deferJudgment sites
// carry the gate's analysis for the evolution log, but a deferred call must
// reach the downstream evaluator exactly as a bare defer does: the gate did not
// decide, so it puts no words in the judge's mouth, and every defer emits the
// identical payload whatever its analysis says.
func emitDecision(d Decision) {
	hookOut := map[string]any{
		"hookEventName": "PreToolUse",
	}
	if d.Bucket != BucketDefer {
		hookOut["permissionDecision"] = string(d.Bucket)
		hookOut["permissionDecisionReason"] = d.Reason
	}
	out := map[string]any{
		"hookSpecificOutput": hookOut,
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
