package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// §10: fault-injection — a git rev-parse that times out must fail closed.
//
// We shim `git` with a script that sleeps longer than gitRevParseTimeout, put
// it first on PATH, and assert resolveRepoContext returns an error (which the
// callers convert to ASK/DENY, never allow).
//
// To keep the test fast we cannot lower the production timeout, so instead we
// exercise runGit's timeout path with a context we control via a slow shim and
// a short-lived check: the shim sleeps 30s; the test fails closed as soon as
// the (real) 5s timeout would trigger would be too slow, so we instead verify
// the *error path* by shimming git to EXIT NON-ZERO, plus a separate explicit
// timeout unit using a tiny override.
func TestRunGitNonZeroFailsClosed(t *testing.T) {
	dir := t.TempDir()
	shim := filepath.Join(dir, "bin")
	if err := os.MkdirAll(shim, 0o755); err != nil {
		t.Fatal(err)
	}
	gitShim := filepath.Join(shim, "git")
	// A git that always exits 1 with empty output.
	if err := os.WriteFile(gitShim, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shim+string(os.PathListSeparator)+os.Getenv("PATH"))

	if _, err := resolveRepoContext(dir); err == nil {
		t.Errorf("git exiting non-zero must produce an error (fail-closed)")
	}
}

func TestRunGitEmptyOutputFailsClosed(t *testing.T) {
	dir := t.TempDir()
	shim := filepath.Join(dir, "bin")
	_ = os.MkdirAll(shim, 0o755)
	// A git that exits 0 but prints nothing.
	if err := os.WriteFile(filepath.Join(shim, "git"), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shim+string(os.PathListSeparator)+os.Getenv("PATH"))

	if _, err := resolveRepoContext(dir); err == nil {
		t.Errorf("git empty output must produce an error (fail-closed)")
	}
}

// TestRunGitTimeoutFailsClosed verifies the timeout branch by shimming git to
// sleep well past the deadline and asserting runGit returns within a bounded
// time with an error.
func TestRunGitTimeoutFailsClosed(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping slow timeout test in -short mode")
	}
	dir := t.TempDir()
	shim := filepath.Join(dir, "bin")
	_ = os.MkdirAll(shim, 0o755)
	// git that hangs for 60s.
	if err := os.WriteFile(filepath.Join(shim, "git"), []byte("#!/bin/sh\nsleep 60\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shim+string(os.PathListSeparator)+os.Getenv("PATH"))

	start := time.Now()
	_, err := resolveRepoContext(dir)
	elapsed := time.Since(start)
	if err == nil {
		t.Errorf("hung git must produce a timeout error (fail-closed)")
	}
	// Must return at/near the deadline, not after the full 60s sleep.
	if elapsed > gitRevParseTimeout+3*time.Second {
		t.Errorf("runGit did not honor its timeout: took %s", elapsed)
	}
}

// §10 end-to-end: the built binary emits a structured JSON decision on stdout
// with exit 0 for normal verdicts, and exits 2 with stderr on a malformed
// event (fail-closed backstop).
func TestBinaryEndToEnd(t *testing.T) {
	bin := buildBinary(t)

	// Normal verdict: read-only git → allow JSON on stdout, exit 0.
	out, code := runBinary(t, bin, `{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"git status"}}`)
	if code != 0 {
		t.Errorf("normal verdict should exit 0; got %d (out=%s)", code, out)
	}
	if !containsSubstr(out, `"permissionDecision":"allow"`) {
		t.Errorf("expected allow decision JSON; got %s", out)
	}

	// Malformed event: fail-closed backstop → exit 2, stderr message.
	_, code2 := runBinary(t, bin, `not json`)
	if code2 != 2 {
		t.Errorf("malformed event must exit 2 (fail-closed); got %d", code2)
	}

	// Deny verdict: subagent reset --hard → deny JSON, exit 0.
	out3, code3 := runBinary(t, bin, `{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/tmp","agent_type":"issue-developer","tool_input":{"command":"git reset --hard HEAD"}}`)
	if code3 != 0 {
		t.Errorf("deny verdict should exit 0 (decision on stdout); got %d", code3)
	}
	if !containsSubstr(out3, `"permissionDecision":"deny"`) {
		t.Errorf("expected deny decision JSON; got %s", out3)
	}
}

func buildBinary(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "permission-gate")
	cmd := exec.Command("go", "build", "-o", bin, ".")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build binary: %v\n%s", err, out)
	}
	return bin
}

func runBinary(t *testing.T, bin, stdin string) (string, int) {
	t.Helper()
	cmd := exec.Command(bin)
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.Output()
	code := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("run binary: %v", err)
	}
	return string(out), code
}
