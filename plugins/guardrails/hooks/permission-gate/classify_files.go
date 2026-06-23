package main

import (
	"fmt"
	"path/filepath"
)

// classifyFileTool runs Engine B containment for a Read/Write/Edit/
// MultiEdit/NotebookEdit call. Every path-bearing field in tool_input is
// tested; the worst result wins (escape → deny, contained → defer to the
// normal pipeline).
//
// Writes and reads are treated identically for the CONTAINMENT decision:
// both #127 (write into the primary clone) and #148 (read a sibling repo)
// are escapes. The hook only DENIES on a proven escape; an in-worktree path
// defers (the normal pipeline / settings.json denyRead etc. still apply).
func classifyFileTool(ev *Event) Decision {
	paths, err := ev.filePaths()
	if err != nil {
		return ask("file:unreadable-input", fmt.Sprintf(
			"Blocked: could not read the file path from this %s event (%v); escalating to a human (fail-closed).",
			ev.ToolName, err))
	}
	if len(paths) == 0 {
		// Nothing to guard (e.g. a tool form with no path) — defer.
		return deferToPipeline()
	}

	rc, err := resolveRepoContext(ev.CWD)
	if err != nil {
		// Fail-closed: we cannot establish the boundary, so we cannot prove
		// the target is in-bounds. ASK rather than allow.
		return ask("file:no-repo-context", fmt.Sprintf(
			"Blocked: could not resolve the repository/worktree boundary for this %s (%v). "+
				"Escalating to a human decision (fail-closed) rather than allowing a possibly out-of-bounds path.",
			ev.ToolName, err))
	}

	for _, p := range paths {
		// #125 (write half): a file-mutating tool whose canonicalized target is
		// a git `config` file is a direct .git/config identity-surface write.
		// This is denied independently of containment — an in-worktree
		// .git/config write would otherwise be `contained` and defer. Reads of
		// .git/config are not mutations, so this is gated on a mutating tool.
		if isMutatingFileTool(ev.ToolName) && isGitConfigPath(canonicalize(p), rc) {
			return deny("write:.git/config (#125 write)", fmt.Sprintf(
				"Blocked: %s target '%s' is a git config file. Directly editing .git/config can rewrite "+
					"committer identity and other repo settings (the #125 write half) outside the controlled "+
					"environment. Do not edit .git/config by hand; if a setting is genuinely wrong, surface it to "+
					"the human rather than rewriting it. See issue #125.",
				ev.ToolName, p))
		}

		res, real := testContainment(p, rc)
		switch res {
		case escapeWorktree:
			correct := correctWorktreePath(real, rc)
			return deny("containment:worktree-escape (#127)", fmt.Sprintf(
				"Blocked: %s target '%s' resolves to the primary clone / shared git dir (%s), not this worktree (%s). "+
					"Writes and edits must land inside this worktree. Use the worktree-anchored path instead: %s. "+
					"Anchor every absolute path to $(git rev-parse --show-toplevel). See issues #127, #188.",
				ev.ToolName, p, real, rc.topLevel, correct))
		case escapeRepo:
			return deny("containment:cross-repo (#148)", fmt.Sprintf(
				"Blocked: %s target '%s' resolves outside the current repository (%s, repo root %s). "+
					"Tool-mediated reads and writes must stay within the current repo — do not reach into a sibling "+
					"repo (e.g. another project's node_modules). If you need third-party API details, consult the "+
					"dependency's published docs instead. See issue #148.",
				ev.ToolName, p, real, rc.topLevel))
		case claudeConfig:
			// The agent's own ~/.claude global config tree (#247). Required
			// startup reading, allow-listed in settings.json. Defer so that
			// allow-list governs it rather than the #148 cross-repo deny.
		case contained:
			// ok; keep checking the remaining paths
		}
	}
	// All targets are inside this worktree — defer to the normal pipeline
	// (settings.json denyRead, ask lists, etc. still apply).
	return deferToPipeline()
}

