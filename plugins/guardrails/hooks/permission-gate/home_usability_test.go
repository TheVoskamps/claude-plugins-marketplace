package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// Home usability is decided by ONE predicate at ONE chokepoint (home.go).
// These tests are the table the issue asks for: every home shape the gate can
// be handed — unset, empty, relative, absolute — crossed with every shape that
// reads a home, asserting that the unusable rows all deny at the chokepoint
// and the absolute rows are untouched.
//
// The unusable rows can only be measured here. A replay against the committed
// binary cannot build them: a `HOME=<dir>` prefix is refused by the harness's
// worktree-isolation guard, so a synthetic event measures whatever the driving
// machine's own home is (docs/guardrails-verification-playbook.md → "A
// `$HOME`-rooted rule is settled by `go test`, not by a replay"). t.Setenv over
// a t.TempDir builds the fixture the replay cannot.

// homeShape is one setting of the process home directory.
type homeShape struct {
	name string
	// apply installs the shape and returns the home value the gate will see.
	apply func(t *testing.T) string
	// usable is the verdict the one predicate gives this shape.
	usable bool
}

func homeShapes() []homeShape {
	return []homeShape{
		{
			name: "unset",
			apply: func(t *testing.T) string {
				t.Helper()
				// t.Setenv registers the restore; Unsetenv then produces the
				// shape t.Setenv itself cannot spell.
				t.Setenv("HOME", "placeholder")
				if err := os.Unsetenv("HOME"); err != nil {
					t.Fatalf("unset HOME: %v", err)
				}
				return ""
			},
		},
		{
			name: "empty",
			apply: func(t *testing.T) string {
				t.Helper()
				t.Setenv("HOME", "")
				return ""
			},
		},
		{
			name: "relative",
			apply: func(t *testing.T) string {
				t.Helper()
				t.Setenv("HOME", "relhome")
				return "relhome"
			},
		},
		{
			name: "absolute",
			apply: func(t *testing.T) string {
				t.Helper()
				home := t.TempDir()
				t.Setenv("HOME", home)
				return home
			},
			usable: true,
		},
	}
}

// homeTestRepo builds a git worktree to run the events in and returns its
// canonical path. Call it BEFORE installing a home shape: git itself reads
// `~`, so `git init` under an unset home fails on a machine whose global
// config carries a tilde-spelled include.
func homeTestRepo(t *testing.T) string {
	t.Helper()
	repo := filepath.Join(t.TempDir(), "repo")
	gitInit(t, repo)
	return canonicalize(repo)
}

// applyHomeShape installs a home shape for the duration of the test, after
// detaching git from the driving machine's global/system config. The gate
// shells out to `git rev-parse`, and a global config carrying a `~`-spelled
// include makes every such call fail once the home is unusable — which would
// measure the machine's gitconfig rather than the gate.
func applyHomeShape(t *testing.T, shape homeShape) {
	t.Helper()
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_SYSTEM", os.DevNull)
	shape.apply(t)
}

// TestHomeUsabilityPredicate pins the one predicate directly: usable iff it
// resolved without error, is non-empty, and is absolute.
func TestHomeUsabilityPredicate(t *testing.T) {
	for _, tc := range []struct {
		name string
		home string
		err  error
		want bool
	}{
		{name: "absolute", home: "/Users/someone", want: true},
		{name: "empty", home: ""},
		{name: "relative", home: "relhome"},
		{name: "relative-dot", home: "./relhome"},
		{name: "errored", home: "/Users/someone", err: os.ErrNotExist},
	} {
		if got := homeUsable(tc.home, tc.err); got != tc.want {
			t.Errorf("homeUsable(%q, %v) = %v, want %v", tc.home, tc.err, got, tc.want)
		}
	}
}

