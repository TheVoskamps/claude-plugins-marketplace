#!/usr/bin/env bash
#
# cr-test.sh -- drive plugins/cc-tools/bin/cr, hooks/cr-resolver and
# hooks/cr-deploy.sh under the bash 3.2 macOS ships, with HOME pointed at
# a scratch directory and a stub claude first on PATH: cr's argument
# handling, repo detection, settings overlay, GIT_CONFIG_GLOBAL and exit
# status; the resolver's exec of the enabled cc-tools and its refusals;
# and the deploy hook's missing, differing, current and unwritable
# targets and its unset or empty HOME.
#
# Needs git and jq on PATH. Reaches no network.
#
# Usage: cr-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CR="$TEST_DIR/../bin/cr"
RESOLVER="$TEST_DIR/../hooks/cr-resolver"
DEPLOY="$TEST_DIR/../hooks/cr-deploy.sh"
HOOKS_JSON="$TEST_DIR/../hooks/hooks.json"
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cr-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0

# check <actual> <expected> <label>: passes when the two are equal, and
# otherwise prints both and counts a failure in FAILURES.
check() {
  if [ "$1" = "$2" ]; then
    echo "PASS  $3"
  else
    echo "FAIL  $3"
    echo "      expected: $2"
    echo "      actual:   $1"
    FAILURES=$((FAILURES + 1))
  fi
}

# check_contains <actual> <substring> <label>: passes when the actual
# text contains the substring, and otherwise prints both and counts a
# failure in FAILURES.
check_contains() {
  case "$1" in
    *"$2"*) echo "PASS  $3" ;;
    *)
      echo "FAIL  $3"
      echo "      expected to contain: $2"
      echo "      actual:              $1"
      FAILURES=$((FAILURES + 1))
      ;;
  esac
}

# check_lacks <actual> <substring> <label>: the negation of
# check_contains.
check_lacks() {
  case "$1" in
    *"$2"*)
      echo "FAIL  $3"
      echo "      expected not to contain: $2"
      echo "      actual:                  $1"
      FAILURES=$((FAILURES + 1))
      ;;
    *) echo "PASS  $3" ;;
  esac
}

export HOME="$SANDBOX/home"
mkdir -p "$HOME"
unset GIT_CONFIG_GLOBAL
export GIT_CEILING_DIRECTORIES="$SANDBOX"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
JQ="$(command -v jq)"

# The stub claude answers `plugin list --json` with $SANDBOX/plugins.json
# and the status in $SANDBOX/list.rc, 0 when absent. Any other call is a
# launch: it writes its arguments one per line to $SANDBOX/claude.args,
# its directory, GIT_CONFIG_GLOBAL and whether ./.git exists to
# $SANDBOX/claude.env, sends the signal named in $SANDBOX/claude.signal
# to its parent and then to itself when that file exists, and exits
# with the status in $SANDBOX/claude.rc, 0 when absent. It names every
# command by absolute path so it runs on the restricted PATHs below.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/claude" <<EOF
#!/bin/sh
if [ "\$*" = "plugin list --json" ]; then
  [ ! -f "$SANDBOX/plugins.json" ] || /bin/cat "$SANDBOX/plugins.json"
  exit "\$(/bin/cat "$SANDBOX/list.rc" 2>/dev/null || echo 0)"
fi
: >"$SANDBOX/claude.args"
for a in "\$@"; do printf '%s\n' "\$a" >>"$SANDBOX/claude.args"; done
{
  echo "pwd=\$(/bin/pwd -P)"
  echo "gcg=\${GIT_CONFIG_GLOBAL-}"
  if [ -d .git ]; then echo "git=yes"; else echo "git=no"; fi
} >"$SANDBOX/claude.env"
if [ -f "$SANDBOX/claude.signal" ]; then
  sig=\$(/bin/cat "$SANDBOX/claude.signal")
  kill -"\$sig" "\$PPID"
  kill -"\$sig" \$\$
fi
exit "\$(/bin/cat "$SANDBOX/claude.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$SANDBOX/bin/claude"

