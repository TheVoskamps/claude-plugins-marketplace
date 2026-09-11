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
		// A NAKED `export HOME` carries no value — a no-op for `$HOME` in bash —
		// so the home keeps the grade it already had and the `~` after it is
		// judged against the process home. Only `HOME=`, which sets the EMPTY
		// home, is the empty-home spelling, and it denies under every process
		// home.
		{cmd: `export HOME; cat ~/x`},
		{cmd: `HOME=; cat ~/x`, alwaysDenies: true},
		// A SCOPED assignment does not set the home the words after the scope
		// resolve against, so it may only make the gate stricter. An absolute
		// one cannot rescue a `~` from an unusable process home…
		{cmd: `(HOME=/absolute/home); cat ~/x`},
		{cmd: `f() { HOME=/absolute/home; }; cat ~/x`},
		// …while a relative one is still graded as if it persisted, which
		// denies under a process home bash would have resolved the `~` against.
		{cmd: `(HOME=relhome); cat ~/x`, alwaysDenies: true},
		// A command substitution on a PERSISTENT assignment's RHS is one of
		// those scopes: the walk descends into it like any other, so the
		// `HOME=` inside takes effect in the unusable direction.
		{cmd: `X=$(HOME=relhome; echo hi); cat ~/x`, alwaysDenies: true},
		// A loop variable bound by the walk's own fan-out names `cd` as
		// surely as a plain assignment does.
		{cmd: `HOME=relhome; for C in cd; do $C; done`, alwaysDenies: true},
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

