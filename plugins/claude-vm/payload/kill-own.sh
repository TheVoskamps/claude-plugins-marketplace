#!/usr/bin/env bash
#
# kill-own.sh -- claude_vm_kill_own as a command, for a caller that can only
# exec one: the run's watcher, which is lockf(1) running this once it holds
# the run's lock.
#
# Usage:
#   kill-own.sh <pid> <start> [<pid> <start> ...]
#
# Arguments are claude_vm_kill_own's (lib/config.sh), passed through as given.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

claude_vm_kill_own "$@"