# reset -- forget the previous launch.
reset() {
  rm -f "$SANDBOX/claude.args" "$SANDBOX/claude.env" "$SANDBOX/claude.rc" "$SANDBOX/claude.signal"
}

# run_cr <dir> [<arg>…] -- run bin/cr from <dir> with the stub claude
# first on PATH; leaves ARGS (claude's arguments, one per line), ENV,
# ERR and RC.
run_cr() {
  local dir=$1
  shift
  reset
  (cd "$dir" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" "$@") >/dev/null 2>"$SANDBOX/stderr"
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
  ARGS=$(cat "$SANDBOX/claude.args" 2>/dev/null)
  ENV=$(cat "$SANDBOX/claude.env" 2>/dev/null)
}

# lines <word>… -- the words, one per line, as claude.args holds them.
lines() {
  printf '%s\n' "$@"
}

check "$([ -x "$CR" ] && echo yes)" "yes" "bin/cr is executable"
check "$([ -x "$RESOLVER" ] && echo yes)" "yes" "hooks/cr-resolver is executable"
check "$([ -x "$DEPLOY" ] && echo yes)" "yes" "hooks/cr-deploy.sh is executable"
check "$("$JQ" -r '.hooks.SessionStart[].hooks[].command' "$HOOKS_JSON")" \
  "\${CLAUDE_PLUGIN_ROOT}/hooks/cr-deploy.sh" "hooks.json registers cr-deploy.sh on SessionStart"

# --- bin/cr: inside a repo with an origin -----------------------------------
REPO="$SANDBOX/myrepo"
git init -q "$REPO"
git -C "$REPO" remote add origin git@github.com:owner/my-repo.git
mkdir -p "$REPO/sub"

run_cr "$REPO/sub" fix the bug --model opus "two words"
check "$RC" "0" "repo: exit 0"
check "$ARGS" "$(lines --name "fix the bug my-repo" --remote-control \
  --debug-file "$HOME/.claude/logs/fix the bug my-repo" --allowedTools Grep Glob --model opus "two words")" \
  "repo: name words before the first flag, the rest passed unchanged, no --settings without an overlay"
check_contains "$ENV" "pwd=$REPO
" "repo: claude runs from the repo root"
check_contains "$ERR" "cr: detected existing git repo; cd to repo root $REPO" "repo: stderr names the root"
check_contains "$ENV" "git=yes" "repo: the repo's own .git is there"
check "$([ -d "$REPO/.git" ] && echo kept)" "kept" "repo: the existing .git is left alone"

run_cr "$REPO" --model opus fix
check "$(sed -n '9,$p' "$SANDBOX/claude.args")" "$(lines --model opus fix)" \
  "first flag first: no name words, and a word after a flag passes to claude"

run_cr "$REPO"
NAME=$(sed -n 2p "$SANDBOX/claude.args")
case "$NAME" in
  [A-Z][a-z][a-z][0-3][0-9]-[0-2][0-9]:[0-5][0-9]\ my-repo) STAMP=ok ;;
  *) STAMP="$NAME" ;;
esac
check "$STAMP" "ok" "no name words: a %b%d-%H:%M date stamp names the session"
check "$(sed -n '9,$p' "$SANDBOX/claude.args")" "" "no arguments: nothing passed through"

git -C "$REPO" remote set-url origin https://example.com/owner/plain
run_cr "$REPO" x
check "$(sed -n 2p "$SANDBOX/claude.args")" "x plain" "origin with no .git suffix: its last component names the repo"
git -C "$REPO" remote set-url origin git@github.com:owner/my-repo.git

# --- bin/cr: the settings overlay -------------------------------------------
mkdir -p "$REPO/.cc-tools"
echo '{}' >"$REPO/.cc-tools/cr-settings.json"
run_cr "$REPO/sub" x --model opus
check "$ARGS" "$(lines --name "x my-repo" --remote-control --debug-file "$HOME/.claude/logs/x my-repo" \
  --settings "$REPO/.cc-tools/cr-settings.json" --allowedTools Grep Glob --model opus)" \
  "overlay: claude receives --settings <repo-root>/.cc-tools/cr-settings.json"
