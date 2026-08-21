package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"testing"
)

// The registration wrapper in hooks/hooks.json treats "the gate exited 0 but
// wrote nothing to stdout" as a fail-closed condition. It
// has to: a gate binary that is present and executable but not *runnable* —
// most sharply, a zero-byte file with the exec bit set, which the kernel's
// ENOEXEC shell fallback runs as an empty script — exits 0 with no stdout and
// no stderr, and the tool call would otherwise proceed completely unguarded.
//
// That discriminator is only sound while the REAL binary can never produce the
// same signature. These tests pin exactly that invariant: every decision
// bucket the gate can reach leaves non-empty JSON on stdout and exits 0. A
// future refactor that introduces a silent exit-0 path — a bucket that returns
// without emitting, an early return in emitDecision, a "no opinion means say
// nothing" shortcut — fails here instead of silently reopening the fail-open
// hole in the wrapper.
//
// The second invariant these tests pin is the DEFER WIRE SPELLING. A
// defer is the envelope with NO permissionDecision field — the documented
// per-call abstention — and specifically not the literal "defer", which Claude
// Code reads as "pause this tool call for later resumption"; inside a subagent
// that pause never resolves and the harness tears the session down. allow /
// deny / ask must still carry the field. The two invariants pull against each
// other — abstention wants silence, the wrapper requires bytes — so both are
// asserted on the same output.
//
// Exit 2 (failClosed) is deliberately NOT in scope: it is the blocking
// backstop, always accompanied by a stderr line, and the wrapper propagates it
// as-is.

// allBuckets is every bucket emitDecision can be handed. Both tests below
// iterate it, so adding a Bucket constant without covering it fails the
// end-to-end exhaustiveness check.
var allBuckets = []Bucket{BucketAllow, BucketDeny, BucketAsk, BucketDefer}

// emitBucketEnv makes TestEmitDecisionHelperProcess act as the child process
// of TestEmitDecisionNeverExitsZeroWithEmptyStdout.
const emitBucketEnv = "PERMISSION_GATE_TEST_EMIT_BUCKET"

