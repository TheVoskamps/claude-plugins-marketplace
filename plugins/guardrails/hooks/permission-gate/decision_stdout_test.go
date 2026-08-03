package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"testing"
)

// The registration wrapper in hooks/hooks.json treats "the gate exited 0 but
// wrote nothing to stdout" as a fail-closed condition (issue #216 round 2). It
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
			// Engine A deny track: history destruction from a subagent (#120).
			BucketDeny,
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","agent_type":"issue-developer","tool_input":{"command":"git reset --hard HEAD"}}`,
		},
		{
			// MCP branch: an explicit remote-state mutation escalates to a human.
			BucketAsk,
			`{"hook_event_name":"PreToolUse","tool_name":"mcp__example__merge_pull_request","cwd":"/tmp","tool_input":{}}`,
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
			var got struct {
				HookSpecificOutput struct {
					PermissionDecision string `json:"permissionDecision"`
				} `json:"hookSpecificOutput"`
			}
			if err := json.Unmarshal([]byte(out), &got); err != nil {
				t.Fatalf("bucket %q: decode stdout %q: %v", tc.bucket, out, err)
			}
			if got := got.HookSpecificOutput.PermissionDecision; got != string(tc.bucket) {
				t.Fatalf("event was meant to land in bucket %q but produced %q; pick a new event for this bucket", tc.bucket, got)
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
