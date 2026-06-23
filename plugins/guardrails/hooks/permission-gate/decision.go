package main

// Bucket is the three-way (plus defer) verdict the gate emits.
//
// The native PreToolUse permission channel (Resolved decision 1) accepts
// four permissionDecision values on stdout with exit 0:
//
//	allow  - bypass remaining permission checks; the tool runs.
//	deny   - block the tool call.
//	ask    - escalate to a human permission prompt (the real ask channel).
//	defer  - defer to the normal permission flow (the spec's "exit 0 /
//	         allow-defer"): let the rest of the pipeline proceed.
//
// Exit 2 + stderr remains the FAIL-CLOSED backstop for crash / parse-error /
// panic / malformed-event paths; it is NOT one of these buckets. See
// failClosed in main.go.
type Bucket string

const (
	// BucketAllow bypasses all remaining permission checks. Reserved for
	// provably read-only / non-mutating operations (Engine A allow track).
	BucketAllow Bucket = "allow"
	// BucketDeny hard-blocks a known-destructive / boundary-violating call.
	BucketDeny Bucket = "deny"
	// BucketAsk escalates to a human decision. This is the ask-default for
	// uncertainty (fail toward human decision, never toward allow).
	BucketAsk Bucket = "ask"
	// BucketDefer hands the call back to the normal permission pipeline
	// (settings.json allow/deny/ask lists, interactive prompt, etc.). Used
	// when the gate has no opinion and does NOT want to short-circuit the
	// rest of the pipeline.
	BucketDefer Bucket = "defer"
)

// Decision is the gate's verdict for a single tool call, plus the teaching
// message that explains it (§6). The reason is surfaced to the model via
// permissionDecisionReason on the JSON-stdout path.
type Decision struct {
	Bucket Bucket
	// Reason is the §6 teaching message: what was blocked, why, and the
	// remediation. Required for Deny and Ask; ignored for Defer.
	Reason string
	// Operation is a short classified-operation label used for evolution
	// logging (§7), e.g. "git reset --hard" or "containment:worktree-escape".
	Operation string
}

func allow(reason string) Decision { return Decision{Bucket: BucketAllow, Reason: reason} }
func deny(op, reason string) Decision {
	return Decision{Bucket: BucketDeny, Reason: reason, Operation: op}
}
func ask(op, reason string) Decision {
	return Decision{Bucket: BucketAsk, Reason: reason, Operation: op}
}
func deferToPipeline() Decision { return Decision{Bucket: BucketDefer} }
