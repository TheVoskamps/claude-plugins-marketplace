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
	// BucketAllow bypasses all remaining permission checks. It is the one
	// bucket that outranks settings.json, so it needs a stated bar, and that
	// bar is POSITIVE GROUNDS to declare the call safe: either the operation
	// itself cannot write (the Engine A read track — a read-only git/gh/aws
	// subcommand, a read-only utility invocation), or the target region is
	// designated safe by construction (the current worktree for the
	// in-repo-write classifier; the harness's per-session scratchpad, and
	// — for a read only — its bundled-skills tree).
	//
	// The earlier wording — "provably read-only / non-mutating operations" —
	// is restated rather than dropped because the bucket still needs a bar,
	// but that particular bar is not decidable at classification time: proving
	// non-mutation would require the target's current bytes, since a rewrite
	// with identical content mutates nothing. Positive grounds are decidable
	// from the call and the path alone, which is all the gate has.
	BucketAllow Bucket = "allow"
	// BucketDeny hard-blocks a known-destructive / boundary-violating call.
	// Membership requires a PRESCRIPTIVE REDIRECT: a deny reason is fed back to
	// the model, so the agent self-corrects on its next tool call instead of
	// stalling. The redirect must be TOTAL over the call's LEGITIMATE uses — a
	// deny that leaves one of them with nowhere to go is a dead end, not a
	// redirect, and belongs in BucketDefer. That is the whole difference
	// between the `updateIssue` deny, whose reason names an allowed spelling
	// per concept the verb covers, and the `deleteIssue` defer, which has none
	// to name.
	//
	// A shape with NO legitimate use — `gh api --hostname`, `aws --endpoint-url`,
	// `gh auth switch` — is not a dead end by that test: there is no legitimate
	// use stranded, and the prescription is to drop the shape and stay on the
	// sanctioned one. Such a reason still has to SAY so ("Remove --hostname;
	// the default GitHub host is the only sanctioned target", "surface it to
	// the human"), because an unstated prescription teaches nothing.
	BucketDeny Bucket = "deny"
	// BucketAsk escalates to a human decision. It is NOT an uncertainty
	// default: it is a short, enumerated policy tier — the calls fleet policy
	// says a human must click regardless of how good the downstream judge is
	// (publish verbs, history-destroying pushes, credential/secret reads and
	// mints). An LLM must not be able to waive these, which is exactly what a
	// defer would permit.
	//
	// That intent RESTS on a precedence the gate does not itself enforce: that
	// a hook `ask` outranks a settings.json / automode allow rather than being
	// waived by it. That is the documented contract of the PreToolUse
	// permission channel, but it is unpinned here — no test in this package
	// exercises real hook/settings resolution, so treat "a hard ask cannot be
	// waived downstream" as the tier's design intent, not as a measured
	// property. See README.md, "The hard-ask tier's precedence is unpinned".
	BucketAsk Bucket = "ask"
	// BucketDefer hands the call back to the normal permission pipeline
	// (settings.json allow/deny/ask lists, the tuned automode evaluator, an
	// interactive prompt). It carries the ENTIRE judgment middle: everything
	// the gate cannot statically classify, plus the context-dependent remote
	// mutations. "The gate cannot pin this statically" is precisely where a
	// context-reading judge outperforms both the gate and a prompt-fatigued
	// human, so those sites defer WITH the gate's analysis (deferJudgment)
	// rather than asking.
	BucketDefer Bucket = "defer"
)

// Decision is the gate's verdict for a single tool call, plus the teaching
// message that explains it (§6). The reason is surfaced to the model via
// permissionDecisionReason on the JSON-stdout path.
type Decision struct {
	Bucket Bucket
	// Reason is the §6 teaching message: what was blocked, why, and the
	// remediation. Required for Deny and Ask.
	//
	// A Defer may also carry one — the gate's ANALYSIS of what it could and
	// could not establish — but it is never emitted on the stdout verdict
	// (emitDecision blanks it for a defer, so a deferred call reaches the
	// downstream judge exactly as it did before). It exists for the §7
	// evolution log, which is the feed for automode re-tuning.
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

// deferJudgment is deferToPipeline for a site that HAS an account of why it
// could not decide — an unpinnable path, an unmodelled flag, a remote mutation
// whose target the gate cannot see. The verdict is identical to a bare defer
// (the reason is blanked before it reaches stdout); what it adds is the §7 log
// record, which carries the operation label AND the analysis text so the
// automode re-tune has the gate's own account of each deferred call.
func deferJudgment(op, reason string) Decision {
	return Decision{Bucket: BucketDefer, Reason: reason, Operation: op}
}