// classifyPathReader runs containment on the path arguments of a read-class
// Bash program (cat/head/tail/...). Flags and option values are skipped; the
// remaining tokens are treated as path operands and tested with Engine B.
//
// #148: a bash-read targeting a sibling repo's node_modules is blocked.
func classifyPathReader(prog string, args []string, sc simpleCommand, ev *Event) Decision {
	if sc.hasUnknownExpansion {
		// A path built from a command substitution / unresolved variable can't
		// be statically contained → escalate to a human (fail-closed).
		return ask("bash-read:dynamic-path", fmt.Sprintf(
			"Blocked: '%s' has a path argument built from an expansion the gate cannot resolve statically; "+
				"escalating to a human decision (fail-closed).", prog))
	}

	operands := pathOperands(args)
	if len(operands) == 0 {
		return deferToPipeline()
	}

	rc, err := resolveRepoContext(ev.CWD)
	if err != nil {
		return ask("bash-read:no-repo-context", fmt.Sprintf(
			"Blocked: could not resolve the repository boundary for '%s' (%v); escalating to a human (fail-closed).",
			prog, err))
	}

	for _, p := range operands {
		res, real := testContainment(p, rc)
		switch res {
		case escapeRepo:
			return deny("bash-read:cross-repo (#148)", fmt.Sprintf(
				"Blocked: '%s' would read '%s' which resolves outside the current repository (%s, repo root %s). "+
					"Do not read another repo's files (e.g. a sibling project's node_modules) to verify third-party "+
					"APIs — use the dependency's published docs. See issue #148.",
				prog, p, real, rc.topLevel))
		case escapeWorktree:
			// Reading the primary clone from a worktree is suspect but not as
			// clearly forbidden as a write; escalate to a human.
			return ask("bash-read:worktree-escape", fmt.Sprintf(
				"'%s' would read '%s' in the primary clone / shared git dir rather than this worktree (%s). "+
					"Confirm this is intended.", prog, real, rc.topLevel))
		case claudeConfig:
			// The agent's own ~/.claude global config tree (#247) — required
			// startup reading, allow-listed in settings.json. Defer.
		case contained:
		}
	}
	return deferToPipeline()
}

// pathOperands returns the non-flag tokens of a read-class command, treating
// them as path operands. Tokens after a `--` separator are all operands. A
// leading-dash token is treated as a flag and skipped; this is conservative
// (a real path starting with `-` is vanishingly rare and a missed operand only
// loses a containment check, which then defers, not allows).
func pathOperands(args []string) []string {
	var out []string
	sawDashDash := false
	for _, a := range args {
		if sawDashDash {
			out = append(out, a)
			continue
		}
		if a == "--" {
			sawDashDash = true
			continue
		}
		if len(a) > 0 && a[0] == '-' {
			continue
		}
		out = append(out, a)
	}
	return out
}

// isMutatingFileTool reports whether the tool writes/edits files (as opposed to
// Read, which only reads). The .git/config write rule (#125) applies only to
// mutating tools — reading .git/config is not an identity write.
func isMutatingFileTool(name string) bool {
	switch name {
	case "Write", "Edit", "MultiEdit", "NotebookEdit":
		return true
	default:
		return false
	}
}

// isGitConfigPath reports whether the canonicalized target is a git `config`
// file (#125 write half). Two forms are matched:
//
//   - The current repo's resolved shared git dir + "/config" (rc.commonDir is
//     <gitdir>; <gitdir>/config is the canonical config-file location). This is
//     the precise, canonicalization-safe match for THIS repo.
//   - Any path whose final two segments are ".git/config", covering a direct
//     edit of some other ".git/config" the containment layer would otherwise
//     wave through (e.g. a nested submodule's, or a path the harness presents
//     literally). The basename is "config" and its parent is ".git".
//
// real is expected to already be canonicalized.
func isGitConfigPath(real string, rc *repoContext) bool {
	if real == "" {
		return false
	}
	if rc != nil && rc.commonDir != "" {
		if real == filepath.Join(rc.commonDir, "config") {
			return true
		}
	}
	if filepath.Base(real) == "config" && filepath.Base(filepath.Dir(real)) == ".git" {
		return true
	}
	return false
}

// correctWorktreePath rewrites a primary-clone path to its in-worktree
// equivalent, for the #127 remediation message. Returns the original real
// path if the rewrite cannot be derived.
func correctWorktreePath(real string, rc *repoContext) string {
	if rc.primaryClone != "" && pathUnder(real, rc.primaryClone) {
		rel := real[len(rc.primaryClone):]
		return rc.topLevel + rel
	}
	return rc.topLevel + "/<the-intended-relative-path>"
}
