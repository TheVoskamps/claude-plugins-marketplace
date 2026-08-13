package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// runBinaryWithLog runs the built gate with PERMISSION_GATE_LOG pointed at
// logPath and returns stdout, the exit code, and every record the run appended.
//
// It drives the REAL binary rather than calling logEvent directly, because what
// #262 changed is which decisions main.go hands to the logger — a unit test on
// logEvent would keep passing with the DEFER arm deleted from that condition.
func runBinaryWithLog(t *testing.T, bin, logPath, stdin string) (string, int, []logRecord) {
	t.Helper()
	cmd := exec.Command(bin)
	cmd.Stdin = strings.NewReader(stdin)
	cmd.Env = append(os.Environ(), logEnvVar+"="+logPath)
	out, err := cmd.Output()
	code := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("run binary: %v", err)
	}

	var recs []logRecord
	raw, readErr := os.ReadFile(logPath)
	if readErr != nil && !os.IsNotExist(readErr) {
		t.Fatalf("read log %s: %v", logPath, readErr)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if line == "" {
			continue
		}
		var rec logRecord
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("log line is not a JSON record: %q (%v)", line, err)
		}
		recs = append(recs, rec)
	}
	return string(out), code, recs
}

// The §7 evolution log records ASK, DENY and DEFER, and a record from a site
// that reached a verdict carries the gate's ANALYSIS — not just the operation
// label. Every ask, every deny and every `deferJudgment` site is such a site;
// a bare `deferToPipeline` has no account to give and logs both fields empty,
// which is how a reader tells the two kinds of defer apart. The rows below are
// all verdict-reaching sites. The defer rows are the
// point of #262: they are the feed for tuning the evaluator those calls now
// land in, and a deferred call that appears nowhere is a call nobody can tune
// for.
func TestEvolutionLogRecordsEveryNonAllowBucketWithAnalysis_262(t *testing.T) {
	bin := buildBinary(t)

	for _, tc := range []struct {
		name          string
		event         string
		wantBucket    string
		wantOperation string
		wantAnalysis  string
	}{
		{
			// Hard-ask tier: a credential read.
			"ask",
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"gh auth token"}}`,
			"ask", "gh auth token (#262)", "prints the live OAuth token",
		},
		{
			// Deny-with-teaching.
			"deny",
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","agent_type":"issue-developer","tool_input":{"command":"git reset --hard HEAD"}}`,
			"deny", "git reset --hard (subagent)", "detached checkout",
		},
		{
			// The judgment middle: an unpinnable path.
			"defer",
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"cat \"$D/x\""}}`,
			"defer", "bash-read:dynamic-path", "cannot resolve statically",
		},
		{
			// The judgment middle: a remote mutation.
			"defer-remote",
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"aws s3 rm s3://b/k"}}`,
			"defer", "aws non-read op", "not a provably read-only operation",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logPath := filepath.Join(t.TempDir(), "nested", "gate.jsonl")
			out, code, recs := runBinaryWithLog(t, bin, logPath, tc.event)
			if code != 0 {
				t.Fatalf("expected the exit-0 decision channel; got %d (stdout=%s)", code, out)
			}
			if !strings.Contains(out, `"permissionDecision":"`+tc.wantBucket+`"`) {
				t.Fatalf("event was meant to land in %q; stdout=%s", tc.wantBucket, out)
			}
			if len(recs) != 1 {
				t.Fatalf("expected exactly one log record for a %s; got %d", tc.wantBucket, len(recs))
			}
			rec := recs[0]
			if rec.Bucket != tc.wantBucket {
				t.Errorf("logged bucket: got %q, want %q", rec.Bucket, tc.wantBucket)
			}
			if rec.Operation != tc.wantOperation {
				t.Errorf("logged operation: got %q, want %q", rec.Operation, tc.wantOperation)
			}
			if !strings.Contains(rec.Analysis, tc.wantAnalysis) {
				t.Errorf("logged analysis must carry the gate's account (%q); got %q",
					tc.wantAnalysis, rec.Analysis)
			}
			if rec.Timestamp == "" || rec.ToolName == "" || rec.Raw == "" {
				t.Errorf("record is missing context fields: %+v", rec)
			}
		})
	}
}