// TestHomeChokepointBashShapes crosses every home shape with every Bash
// spelling that reaches a home read. Under an unusable home each of them
// denies at the chokepoint with the one operation label; under an absolute
// home none of them does.
func TestHomeChokepointBashShapes(t *testing.T) {
	// alwaysDenies marks a command carrying its own in-script home the gate
	// cannot place, which denies at the chokepoint whatever the process home is.
	commands := []struct {
		cmd          string
		alwaysDenies bool
	}{
		{cmd: `cat ~/x`},
		{cmd: `cat "$HOME/x"`},
		{cmd: `cat "${HOME}/x"`},
		{cmd: `cat '~/x'`},
		{cmd: `X=~/x; cat "$X"`},
		{cmd: `HOME=relhome; cat ~/x`, alwaysDenies: true},
		{cmd: `echo $(cat ~/x)`},
		// An in-script HOME= built from the process home is resolved by the
		// package's own literalWord, so under a usable home these set a usable
		// home and deny nothing — the chokepoint carries no second, stricter
		// notion of "literal".
		{cmd: `HOME=$HOME/sub; cat ~/x`},
		{cmd: `HOME=~/sub; cat ~/x`},
		// A value literalWord cannot resolve exactly is unusable whatever the
		// process home is: the gate cannot place the home the later `~`
		// resolves against.
		{cmd: `HOME=$(pwd); cat ~/x`, alwaysDenies: true},
	}
	for _, shape := range homeShapes() {
		for _, tc := range commands {
			cmd := tc.cmd
			t.Run(shape.name+"/"+cmd, func(t *testing.T) {
				repo := homeTestRepo(t)
				applyHomeShape(t, shape)
				ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: repo, AgentType: "main"}
				d := classifyBash(cmd, ev)
				wantChokepoint := !shape.usable || tc.alwaysDenies
				if wantChokepoint {
					if d.Bucket != BucketDeny || d.Operation != homeUnusableOp {
						t.Fatalf("%q with %s home: got bucket %q op %q (reason=%q), want deny/%s",
							cmd, shape.name, d.Bucket, d.Operation, d.Reason, homeUnusableOp)
					}
					return
				}
				if d.Operation == homeUnusableOp {
					t.Fatalf("%q with an absolute home must not deny at the home chokepoint (reason=%q)",
						cmd, d.Reason)
				}
				if d.Bucket == BucketAllow {
					t.Fatalf("%q with an absolute home outside the repo must not allow (reason=%q)", cmd, d.Reason)
				}
			})
		}
	}
}

// TestHomeChokepointInScriptAbsoluteHome pins the second half of the
// two-value grading: an in-script `HOME=` assignment to an ABSOLUTE path is
// usable, so a later word referencing it is not denied at the chokepoint even
// when the process home is unusable.
func TestHomeChokepointInScriptAbsoluteHome(t *testing.T) {
	for _, shape := range homeShapes() {
		if shape.usable {
			continue
		}
		t.Run(shape.name, func(t *testing.T) {
			repo := homeTestRepo(t)
			applyHomeShape(t, shape)
			ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: repo, AgentType: "main"}
			d := classifyBash(`HOME=/absolute/home; cat "$HOME/x"`, ev)
			if d.Operation == homeUnusableOp {
				t.Fatalf("an in-script absolute HOME= is usable and must not deny at the chokepoint "+
					"(reason=%q)", d.Reason)
			}
		})
	}
}

// TestHomeChokepointBareCd covers the one home reference spelled with no
// home-referencing WORD: bare `cd` goes to $HOME, so it is a home reference by
// definition and denies at the chokepoint under an unusable home exactly as
// `cat ~/x` does. Under a usable home it tracks $HOME, so the command reads
// outside the repo and must not ride the allow track either.
func TestHomeChokepointBareCd(t *testing.T) {
	for _, cmd := range []string{`cd && cat ../x`, `cd; cat x`} {
		for _, shape := range homeShapes() {
			t.Run(shape.name+"/"+cmd, func(t *testing.T) {
				repo := homeTestRepo(t)
				applyHomeShape(t, shape)
				ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: repo, AgentType: "main"}
				d := classifyBash(cmd, ev)
				if !shape.usable {
					if d.Bucket != BucketDeny || d.Operation != homeUnusableOp {
						t.Fatalf("%q with a %s home: got bucket %q op %q (reason=%q), want deny/%s",
							cmd, shape.name, d.Bucket, d.Operation, d.Reason, homeUnusableOp)
					}
					return
				}
				if d.Operation == homeUnusableOp {
					t.Fatalf("%q with an absolute home must not deny at the home chokepoint (reason=%q)",
						cmd, d.Reason)
				}
				if d.Bucket == BucketAllow {
					t.Fatalf("%q with an absolute home reads outside the repo and must not allow (reason=%q)",
						cmd, d.Reason)
				}
			})
		}
	}
}

// TestHomeChokepointFileTool crosses the home shapes with a file-tool operand
// naming the home directory.
func TestHomeChokepointFileTool(t *testing.T) {
	for _, shape := range homeShapes() {
		for _, tool := range []string{"Read", "Write", "Edit"} {
			t.Run(shape.name+"/"+tool, func(t *testing.T) {
				repo := homeTestRepo(t)
				applyHomeShape(t, shape)
				ev := &Event{
					HookEventName: "PreToolUse",
					ToolName:      tool,
					CWD:           repo,
					AgentType:     "main",
					ToolInput:     json.RawMessage(`{"file_path":"~/x"}`),
				}
				d := classifyFileTool(ev)
				if !shape.usable {
					if d.Bucket != BucketDeny || d.Operation != homeUnusableOp {
						t.Fatalf("%s ~/x with a %s home: got bucket %q op %q (reason=%q), want deny/%s",
							tool, shape.name, d.Bucket, d.Operation, d.Reason, homeUnusableOp)
					}
					return
				}
				if d.Operation == homeUnusableOp {
					t.Fatalf("%s ~/x with an absolute home must not deny at the home chokepoint", tool)
				}
			})
		}
	}
}