// permissionDecisionOf decodes one emitted envelope and reports the
// permissionDecision value together with whether the KEY was present at all.
// The presence bit is the point: a defer is spelled by the key's absence, and
// unmarshalling into a plain string would render that indistinguishable from
// an explicit empty value.
func permissionDecisionOf(out string) (value string, present bool, err error) {
	var env struct {
		HookSpecificOutput map[string]json.RawMessage `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(out), &env); err != nil {
		return "", false, err
	}
	raw, ok := env.HookSpecificOutput["permissionDecision"]
	if !ok {
		return "", false, nil
	}
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", true, err
	}
	return value, true, nil
}

// stdoutBucket reports which bucket an emitted envelope spells: the
// permissionDecision value when the field is present, and BucketDefer when it
// is absent, which is how a defer abstains. Tests that only need "did
// this event land in bucket X" use it; the two tests in this file deliberately
// do NOT, asserting the presence bit directly instead, since they are what
// pins the spelling this helper encodes.
func stdoutBucket(t *testing.T, out string) Bucket {
	t.Helper()
	value, present, err := permissionDecisionOf(out)
	if err != nil {
		t.Fatalf("decode stdout %q: %v", out, err)
	}
	if !present {
		return BucketDefer
	}
	return Bucket(value)
}

// TestEveryBucketWritesJSONToStdoutWithExitZero drives the built binary
// end-to-end with one real event per bucket and asserts the exit-0 channel
// always carries a decision.
func TestEveryBucketWritesJSONToStdoutWithExitZero(t *testing.T) {
	bin := buildBinary(t)

	cases := []struct {
		bucket Bucket
		event  string
	}{
		{
			// Engine A allow track: a read-only git command.
			BucketAllow,
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"git status"}}`,
		},
		{
			// Engine A deny track: history destruction from a subagent.
			BucketDeny,
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","agent_type":"issue-developer","tool_input":{"command":"git reset --hard HEAD"}}`,
		},
		{
			// Engine A ask track: a credential read escalates to a human.
			// A hard-ask-tier member. The MCP mutation that used to sit here
			// sits in the DEFER middle, so this row names a call the tier
			// keeps by POLICY — a credential read — which is what makes it a
			// stable choice rather than one more classification residue.
			BucketAsk,
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"gh auth token"}}`,
		},
		{
			// classify's default arm: an unknown tool hands back to the pipeline.
			// This is the bucket with an EMPTY Reason, so it is the one most at
			// risk of a future "nothing to say, write nothing" shortcut.
			BucketDefer,
			`{"hook_event_name":"PreToolUse","tool_name":"WebFetch","cwd":"/tmp","tool_input":{"url":"https://example.com"}}`,
		},
	}

	covered := make(map[Bucket]bool, len(cases))
	for _, tc := range cases {
		covered[tc.bucket] = true
		t.Run(string(tc.bucket), func(t *testing.T) {
			out, code := runBinary(t, bin, tc.event)
			if code != 0 {
				t.Fatalf("bucket %q must use the exit-0 decision channel; got exit %d (stdout=%q)", tc.bucket, code, out)
			}
			if out == "" {
				t.Fatalf("bucket %q exited 0 with EMPTY stdout: that is the signature the "+
					"hooks.json wrapper uses to detect an unrunnable gate binary, so the real "+
					"binary must never produce it", tc.bucket)
			}
			if !json.Valid([]byte(out)) {
				t.Fatalf("bucket %q wrote non-JSON to stdout: %q", tc.bucket, out)
			}
			decision, present, err := permissionDecisionOf(out)
			if err != nil {
				t.Fatalf("bucket %q: decode stdout %q: %v", tc.bucket, out, err)
			}
			if tc.bucket == BucketDefer {
				if present {
					t.Fatalf("a defer must abstain by OMITTING permissionDecision, but stdout carried %q "+
						"(%q). The literal \"defer\" makes Claude Code PAUSE the tool call for later "+
						"resumption; inside a subagent it never resolves and the session is torn down "+
						".", decision, out)
				}
				return
			}
			if !present {
				t.Fatalf("bucket %q emitted no permissionDecision field (%q); only a defer abstains", tc.bucket, out)
			}
			if decision != string(tc.bucket) {
				t.Fatalf("event was meant to land in bucket %q but produced %q; pick a new event for this bucket", tc.bucket, decision)
			}
		})
	}

	for _, b := range allBuckets {
		if !covered[b] {
			t.Errorf("bucket %q has no end-to-end case: add an event that reaches it", b)
		}
	}
}

// TestEmitDecisionNeverExitsZeroWithEmptyStdout covers emitDecision itself,
// exhaustively over every bucket, independent of whether any event currently
// classifies into it. emitDecision ends in os.Exit(0), so each bucket runs in
// a re-exec'd child process (the same process-level idiom faultinject_test.go
// uses for the built binary).
func TestEmitDecisionNeverExitsZeroWithEmptyStdout(t *testing.T) {
	for _, b := range allBuckets {
		t.Run(string(b), func(t *testing.T) {
			cmd := exec.Command(os.Args[0], "-test.run=^TestEmitDecisionHelperProcess$")
			cmd.Env = append(os.Environ(), emitBucketEnv+"="+string(b))
			out, err := cmd.Output()
			if err != nil {
				t.Fatalf("emitDecision(%q) must exit 0; got %v (stdout=%q)", b, err, out)
			}
			if len(out) == 0 {
				t.Fatalf("emitDecision(%q) exited 0 without writing anything to stdout: the "+
					"hooks.json wrapper reads that as an unrunnable gate binary and denies the "+
					"call, so every bucket must emit a decision", b)
			}
			if !json.Valid(out) {
				t.Fatalf("emitDecision(%q) wrote non-JSON to stdout: %q", b, out)
			}
			decision, present, err := permissionDecisionOf(string(out))
			if err != nil {
				t.Fatalf("emitDecision(%q): decode stdout %q: %v", b, out, err)
			}
			if b == BucketDefer {
				if present {
					t.Fatalf("emitDecision(%q) wrote permissionDecision=%q; a defer abstains by omitting "+
						"the field, because the literal \"defer\" pauses the tool call for later "+
						"resumption and never resolves inside a subagent", b, decision)
				}
				return
			}
			if !present || decision != string(b) {
				t.Fatalf("emitDecision(%q) must write permissionDecision=%q; got present=%v value=%q",
					b, b, present, decision)
			}
		})
	}
}

// TestEmitDecisionHelperProcess is not a standalone test: it is the child
// re-exec'd by TestEmitDecisionNeverExitsZeroWithEmptyStdout. Under a normal
// `go test` run the env var is unset and it skips. When set, it calls
// emitDecision, which writes the decision and exits the process, so nothing
// after this line runs and the testing framework prints no trailing output —
// leaving stdout as exactly the decision bytes.
func TestEmitDecisionHelperProcess(t *testing.T) {
	b := os.Getenv(emitBucketEnv)
	if b == "" {
		t.Skip("child process of TestEmitDecisionNeverExitsZeroWithEmptyStdout; " +
			emitBucketEnv + " is unset")
	}
	emitDecision(Decision{Bucket: Bucket(b)})
}