rm -r "$REPO/.cc-tools"

mkdir -p "$REPO/sub/.cc-tools"
echo '{}' >"$REPO/sub/.cc-tools/cr-settings.json"
run_cr "$REPO/sub" x
check_lacks "$ARGS" "--settings" "overlay below the root only: no --settings"
rm -r "$REPO/sub/.cc-tools"

# --- bin/cr: GIT_CONFIG_GLOBAL ----------------------------------------------
run_cr "$REPO" x
check_contains "$ENV" "gcg=
" "no .gitconfig-claude: GIT_CONFIG_GLOBAL stays unset"

echo "[user]" >"$HOME/.gitconfig-claude"
run_cr "$REPO" x
check_contains "$ENV" "gcg=$HOME/.gitconfig-claude" "a readable .gitconfig-claude: GIT_CONFIG_GLOBAL exported"

reset
(cd "$REPO" && GIT_CONFIG_GLOBAL=/elsewhere PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" x) >/dev/null 2>&1
check_contains "$(cat "$SANDBOX/claude.env")" "gcg=/elsewhere" "GIT_CONFIG_GLOBAL already set: left as it is"
rm "$HOME/.gitconfig-claude"

# --- bin/cr: exit status ----------------------------------------------------
reset
echo 7 >"$SANDBOX/claude.rc"
(cd "$REPO" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" x) >/dev/null 2>&1
check "$?" "7" "claude's exit status is cr's"

# --- bin/cr: a repo with no origin ------------------------------------------
LOCAL="$SANDBOX/local"
git init -q "$LOCAL"
run_cr "$LOCAL" x
check "$(sed -n 2p "$SANDBOX/claude.args")" "x (local)" "no origin: the repo is named (local)"

run_cr "$LOCAL" --cr-strict x
check "$RC" "1" "--cr-strict, no origin: exit 1"
check "$ERR" "cr: --cr-strict: this git repo has no 'origin' remote" "--cr-strict, no origin: stderr says why"
check "$ARGS" "" "--cr-strict, no origin: claude does not run"

run_cr "$REPO" --cr-strict x
check "$RC:$(sed -n 2p "$SANDBOX/claude.args")" "0:x my-repo" "--cr-strict with an origin: claude runs"

run_cr "$REPO" x --cr-strict
check "$(sed -n '9,$p' "$SANDBOX/claude.args")" "--cr-strict" "--cr-strict not first: passed to claude"

# --- bin/cr: outside a git repo ---------------------------------------------
PLAIN="$SANDBOX/plain"
mkdir -p "$PLAIN"
run_cr "$PLAIN" --cr-strict x
check "$RC" "1" "--cr-strict outside a repo: exit 1"
check "$ERR" "cr: --cr-strict: not inside a git repo" "--cr-strict outside a repo: stderr says why"
check "$ARGS:$([ -e "$PLAIN/.git" ] && echo git)" ":" "--cr-strict outside a repo: no claude, no git init"

run_cr "$PLAIN" x
check "$RC:$(sed -n 2p "$SANDBOX/claude.args")" "0:x (local)" "outside a repo: the repo is named (local)"
check_contains "$ENV" "git=yes" "outside a repo: claude runs inside a fresh git init"
check_contains "$ENV" "pwd=$PLAIN
" "outside a repo: claude runs from the current directory"
check "$([ -e "$PLAIN/.git" ] && echo left)" "" "outside a repo: the .git is removed on exit"

for sig in INT TERM; do
  reset
  echo "$sig" >"$SANDBOX/claude.signal"
  (cd "$PLAIN" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" x) >/dev/null 2>&1
  RC=$?
  check "$(grep -c git=yes "$SANDBOX/claude.env"):$([ -e "$PLAIN/.git" ] && echo left)" "1:" \
    "outside a repo, $sig: the .git is removed"
  check "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero" "outside a repo, $sig: cr exits non-zero"
done

# --- hooks/cr-resolver ------------------------------------------------------
# Two fake installs: the enabled one and a disabled one listed first. Each
# fake bin/cr records its arguments in a file of its own.
for v in enabled disabled; do
  mkdir -p "$SANDBOX/install/$v/bin"
  cat >"$SANDBOX/install/$v/bin/cr" <<EOF
#!/bin/sh
: >"$SANDBOX/$v.args"
for a in "\$@"; do printf '%s\n' "\$a" >>"$SANDBOX/$v.args"; done
exit 5
EOF
  chmod +x "$SANDBOX/install/$v/bin/cr"
done

# entry <id> <enabled> <path> -- one `claude plugin list --json` element.
entry() {
  printf '{"id": "%s", "enabled": %s, "installPath": "%s"}' "$1" "$2" "$3"
}

# PATHs for the resolver: the stub claude, with and without jq.
mkdir -p "$SANDBOX/withjq" "$SANDBOX/nojq"
ln -s "$SANDBOX/bin/claude" "$SANDBOX/withjq/claude"
ln -s "$SANDBOX/bin/claude" "$SANDBOX/nojq/claude"
ln -s "$JQ" "$SANDBOX/withjq/jq"

# run_resolver <path> [<arg>…] -- run the resolver with PATH=<path>;
# leaves ERR and RC.
run_resolver() {
  local path=$1
  shift
  reset
  rm -f "$SANDBOX/enabled.args" "$SANDBOX/disabled.args"
  PATH="$path" /bin/bash "$RESOLVER" "$@" >/dev/null 2>"$SANDBOX/stderr"
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
}

echo "[$(entry other@thevoskamps true /nowhere), \
$(entry cc-tools@thevoskamps false "$SANDBOX/install/disabled"), \
$(entry cc-tools@thevoskamps true "$SANDBOX/install/enabled")]" >"$SANDBOX/plugins.json"

run_resolver "$SANDBOX/withjq" a "b c" --model opus
check "$RC" "5" "resolver: execs the enabled install's bin/cr, whose status is its own"
check "$(cat "$SANDBOX/enabled.args" 2>/dev/null)" "$(lines a "b c" --model opus)" \
  "resolver: the arguments reach bin/cr unchanged"
check "$([ -f "$SANDBOX/disabled.args" ] && echo ran)" "" "resolver: a disabled install's bin/cr does not run"
check "$ERR" "" "resolver: nothing on stderr"

run_resolver "$SANDBOX/nojq" a
check "$RC" "1" "resolver, no jq: exit 1"
check_contains "$ERR" "cr: jq is not on PATH" "resolver, no jq: stderr says so"
check "$([ -f "$SANDBOX/enabled.args" ] && echo ran)" "" "resolver, no jq: bin/cr does not run"

echo "[$(entry cc-tools@thevoskamps false "$SANDBOX/install/disabled")]" >"$SANDBOX/plugins.json"
run_resolver "$SANDBOX/withjq" a
check "$RC" "1" "resolver, cc-tools disabled: exit 1"
check_contains "$ERR" "cr: no enabled cc-tools@thevoskamps is installed" "resolver, cc-tools disabled: stderr says so"
check "$([ -f "$SANDBOX/disabled.args" ] && echo ran)$([ -f "$SANDBOX/claude.args" ] && echo claude)" "" \
  "resolver, cc-tools disabled: neither bin/cr nor claude runs"

echo "[]" >"$SANDBOX/plugins.json"
run_resolver "$SANDBOX/withjq" a
check "$RC:$([ -f "$SANDBOX/claude.args" ] && echo claude)" "1:" "resolver, cc-tools not installed: exit 1, claude does not run"
check_contains "$ERR" "cr: no enabled cc-tools@thevoskamps is installed" "resolver, cc-tools not installed: stderr says so"

echo 1 >"$SANDBOX/list.rc"
run_resolver "$SANDBOX/withjq" a
check "$RC" "1" "resolver, plugin list fails: exit 1"
check_contains "$ERR" "cr: \`claude plugin list --json\` failed" "resolver, plugin list fails: stderr says so"
rm "$SANDBOX/list.rc"

# --- hooks/cr-deploy.sh -----------------------------------------------------
TARGET_DIR="$HOME/.local/bin"
TARGET="$TARGET_DIR/cr"

# run_deploy <path> -- run the hook with PATH=<path>:/usr/bin:/bin;
# leaves OUT, ERR and RC.
run_deploy() {
  OUT=$(PATH="$1:/usr/bin:/bin" /bin/bash "$DEPLOY" </dev/null 2>"$SANDBOX/stderr")
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
}

# same_file -- whether $TARGET is still the file hard-linked as
# $SANDBOX/before, which a replacement breaks.
same_file() {
  [ "$TARGET" -ef "$SANDBOX/before" ] && echo same
}

check "$([ -e "$TARGET_DIR" ] && echo there)" "" "deploy: ~/.local/bin starts absent"
run_deploy "$SANDBOX/elsewhere"
check "$RC:$ERR" "0:" "deploy, missing target: exit 0, nothing on stderr"
check "$(cmp -s "$RESOLVER" "$TARGET" && echo same)" "same" "deploy, missing target: the resolver is written"
check "$([ -x "$TARGET" ] && echo yes)" "yes" "deploy, missing target: the written file is executable"
check "$(printf '%s' "$OUT" | "$JQ" -r '.systemMessage')" \
  "cc-tools updated the cr launcher at $TARGET; restart your shell and run cr to use it. $TARGET_DIR is not on PATH, so add it before cr can be found." \
  "deploy, missing target, not on PATH: the systemMessage says both"
check "$(find "$TARGET_DIR" -name '.cr.*')" "" "deploy: no temporary file is left behind"

ln "$TARGET" "$SANDBOX/before"
run_deploy "$TARGET_DIR"
check "$RC:$OUT" "0:" "deploy, current target: exit 0, nothing on stdout"
check "$(same_file)" "same" "deploy, current target: the file is not replaced"
rm "$SANDBOX/before"

echo "old" >"$TARGET"
ln "$TARGET" "$SANDBOX/before"
run_deploy "$TARGET_DIR"
check "$RC" "0" "deploy, differing target: exit 0"
check "$(cmp -s "$RESOLVER" "$TARGET" && echo same)" "same" "deploy, differing target: the resolver replaces it"
check "$(same_file)" "" "deploy, differing target: the file is replaced, not edited in place"
check "$(printf '%s' "$OUT" | "$JQ" -r '.systemMessage')" \
  "cc-tools updated the cr launcher at $TARGET; restart your shell and run cr to use it." \
  "deploy, differing target, on PATH: the systemMessage has no PATH note"

rm -r "$HOME/.local"
mkdir -p "$HOME/.local"
echo "a file" >"$TARGET_DIR"
run_deploy "$TARGET_DIR"
check "$RC" "0" "deploy, unwritable target: exit 0"
check "$(printf '%s' "$OUT" | "$JQ" -r '.systemMessage')" \
  "cc-tools could not update the cr launcher at $TARGET." "deploy, unwritable target: the systemMessage says so"

OUT=$(env -u HOME PATH=/usr/bin:/bin /bin/bash "$DEPLOY" </dev/null 2>"$SANDBOX/stderr")
RC=$?
check "$RC:$(cat "$SANDBOX/stderr")" "0:" "deploy, HOME unset: exit 0, nothing on stderr"
check "$(printf '%s' "$OUT" | "$JQ" -r '.systemMessage')" \
  "cc-tools could not update the cr launcher at ~/.local/bin/cr: HOME is not set." \
  "deploy, HOME unset: the systemMessage says so"

OUT=$(HOME='' PATH=/usr/bin:/bin /bin/bash "$DEPLOY" </dev/null 2>"$SANDBOX/stderr")
RC=$?
check "$RC:$(cat "$SANDBOX/stderr")" "0:" "deploy, HOME empty: exit 0, nothing on stderr"
check "$(printf '%s' "$OUT" | "$JQ" -r '.systemMessage')" \
  "cc-tools could not update the cr launcher at ~/.local/bin/cr: HOME is not set." \
  "deploy, HOME empty: the systemMessage says so"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