// TestHomeChokepointBareCd covers the home references spelled with no
// home-referencing WORD: a `cd` carrying no DIRECTORY operand goes to $HOME, so
// it is a home reference by definition and denies at the chokepoint under an
// unusable home exactly as `cat ~/x` does. That is the operand-less spelling
// and every all-options one — `cd -P`, `cd -L`, `cd --` and their combinations,
// each of which bash sends to $HOME too — and every operand that MAY expand to
// no field at all: one that certainly does, which bash word-splits away before
// `cd` ever sees it (`X=; cd $X`), and equally one whose field count the gate
// cannot resolve (`cd $Z`, `cd $(…)`), which is graded as possibly none because
// an operand the gate cannot place belongs on the deny side, and equally an
// unquoted pathname-expansion pattern in either spelling — a metacharacter one
// (`cd *nomatch*`) and an extended-glob one (`cd @(nomatch)x`) — which
// `shopt -s nullglob` drops entirely when it matches nothing.
// `$C` with `C=cd` is here, as a plain assignment and as a
// loop-variable binding, because the chokepoint must recognize the same `cd`
// call applyCd does: resolved against a variable map that never learned `C`
// the program word is opaque, the chokepoint stays silent, and applyCd is left
// tracking a home the gate cannot place.
//
// Under a usable home none of them may ride the allow track. The operand-less
// spelling tracks $HOME, so the command reads outside the repo; the
// all-options spellings are read by applyCd as a RELATIVE target (it carries no
// option arm — `cd -P` tracks `<cwd>/-P`), and what holds them off the allow
// track there is the residual defer `cd` carries as an unclassified program.
func TestHomeChokepointBareCd(t *testing.T) {
	for _, cmd := range []string{
		`cd && cat ../x`,
		`cd; cat x`,
		`cd -P; cat x`,
		`cd -L; cat x`,
		`cd --; cat x`,
		`cd -P -L; cat x`,
		`C=cd; $C; cat x`,
		`for C in cd; do $C; done; cat x`,
		`X=; cd $X; cat x`,
		// An unquoted operand the gate cannot resolve has a field count it
		// cannot count either, and zero is one of the possibilities — bash
		// word-splits an unset expansion away and goes to $HOME. Graded as
		// possibly none, which is the deny direction.
		`cd $Z; cat x`,
		`cd $(printf sub); cat x`,
		// An unquoted glob is a possible zero-field expansion too: under
		// `shopt -s nullglob` bash drops a pattern that matches nothing, and
		// `shopt -s nullglob; cd *nomatch*` lands in $HOME (measured). A quoted
		// part beside the pattern does not save it — `cd "a"*nomatch*` is
		// dropped the same way — so the whole word is graded possibly-none.
		`cd *nomatch*; cat x`,
		`cd "a"*nomatch*; cat x`,
		// An extended-glob pattern is dropped by nullglob the same way, and it
		// carries no `*?[` of its own for a metacharacter scan over the word's
		// literal text to find: `shopt -s extglob nullglob; cd @(nomatch)x`
		// lands in $HOME too (measured), as does the `+(…)` spelling.
		`cd @(nomatch)x; cat x`,
		`cd +(nomatch)x; cat x`,
	} {
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

// TestHomeChokepointCdCarryingADirectory is the negative control for the row
// above: a `cd` that carries a directory operand names no home, so it must not
// deny at the chokepoint even under an unusable home. `cd -` is one of these —
// it names $OLDPWD, not $HOME — and so is an all-options `cd` that still has a
// directory after the options. So is an operand that expands to one EMPTY
// field rather than to none: bash keeps a quoted empty operand and stays put,
// where it word-splits an unquoted empty expansion away and goes to $HOME. So
// is an unresolvable expansion carrying a literal or quoted part beside it —
// that part yields a field whatever the expansion turns out to be, which is
// what separates these rows from the `cd $Z` one above and keeps the
// possibly-no-field arm from collapsing into "every unresolved operand".
//
// The rows come in two families, and a negation of wordMayYieldNoField reaches
// them in a fixed order — measured, by running each mutation against this file:
//
//   - Grading only a CERTAINLY-empty operand as zero-field (`exact &&
//     lit == ""`, the predicate's shape before it learned to count fields)
//     moves the three rows that RESOLVE to the empty string — `cd ""`,
//     `X=; cd "$X"`, `X=; cd $X""` — and leaves `cd $Z/sub` and `cd "$Z"`
//     passing, because an inexact word is not empty to it.
//   - Dropping the word-parts test instead (`!exact || lit == ""` alone) moves
//     those two as well: with nothing guaranteeing a field, every unresolvable
//     operand becomes a bare `cd`.
//
// So the inexact rows are pinned by the second mutation and not by the first,
// and no claim that "the negate-check moves every row here" is available.
func TestHomeChokepointCdCarryingADirectory(t *testing.T) {
	for _, cmd := range []string{
		`cd sub; cat x`,
		`cd -; cat x`,
		`cd -P /absolute/dir; cat x`,
		`cd ""; cat x`,
		`X=; cd "$X"; cat x`,
		// A quoted part beside an expansion that resolves EXACTLY to the empty
		// string still leaves one field, so this row grades as a directory
		// operand where `X=; cd $X` (above) grades as none.
		`X=; cd $X""; cat x`,
		// A literal or quoted part guarantees at least one field however
		// unresolvable the expansion beside it is, so an unresolved `$Z` alone
		// is a bare `cd` (above) while these two are not.
		`cd $Z/sub; cat x`,
		`cd "$Z"; cat x`,
		// A QUOTED pattern is not a pattern: bash matches no pathname against
		// it, so it cannot be dropped by nullglob and `cd "*nomatch*"` stays
		// put (measured). The negative control for the glob rows above, in
		// both the metacharacter and the extended-glob spelling.
		`cd "*nomatch*"; cat x`,
		`cd "@(nomatch)x"; cat x`,
	} {
		for _, shape := range homeShapes() {
			t.Run(shape.name+"/"+cmd, func(t *testing.T) {
				repo := homeTestRepo(t)
				applyHomeShape(t, shape)
				ev := &Event{HookEventName: "PreToolUse", ToolName: "Bash", CWD: repo, AgentType: "main"}
				d := classifyBash(cmd, ev)
				if d.Operation == homeUnusableOp {
					t.Fatalf("%q with a %s home names no home and must not deny at the chokepoint "+
						"(reason=%q)", cmd, shape.name, d.Reason)
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
//
// The carve-out row below is the stated exception, and it is here rather than
// in a test of its own because it is the boundary of the invariant above: a
// relaxation an unusable home withdraws moves the verdict even for an event
// that names no home. Its root deliberately sits OUTSIDE every home shape, so
// the row measures the withdrawal of the whole carve-out — the config file is
// found only at `$HOME/.config/guardrails/config.yml`, so an unusable home
// loads no config and no root survives, wherever that root pointed.
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

	t.Run("carve-out root outside the home", func(t *testing.T) {
		for _, shape := range homeShapes() {
			t.Run(shape.name, func(t *testing.T) {
				base := t.TempDir()
				repo := filepath.Join(base, "repo")
				gitInit(t, repo)
				// The root, the target under it, and the fixture home holding
				// the config are siblings, so the root is under no home shape
				// this test installs.
				root := filepath.Join(base, "operator-config")
				target := filepath.Join(root, "cc-tools", "whats-new.md")
				home := filepath.Join(base, "home")
				writeCarveOutConfig(t, home, "schema-version: 2\n"+
					"config-home-default: "+root+"\n"+
					"config-home:\n  read:\n    - cc-tools/**\n")

				applyHomeShape(t, shape)
				if shape.usable {
					// The shape's own home holds no config; point the process
					// at the one written above, so the file on disk is the same
					// in every row and only its reachability moves.
					t.Setenv("HOME", home)
				}

				d := fileToolVerdict(t, "Read", repo, target)
				if shape.usable {
					wantBucket(t, d, BucketAllow, "read of a listed path under a carve-out root outside the home")
					return
				}
				if d.Bucket == BucketAllow {
					t.Fatalf("a %s home must withdraw the carve-out even for a root outside the home "+
						"(reason=%q)", shape.name, d.Reason)
				}
				if d.Operation == homeUnusableOp {
					t.Fatalf("the target names no home, so the withdrawal must not read as a chokepoint "+
						"deny (reason=%q)", d.Reason)
				}
			})
		}
	})
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

// TestHomeUsabilityLogOverride pins the one log path that resolves no home.
// PERMISSION_GATE_LOG is the operator's own explicit destination, so this test
// asserts that an ABSOLUTE override is returned verbatim under every home
// shape, unusable ones included: the criterion is that no HOME-DERIVED path is
// composed, not that nothing is written.
//
// It asserts the override's own absoluteness alongside, which is what logPath
// grades — a RELATIVE override would compose against whatever directory the
// gate is running in, so it is graded with the same predicate a home is and
// writes nothing. Neither half reads the process home at all; the home shape
// is crossed in to show that it does not move the result.
func TestHomeUsabilityLogOverride(t *testing.T) {
	for _, shape := range homeShapes() {
		t.Run(shape.name, func(t *testing.T) {
			abs := filepath.Join(t.TempDir(), "gate.jsonl")
			t.Setenv(logEnvVar, abs)
			applyHomeShape(t, shape)

			if got := logPath(); got != abs {
				t.Errorf("logPath() = %q with an absolute override and a %s home, want %q", got, shape.name, abs)
			}

			t.Setenv(logEnvVar, "relative/gate.jsonl")
			if got := logPath(); got != "" {
				t.Errorf("logPath() = %q with a relative override and a %s home, want \"\" (no log written)",
					got, shape.name)
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