// TestHomeUsabilityDoesNotMoveHomelessEvents pins the containment half of the
// change: an event that references no home path gets the SAME verdict under
// an unusable home as under an absolute one. Without this the chokepoint could
// be a blanket deny and every row above would still pass.
func TestHomeUsabilityDoesNotMoveHomelessEvents(t *testing.T) {
	commands := []string{
		`cat file.txt`,
		`git status`,
		`cd sub && cat ../file.txt`,
		`rm -rf /`,
	}
	for _, cmd := range commands {
		t.Run(cmd, func(t *testing.T) {
			var buckets []Bucket
			var ops []string
			for _, shape := range homeShapes() {
				repo := homeTestRepo(t)
				applyHomeShape(t, shape)
				ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: repo, AgentType: "main"}
				d := classifyBash(cmd, ev)
				buckets = append(buckets, d.Bucket)
				ops = append(ops, d.Operation)
			}
			for i := range buckets {
				if buckets[i] != buckets[0] || ops[i] != ops[0] {
					t.Fatalf("%q moved with the home shape: %v / %v", cmd, buckets, ops)
				}
			}
		})
	}
}

// TestHomeUsabilityNonVerdictReaders pins the three readers that produce no
// verdict — the evolution log, the carve-out config loader, and the Claude
// config root. Each fails closed on an unusable home rather than composing a
// relative path.
func TestHomeUsabilityNonVerdictReaders(t *testing.T) {
	for _, shape := range homeShapes() {
		t.Run(shape.name, func(t *testing.T) {
			// PERMISSION_GATE_LOG would override the home-derived log path;
			// clear it so the home arm is the one under test.
			t.Setenv(logEnvVar, "")
			applyHomeShape(t, shape)

			gotLog := logPath()
			gotConfig := operatorCarveOutConfigPath()
			gotRoot := claudeConfigRoot()
			carve := loadOperatorCarveOut()

			if !shape.usable {
				if gotLog != "" {
					t.Errorf("logPath() = %q with a %s home, want \"\" (no log written)", gotLog, shape.name)
				}
				if gotConfig != "" {
					t.Errorf("operatorCarveOutConfigPath() = %q with a %s home, want \"\"", gotConfig, shape.name)
				}
				if gotRoot != "" {
					t.Errorf("claudeConfigRoot() = %q with a %s home, want \"\"", gotRoot, shape.name)
				}
				if !carve.empty() {
					t.Errorf("loadOperatorCarveOut() with a %s home must load nothing", shape.name)
				}
				return
			}
			if gotLog == "" || !filepath.IsAbs(gotLog) {
				t.Errorf("logPath() = %q with an absolute home, want an absolute path", gotLog)
			}
			if gotConfig == "" || !filepath.IsAbs(gotConfig) {
				t.Errorf("operatorCarveOutConfigPath() = %q with an absolute home, want an absolute path",
					gotConfig)
			}
		})
	}
}

// TestHomeChokepointPrefixAssignment pins the prefix/persistent split. A
// `HOME=x cmd` prefix sets the environment of that one command and is not
// recorded by the gate's word resolution, so it neither rescues a word from an
// unusable process home nor condemns one under a usable process home. Both
// halves are measured against the committed binary: `HOME=/absolute/home cat
// ~/x` resolves the tilde against the PROCESS home, where `HOME=/absolute/home;
// cat ~/x` resolves it against `/absolute/home`.
func TestHomeChokepointPrefixAssignment(t *testing.T) {
	for _, shape := range homeShapes() {
		t.Run(shape.name, func(t *testing.T) {
			repo := homeTestRepo(t)
			applyHomeShape(t, shape)
			ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: repo, AgentType: "main"}

			// An ABSOLUTE prefix cannot rescue a word from an unusable process
			// home, because the word does not resolve against the prefix.
			d := classifyBash(`HOME=/absolute/home cat ~/x`, ev)
			if shape.usable && d.Operation == homeUnusableOp {
				t.Errorf("a usable process home must not deny at the chokepoint (reason=%q)", d.Reason)
			}
			if !shape.usable && (d.Bucket != BucketDeny || d.Operation != homeUnusableOp) {
				t.Errorf("`HOME=/absolute/home cat ~/x` with a %s process home: got bucket %q op %q, "+
					"want deny/%s", shape.name, d.Bucket, d.Operation, homeUnusableOp)
			}

			// A RELATIVE prefix does not condemn a word either — the word
			// resolves against the process home, so a usable one still stands.
			d = classifyBash(`HOME=relhome cat ~/x`, ev)
			if shape.usable && d.Operation == homeUnusableOp {
				t.Errorf("a relative HOME= PREFIX must not deny a word that resolves against a usable "+
					"process home (reason=%q)", d.Reason)
			}
		})
	}
}