// An ALLOW is still not logged: the log is the evolution/tuning feed, and the
// hot path is exactly what the allow track exists to keep out of it.
func TestEvolutionLogSkipsAllow_262(t *testing.T) {
	bin := buildBinary(t)
	logPath := filepath.Join(t.TempDir(), "gate.jsonl")
	out, _, recs := runBinaryWithLog(t, bin, logPath,
		`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"git status"}}`)
	if !strings.Contains(out, `"permissionDecision":"allow"`) {
		t.Fatalf("this event must allow for the test to mean anything; stdout=%s", out)
	}
	if len(recs) != 0 {
		t.Errorf("an allow must append no log record; got %d: %+v", len(recs), recs)
	}
}

// A DEFER's analysis rides the §7 log and NOT the stdout verdict. A deferred
// call must reach the downstream evaluator exactly as a bare defer does — the
// gate did not decide, so it puts no words in the judge's mouth.
func TestDeferAnalysisStaysOutOfTheStdoutVerdict_262(t *testing.T) {
	bin := buildBinary(t)
	logPath := filepath.Join(t.TempDir(), "gate.jsonl")
	out, _, recs := runBinaryWithLog(t, bin, logPath,
		`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"cat \"$D/x\""}}`)

	var got struct {
		HookSpecificOutput struct {
			PermissionDecision       string `json:"permissionDecision"`
			PermissionDecisionReason string `json:"permissionDecisionReason"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("decode stdout %q: %v", out, err)
	}
	if got.HookSpecificOutput.PermissionDecision != "defer" {
		t.Fatalf("this event must defer for the test to mean anything; got %q",
			got.HookSpecificOutput.PermissionDecision)
	}
	if got.HookSpecificOutput.PermissionDecisionReason != "" {
		t.Errorf("a defer must emit an EMPTY reason on stdout; got %q",
			got.HookSpecificOutput.PermissionDecisionReason)
	}
	// The negative control: the analysis exists, it just does not travel on the
	// verdict. Without this, an emitDecision that dropped the reason everywhere
	// would pass the assertion above.
	if len(recs) != 1 || recs[0].Analysis == "" {
		t.Errorf("the same defer must still carry its analysis into the log; got %+v", recs)
	}
}

// Fault injection: logging must NEVER change a verdict. With the log path
// unwritable — a plain FILE where the gate needs a directory, so MkdirAll and
// OpenFile both fail — every bucket must still emit its normal exit-0 decision.
func TestLoggingFailureChangesNoVerdict_262(t *testing.T) {
	bin := buildBinary(t)
	blocker := filepath.Join(t.TempDir(), "not-a-dir")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	// <blocker>/sub/gate.jsonl cannot be created: <blocker> is a regular file.
	logPath := filepath.Join(blocker, "sub", "gate.jsonl")

	for _, tc := range []struct{ name, event, want string }{
		{
			"ask",
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"gh auth token"}}`,
			"ask",
		},
		{
			"deny",
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","agent_type":"issue-developer","tool_input":{"command":"git reset --hard HEAD"}}`,
			"deny",
		},
		{
			"defer",
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"cat \"$D/x\""}}`,
			"defer",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmd := exec.Command(bin)
			cmd.Stdin = strings.NewReader(tc.event)
			cmd.Env = append(os.Environ(), logEnvVar+"="+logPath)
			out, err := cmd.Output()
			code := 0
			if exitErr, ok := err.(*exec.ExitError); ok {
				code = exitErr.ExitCode()
			} else if err != nil {
				t.Fatalf("run binary: %v", err)
			}
			if code != 0 {
				t.Fatalf("a logging failure must not turn %s into a fail-closed block; got exit %d (out=%s)",
					tc.want, code, out)
			}
			if !strings.Contains(string(out), `"permissionDecision":"`+tc.want+`"`) {
				t.Errorf("a logging failure changed the verdict: wanted %q, got %s", tc.want, out)
			}
		})
	}
}
