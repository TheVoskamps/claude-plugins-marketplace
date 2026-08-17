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
//
// The `defer-residual` row is the highest-VOLUME of them: every program the
// gate has no table for (`npm`, `python3`, `make`, …) lands on
// classifySimpleCommand's no-specific-rule residual, so a blank record there
// would leave the largest share of real deferred traffic invisible to the
// re-tune. It is the one row whose analysis is thin by construction — the gate
// genuinely established only which program it saw.
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
		{
			// The judgment middle's residual: a program on none of the tables.
			"defer-residual",
			`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"npm test"}}`,
			"defer", "bash:no-specific-rule", "no permission-gate rule matches the program 'npm'",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logPath := filepath.Join(t.TempDir(), "nested", "gate.jsonl")
			out, code, recs := runBinaryWithLog(t, bin, logPath, tc.event)
			if code != 0 {
				t.Fatalf("expected the exit-0 decision channel; got %d (stdout=%s)", code, out)
			}
			if got := stdoutBucket(t, out); got != Bucket(tc.wantBucket) {
				t.Fatalf("event was meant to land in %q; got %q (stdout=%s)", tc.wantBucket, got, out)
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

// The no-specific-rule residual is ranked BELOW every other defer analysis when
// a line carries several parts. `npm test && git reset --hard HEAD` (main
// session) defers on both parts, and the residual fires FIRST, so a plain
// first-wins aggregation would log "the gate has no table for npm" and lose the
// reset's account — the informative half, and the one an automode re-tune acts
// on.
//
// The negative control is the reversed order: with the informative part first,
// first-wins and ranking agree, so a run that logged the reset in BOTH
// orderings only proves the ranking when the residual-first ordering is the one
// asserted.
func TestResidualDeferRanksBelowAnInformativeDefer_262(t *testing.T) {
	bin := buildBinary(t)

	for _, tc := range []struct{ name, command string }{
		{"residual first", "npm test && git reset --hard HEAD"},
		{"residual second", "git reset --hard HEAD && npm test"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logPath := filepath.Join(t.TempDir(), "gate.jsonl")
			event := `{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"` +
				tc.command + `"}}`
			out, _, recs := runBinaryWithLog(t, bin, logPath, event)
			if got := stdoutBucket(t, out); got != BucketDefer {
				t.Fatalf("this line must defer for the test to mean anything; got %q (stdout=%s)", got, out)
			}
			if len(recs) != 1 {
				t.Fatalf("expected exactly one log record; got %d", len(recs))
			}
			if recs[0].Operation != "git reset --hard" {
				t.Errorf("the informative defer must win the log record whatever its position; got %q (analysis %q)",
					recs[0].Operation, recs[0].Analysis)
			}
		})
	}

	// The residual still reaches the log when it is the ONLY account on the
	// line — the ranking demotes it, it does not discard it.
	logPath := filepath.Join(t.TempDir(), "gate.jsonl")
	_, _, recs := runBinaryWithLog(t, bin, logPath,
		`{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"npm test && npm run build"}}`)
	if len(recs) != 1 || recs[0].Operation != "bash:no-specific-rule" {
		t.Errorf("a line whose only account is the residual must still log it; got %+v", recs)
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
		HookSpecificOutput map[string]json.RawMessage `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("decode stdout %q: %v", out, err)
	}
	if b := stdoutBucket(t, out); b != BucketDefer {
		t.Fatalf("this event must defer for the test to mean anything; got %q", b)
	}
	// Since #271 a defer abstains by omitting permissionDecision, and the
	// reason key goes with it — there is no field left to leak the analysis on,
	// which is a stronger form of the same guarantee than the empty string was.
	if raw, ok := got.HookSpecificOutput["permissionDecisionReason"]; ok {
		t.Errorf("a defer must emit NO reason key on stdout; got %s", raw)
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
//
// Each subtest injects a fault only for a bucket main.go actually LOGS: with a
// bucket missing from main.go's log condition, logEvent is never reached for
// it, nothing fails, and that subtest passes vacuously. Measured: deleting the
// `|| d.Bucket == BucketDefer` arm leaves all three subtests here green, and
// fails TestEvolutionLogRecordsEveryNonAllowBucketWithAnalysis_262 instead.
// That test is the one that pins which buckets are wired; this one pins only
// that a wired bucket's log failure is swallowed.
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
			if got := stdoutBucket(t, string(out)); got != Bucket(tc.want) {
				t.Errorf("a logging failure changed the verdict: wanted %q, got %q (%s)", tc.want, got, out)
			}
		})
	}
}
