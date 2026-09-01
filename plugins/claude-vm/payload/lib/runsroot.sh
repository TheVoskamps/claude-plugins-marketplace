#!/usr/bin/env bash
#
# runsroot.sh -- the ONE place the claude-vm per-run state root is composed
# (issue #181).
#
# A run dir holds the run's worktree, credential dir, runconfig dir, EFI
# variable store, per-run guest image clone, run.meta, run.lock and logs. Every
# consumer that has to find one -- the launcher that creates it, the cleaner
# that reaps an orphaned one, and the diff/apply skills that read run.meta out
# of one -- resolves it through this file rather than spelling the path again.
#
# Pure: sourcing it sets a variable and defines a function. No mkdir, no I/O,
# no VM. Sourced by payload/claude-vm.sh and by bin/claude-vm-cleanup; the
# diff/apply skills source it through $CLAUDE_PLUGIN_ROOT in the shell step
# they already run, so none of them composes the path in prose.
#
# WHY $XDG_STATE_HOME rather than the $XDG_CONFIG_HOME/claude-vm/ that
# lib/config.sh and lib/claude-cache.sh use: a run dir is run STATE, not
# configuration, and docs/config-file-conventions.md scopes
# $XDG_CONFIG_HOME/<plugin>/ to configuration.
#
# WHY host-scoped rather than per-repo: the run dir used to live inside the
# repo itself, in a git-ignored scratch directory under it, which made a sweep
# for orphaned residue a
# per-repo operation -- it could not see another repo's run dirs, and the
# orphaned gvproxy/proxy processes it must also reap have no repo affiliation
# at all. One host-scoped root is what makes a single cleaner sweep complete.
# A run's OWN repo is not lost by the move: run.meta records it as `repo_src`,
# which is what the diff/apply skills filter on to find "the most recent run
# for this repo".
#
# A run launched against an argument that is NOT a git repo lands here too,
# rather than in a $TMPDIR mktemp dir the cleaner's enumeration would never
# see, with run.meta's `repo_src` recording the argument as given.
#
# Overridable via the environment for testing, in the same
# `: "${VAR:=default}"` shape lib/config.sh uses for the config paths.

: "${CLAUDE_VM_RUNS_ROOT:=${XDG_STATE_HOME:-$HOME/.local/state}/claude-vm/runs}"

# Print the runs root on stdout. The callable form of the variable above, for
# a consumer that wants the value out of a subshell rather than into its own
# environment -- notably the diff/apply skills, whose shell step is
# `. "$CLAUDE_PLUGIN_ROOT/payload/lib/runsroot.sh" && claude_vm_runs_root`.
claude_vm_runs_root() {
  printf '%s\n' "$CLAUDE_VM_RUNS_ROOT"
}
