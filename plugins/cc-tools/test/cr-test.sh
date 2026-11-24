#!/usr/bin/env bash
#
# cr-test.sh -- drive plugins/cc-tools/bin/cr, hooks/cr-resolver and
# hooks/cr-deploy.sh under the bash 3.2 macOS ships, with HOME,
# XDG_CONFIG_HOME and XDG_STATE_HOME pointed at scratch directories and a
# stub claude, a stub gh and a stub ssh first on PATH: cr's argument
# handling, repo detection, repository identity, ssh host aliases included,
# settings layers and their merge, its refusals, GIT_CONFIG_GLOBAL, --as
# and the config directory, and exit status; the resolver's exec of the
# enabled cc-tools, its --as, its refusals and its failed execs; and the
# deploy hook's missing, differing, current and
# unwritable targets and its unset or empty HOME.
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
# Resolved with pwd -P because the stub claude reports its directory that
# way, and the pwd= checks compare the two; TMPDIR can sit under a symlink.
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
export XDG_CONFIG_HOME="$SANDBOX/config"
export XDG_STATE_HOME="$SANDBOX/state"
mkdir -p "$HOME"
unset GIT_CONFIG_GLOBAL CLAUDE_CONFIG_DIR
# Keeps git from finding a repo above the sandbox, which would turn the
# outside-a-repo cases into inside-a-repo ones.
export GIT_CEILING_DIRECTORIES="$SANDBOX"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
JQ="$(command -v jq)"

# The stub claude answers `plugin list --json` with $SANDBOX/plugins.json
# and the status in $SANDBOX/list.rc, 0 when absent, writing
# CLAUDE_CONFIG_DIR to $SANDBOX/list.ccd. Any other call is a launch: it
# writes its arguments one per line to $SANDBOX/claude.args, the file each
# --settings names to $SANDBOX/claude.settings, its directory,
# GIT_CONFIG_GLOBAL, CLAUDE_CONFIG_DIR, `unset` when it is, and whether
# ./.git exists to $SANDBOX/claude.env, sends the signal named in $SANDBOX/claude.signal
# to its parent when that file exists, and then to itself -- or, when
# $SANDBOX/claude.survive exists, instead survives it, waits a second and
# appends to claude.env whether ./.git and the --settings file are still
# there -- and exits with the status in $SANDBOX/claude.rc, 0 when absent.
# It names every command by absolute path so it runs on the restricted
# PATHs below.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/claude" <<EOF
#!/bin/sh
if [ "\$*" = "plugin list --json" ]; then
  echo "\${CLAUDE_CONFIG_DIR-unset}" >"$SANDBOX/list.ccd"
  [ ! -f "$SANDBOX/plugins.json" ] || /bin/cat "$SANDBOX/plugins.json"
  exit "\$(/bin/cat "$SANDBOX/list.rc" 2>/dev/null || echo 0)"
fi
: >"$SANDBOX/claude.args"
prev=
settings=
for a in "\$@"; do
  printf '%s\n' "\$a" >>"$SANDBOX/claude.args"
  if [ "\$prev" = --settings ]; then
    /bin/cat "\$a" >>"$SANDBOX/claude.settings"
    settings=\$a
  fi
  prev=\$a
done
{
  echo "pwd=\$(/bin/pwd -P)"
  echo "gcg=\${GIT_CONFIG_GLOBAL-}"
  echo "ccd=\${CLAUDE_CONFIG_DIR-unset}"
  if [ -d .git ]; then echo "git=yes"; else echo "git=no"; fi
} >"$SANDBOX/claude.env"
if [ -f "$SANDBOX/claude.signal" ]; then
  sig=\$(/bin/cat "$SANDBOX/claude.signal")
  kill -"\$sig" "\$PPID"
  if [ -f "$SANDBOX/claude.survive" ]; then
    /bin/sleep 1
    {
      if [ -d .git ]; then echo "after-git=yes"; else echo "after-git=no"; fi
      if [ -f "\$settings" ]; then echo "after-settings=yes"; else echo "after-settings=no"; fi
    } >>"$SANDBOX/claude.env"
  else
    kill -"\$sig" \$\$
  fi
fi
exit "\$(/bin/cat "$SANDBOX/claude.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$SANDBOX/bin/claude"

# The stub gh appends its arguments, one line per call, to
# $SANDBOX/gh.calls, prints the contents of $SANDBOX/gh.url, or when that
# file is absent the https:// URL `repo view` was given, without `.git`,
# or https://github.com/upstream/upstream-repo when it was given none, as
# a real gh can pick a fork's `upstream`; it exits with the status in
# $SANDBOX/gh.rc, 0 when absent.
cat >"$SANDBOX/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$SANDBOX/gh.calls"
case "\$3" in
  https://*) u=\${3%.git} ;;
  *) u=https://github.com/upstream/upstream-repo ;;
esac
if [ -f "$SANDBOX/gh.url" ]; then /bin/cat "$SANDBOX/gh.url"; else echo "\$u"; fi
exit "\$(/bin/cat "$SANDBOX/gh.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$SANDBOX/bin/gh"

# The stub ssh stands in for the machine's ssh configuration: it appends
# its arguments, one line per call, to $SANDBOX/ssh.calls and answers
# `-G -- <host>` as `ssh -G` does, with the `hostname` line among others,
# naming github.com for the alias github-work, ssh.github.com for the
# alias github-443, and <host> itself otherwise; it exits with the status
# in $SANDBOX/ssh.rc, 0 when absent.
cat >"$SANDBOX/bin/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$SANDBOX/ssh.calls"
case "\$3" in
  github-work) h=github.com ;;
  github-443) h=ssh.github.com ;;
  *) h=\$3 ;;
esac
printf 'host %s\nuser git\nhostname %s\nport 22\n' "\$3" "\$h"
exit "\$(/bin/cat "$SANDBOX/ssh.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$SANDBOX/bin/ssh"

# reset -- forget the previous launch.
reset() {
  rm -f "$SANDBOX/claude.args" "$SANDBOX/claude.env" "$SANDBOX/claude.rc" "$SANDBOX/claude.signal" \
    "$SANDBOX/claude.survive" "$SANDBOX/claude.settings" "$SANDBOX/gh.calls" "$SANDBOX/ssh.calls"
}

# run_cr <dir> [<arg>…] -- run bin/cr from <dir> with the stub claude,
# gh and ssh first on PATH; leaves ARGS (claude's arguments, one per
# line), SETTINGS (the content of each --settings file at launch), ENV,
# GH (gh's calls), SSH (ssh's calls), ERR and RC.
run_cr() {
  local dir=$1
  shift
  reset
  (cd "$dir" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" "$@") >/dev/null 2>"$SANDBOX/stderr"
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
  ARGS=$(cat "$SANDBOX/claude.args" 2>/dev/null)
  SETTINGS=$(cat "$SANDBOX/claude.settings" 2>/dev/null)
  ENV=$(cat "$SANDBOX/claude.env" 2>/dev/null)
  GH=$(cat "$SANDBOX/gh.calls" 2>/dev/null)
  SSH=$(cat "$SANDBOX/ssh.calls" 2>/dev/null)
}

# settings_arg -- the argument after --settings in claude.args.
settings_arg() {
  sed -n '/^--settings$/{n;p;}' "$SANDBOX/claude.args"
}

# state_files -- every file under XDG_STATE_HOME, one per line.
state_files() {
  find "$XDG_STATE_HOME" -type f 2>/dev/null
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
# A repo with no origin.
LOCAL="$SANDBOX/local"
git init -q "$LOCAL"

run_cr "$REPO/sub" fix the bug --model opus "two words"
check "$RC" "0" "repo: exit 0"
check "$ARGS" "$(lines --name "fix the bug my-repo" --remote-control \
  --debug-file "$HOME/.claude/logs/fix the bug my-repo" --allowedTools Grep Glob --model opus "two words")" \
  "repo: name words before the first flag, the rest passed unchanged, no --settings without a settings layer"
check_contains "$ENV" "pwd=$REPO
" "repo: claude runs from the repo root"
check_contains "$ERR" "cr: detected existing git repo; cd to repo root $REPO" "repo: stderr names the root"
check_contains "$ENV" "git=yes" "repo: the repo's own .git is there"
check "$([ -d "$REPO/.git" ] && echo kept)" "kept" "repo: the existing .git is left alone"

# With no settings layer, the arguments cr adds itself fill the first
# eight lines of claude.args, so line 9 onward is what passed through.
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

run_cr "$REPO" x
check "$GH" "repo view https://github.com/owner/my-repo.git --json url --jq .url" \
  "repo: the identity comes from gh repo view of origin's URL in its https:// form"
check "$(state_files)" "" "no layer: no merged file is written"

# Each form an origin can take reaches gh as the same https:// URL.
for form in git@github.com:owner/my-repo.git org-1@github.com:owner/my-repo.git github.com:owner/my-repo.git \
  ssh://git@github.com/owner/my-repo.git ssh://git@github.com:22/owner/my-repo.git \
  git+ssh://git@github.com/owner/my-repo.git ssh+git://git@github.com/owner/my-repo.git \
  https://user@github.com/owner/my-repo.git; do
  git -C "$REPO" remote set-url origin "$form"
  run_cr "$REPO" x
  check "$GH" "repo view https://github.com/owner/my-repo.git --json url --jq .url" "origin $form: gh is given its https:// form"
done

# An ssh origin's host is the one ssh resolves: an alias names its real
# host, and ssh.github.com names github.com.
for form in git@github-work:owner/my-repo.git ssh://git@github-work:22/owner/my-repo.git \
  git+ssh://git@github-work/owner/my-repo.git ssh+git://git@github-work/owner/my-repo.git \
  git@github-443:owner/my-repo.git; do
  git -C "$REPO" remote set-url origin "$form"
  run_cr "$REPO" x
  check "$GH" "repo view https://github.com/owner/my-repo.git --json url --jq .url" \
    "ssh alias origin $form: gh is given the real host's https:// URL"
done
check "$SSH" "-G -- github-443" "ssh alias origin: ssh -G is asked about the origin's host alone"

git -C "$REPO" remote set-url origin https://github-work/owner/my-repo.git
run_cr "$REPO" x
check "$SSH:$GH" ":repo view https://github-work/owner/my-repo.git --json url --jq .url" \
  "https origin: no ssh call, and its host is left as it is"

git -C "$REPO" remote set-url origin git@github-work:owner/my-repo.git
echo 255 >"$SANDBOX/ssh.rc"
run_cr "$REPO" x
check "$GH" "repo view https://github-work/owner/my-repo.git --json url --jq .url" \
  "ssh -G fails: the origin's host is left as it is"
rm "$SANDBOX/ssh.rc"
git -C "$REPO" remote set-url origin git@github.com:owner/my-repo.git

# --- bin/cr: the settings layers --------------------------------------------
CFG="$XDG_CONFIG_HOME/cc-tools/cr-settings"
HOST_L="$CFG/host.json"
OWNER_L="$CFG/github.com/owner.json"
MACHINE_L="$CFG/github.com/owner/my-repo.json"
COMMITTED_L="$REPO/.cc-tools/cr-settings.json"
mkdir -p "$CFG/github.com/owner" "$REPO/.cc-tools"

# write_layers -- one file per layer. Each appends its name to `order`
# and sets `model`; the `permissions.allow` entries repeat across layers,
# and `env` gets a key from each of two layers.
write_layers() {
  echo '{"order": ["host"], "model": "host", "permissions": {"allow": ["a", "shared"]}, "env": {"A": "1"}}' >"$HOST_L"
  echo '{"order": ["owner"], "model": "owner", "permissions": {"allow": ["owner", "shared"]}, "env": {"B": "2"}}' >"$OWNER_L"
  echo '{"order": ["machine"], "model": "machine", "permissions": {"allow": ["machine"]}}' >"$MACHINE_L"
  echo '{"order": ["committed"], "model": "committed", "permissions": {"allow": ["committed", "a"]}}' >"$COMMITTED_L"
}

# merged <jq-filter> -- the filter applied to what claude's --settings
# file held at launch, compact.
merged() {
  printf '%s' "$SETTINGS" | "$JQ" -c "$1"
}

write_layers
run_cr "$REPO/sub" x --model opus
MERGED=$(settings_arg)
check "$RC" "0" "layers: exit 0"
check "$(merged .order)" '["host","owner","machine","committed"]' \
  "layers: applied in the order host, owner, repo per machine, repo committed"
check "$(merged .permissions.allow)" '["a","shared","owner","machine","committed"]' \
  "layers: a list concatenates in layer order, and an entry equal to an earlier one is dropped"
check "$(merged .env)" '{"A":"1","B":"2"}' "layers: an object merges key by key"
check "$(merged .model)" '"committed"' "layers: a later scalar overrides an earlier one"
check "$(grep -c '^--settings$' "$SANDBOX/claude.args")" "1" "layers: claude receives exactly one --settings"
check "$ARGS" "$(lines --name "x my-repo" --remote-control --debug-file "$HOME/.claude/logs/x my-repo" \
  --settings "$MERGED" --allowedTools Grep Glob --model opus)" \
  "layers: cr's --settings precedes the pass-through arguments"
MERGED_DIR="$XDG_STATE_HOME/cc-tools/github.com/owner/my-repo"
case "$MERGED" in
  "$MERGED_DIR"/cr-settings-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*.json) AT=ok ;;
  *) AT="$MERGED" ;;
esac
check "$AT" "ok" "layers: the merged file is <state>/cc-tools/<host>/<owner>/<repo>/cr-settings-<stamp>-<pid>.json"
check "$([ -e "$MERGED" ] && echo left)" "" "layers: the merged file is removed on exit"

# A fork: gh asked with no repository would resolve `upstream`, so these
# pass only when cr names origin's URL.
git -C "$REPO" remote add upstream git@github.com:upstream/upstream-repo.git
run_cr "$REPO" x
check "$RC:$(merged .order)" '0:["host","owner","machine","committed"]' \
  "fork with an upstream remote: origin's owner and repo layers apply"
check "$(dirname "$(settings_arg)")" "$MERGED_DIR" "fork with an upstream remote: the merged file is under origin's owner and repo"
git -C "$REPO" remote remove upstream

# An ssh config alias: the layers are its real host's, not the local ones.
git -C "$REPO" remote set-url origin git@github-work:owner/my-repo.git
run_cr "$REPO" x
check "$RC:$(merged .order)" '0:["host","owner","machine","committed"]' \
  "ssh alias origin: the real host's owner and repo layers apply"
check "$(dirname "$(settings_arg)")" "$MERGED_DIR" "ssh alias origin: the merged file is under the real host's owner and repo"
git -C "$REPO" remote set-url origin git@github.com:owner/my-repo.git

# Negative control: the same launch with the layers moved aside must lose
# them, so the checks above are measuring the layers.
mv "$CFG" "$CFG.aside"
rm "$COMMITTED_L"
run_cr "$REPO" x
check_lacks "$ARGS" "--settings" "negative control: with no layer present, claude receives no --settings"
check "$SETTINGS" "" "negative control: nothing reaches claude's settings"
mv "$CFG.aside" "$CFG"
write_layers

mkdir -p "$REPO/sub/.cc-tools"
mv "$COMMITTED_L" "$REPO/sub/.cc-tools/cr-settings.json"
run_cr "$REPO/sub" x
check "$(merged .order)" '["host","owner","machine"]' "committed layer below the root only: ignored"
mv "$REPO/sub/.cc-tools/cr-settings.json" "$COMMITTED_L"
rm -r "$REPO/sub/.cc-tools"

# gh repo view fails: the local identity, host and committed layers only.
echo 1 >"$SANDBOX/gh.rc"
run_cr "$REPO" x
check "$RC:$(merged .order)" '0:["host","committed"]' "gh repo view fails: only the host and committed layers apply"
check "$(dirname "$(settings_arg)")" "$XDG_STATE_HOME/cc-tools/local" "gh repo view fails: the merged file is under local/"
rm "$SANDBOX/gh.rc"

# --- bin/cr: refusals -------------------------------------------------------
# no_claude -- empty when claude did not run.
no_claude() {
  [ ! -f "$SANDBOX/claude.args" ] || echo ran
}

echo '{"order": [' >"$OWNER_L"
run_cr "$REPO" x
check "$RC:$(no_claude)" "1:" "a layer that is not valid JSON: exit 1, claude does not run"
check_contains "$ERR" "cr: $OWNER_L is not valid JSON" "a layer that is not valid JSON: stderr names the file"
write_layers

echo '{"permissions": {"allow": {"x": 1}}}' >"$MACHINE_L"
run_cr "$REPO" x
check "$RC:$(no_claude)" "1:" "a key's type differs between layers: exit 1, claude does not run"
check_contains "$ERR" "cr: permissions.allow differs in type between layers: list in $HOST_L, list in $OWNER_L, object in $MACHINE_L, list in $COMMITTED_L" \
  "a key's type differs between layers: stderr names the key and the layers"
check "$(state_files)" "" "a refusal writes no merged file"
write_layers

# Each bad URL with the segment cr refuses in it, after a `|`.
for case in "https://github.com/owner/..|.." "https://github.com/own%20er/my-repo|own%20er" \
  "https://github.com/owner/my-repo/extra|my-repo/extra"; do
  bad=${case%|*}
  segment=${case#*|}
  echo "$bad" >"$SANDBOX/gh.url"
  run_cr "$REPO" x
  check "$RC:$(no_claude)" "1:" "segment check ($bad): exit 1, claude does not run"
  check_contains "$ERR" "cr: '$segment' in $bad is not a valid host, owner or repo name" \
    "segment check ($bad): stderr names the segment"
done
rm "$SANDBOX/gh.url"

# PATHs holding every tool cr runs but one; the stubs stand in for claude
# and gh.
for tool in git gh jq; do
  d="$SANDBOX/no-$tool"
  mkdir -p "$d"
  for t in claude gh; do ln -s "$SANDBOX/bin/$t" "$d/$t"; done
  for t in git jq date mkdir rm; do ln -s "$(command -v "$t")" "$d/$t"; done
  mv "$d/$tool" "$SANDBOX/aside-$tool"
  reset
  (cd "$REPO" && PATH="$d" /bin/bash "$CR" x) >/dev/null 2>"$SANDBOX/stderr"
  check "$?:$(no_claude)" "1:" "$tool not on PATH: exit 1, claude does not run"
  check "$(cat "$SANDBOX/stderr")" "cr: $tool is not on PATH" "$tool not on PATH: stderr names it"
  mv "$SANDBOX/aside-$tool" "$d/$tool"
done
# The same PATH with the tool put back launches claude, so the refusals
# above are the missing tool's and not the restricted PATH's.
reset
(cd "$REPO" && PATH="$SANDBOX/no-jq" /bin/bash "$CR" x) >/dev/null 2>&1
check "$?:$(no_claude)" "0:ran" "every tool on a restricted PATH: claude runs"

rm -r "$CFG" "$REPO/.cc-tools"

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

reset
(cd "$REPO" && GIT_CONFIG_GLOBAL='' PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" x) >/dev/null 2>&1
check_contains "$(cat "$SANDBOX/claude.env")" "gcg=$HOME/.gitconfig-claude" \
  "GIT_CONFIG_GLOBAL empty, a readable .gitconfig-claude: exported as when unset"
rm "$HOME/.gitconfig-claude"

reset
(cd "$REPO" && GIT_CONFIG_GLOBAL='' PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" x) >/dev/null 2>&1
check_contains "$(cat "$SANDBOX/claude.env")" "gcg=
" "GIT_CONFIG_GLOBAL empty, no .gitconfig-claude: stays empty"

# --- bin/cr: --as and the config directory ----------------------------------
ACCOUNT="$HOME/.claude.work_1-a"
mkdir "$ACCOUNT" "$HOME/elsewhere" "$HOME/.claude.backup" "$HOME/.claude.a.b"
ln -s "$HOME/elsewhere" "$HOME/.claude.linked"
ln -s "$HOME/nowhere" "$HOME/.claude.dangling"
echo '{}' >"$HOME/.claude.json"

rm -rf "$HOME/.claude"
run_cr "$REPO" x
check_contains "$ENV" "ccd=unset
" "no --as: CLAUDE_CONFIG_DIR stays unset"
check "$([ -d "$HOME/.claude/logs" ] && echo there)" "there" "no --as: ~/.claude/logs is created"

for flags in "--as work_1-a" "--as work_1-a --cr-strict" "--cr-strict --as work_1-a"; do
  read -ra words <<<"$flags"
  run_cr "$REPO" "${words[@]}" fix it --model opus
  check "$RC:$ARGS" "0:$(lines --name "fix it my-repo" --remote-control \
    --debug-file "$ACCOUNT/logs/fix it my-repo" --allowedTools Grep Glob --model opus)" \
    "$flags: the name words follow it, and the debug log is the account's"
  check_contains "$ENV" "ccd=$ACCOUNT
" "$flags: claude runs with CLAUDE_CONFIG_DIR set to the account's directory"
done
check "$([ -d "$ACCOUNT/logs" ] && echo there)" "there" "--as: the account's logs directory is created"

run_cr "$LOCAL" --cr-strict --as work_1-a x
check "$RC:$ERR" "1:cr: --cr-strict: this git repo has no 'origin' remote" "--cr-strict --as: both apply"
run_cr "$LOCAL" --as work_1-a --cr-strict x
check "$RC:$ERR" "1:cr: --cr-strict: this git repo has no 'origin' remote" "--as --cr-strict: both apply"

run_cr "$REPO" --as linked x
check_contains "$RC:$ENV" "ccd=$HOME/.claude.linked
" "--as, a symlink to a directory: accepted as the account directory"

run_cr "$REPO" foo --as x
check "$RC:$(sed -n '9,$p' "$SANDBOX/claude.args")" "0:$(lines --as x)" "--as after a name word: passed to claude"
check_contains "$ENV" "ccd=unset
" "--as after a name word: CLAUDE_CONFIG_DIR stays unset"
run_cr "$REPO" foo --as=x
check "$(sed -n '9,$p' "$SANDBOX/claude.args")" "--as=x" "--as=<name> after a name word: passed to claude"

CLAUDE_CONFIG_DIR="$HOME/inherited" run_cr "$REPO" x
check_contains "$ENV" "ccd=$HOME/inherited
" "no --as, inherited CLAUDE_CONFIG_DIR: left as it is"
check "$([ -d "$HOME/inherited/logs" ] && sed -n 5p "$SANDBOX/claude.args")" "$HOME/inherited/logs/x my-repo" \
  "no --as, inherited CLAUDE_CONFIG_DIR: the debug log is under its logs/"
CLAUDE_CONFIG_DIR="$HOME/inherited" run_cr "$REPO" --as work_1-a x
check_contains "$ENV" "ccd=$ACCOUNT
" "--as over an inherited CLAUDE_CONFIG_DIR: the account's directory"
CLAUDE_CONFIG_DIR='' run_cr "$REPO" x
check "$(sed -n 5p "$SANDBOX/claude.args")" "$HOME/.claude/logs/x my-repo" "empty CLAUDE_CONFIG_DIR: the debug log is under ~/.claude/logs"
check_contains "$ENV" "ccd=
" "empty CLAUDE_CONFIG_DIR: left as it is"

echo "a file" >"$HOME/notdir"
CLAUDE_CONFIG_DIR="$HOME/notdir" run_cr "$REPO" x
check "$RC:$(no_claude)" "1:" "logs/ cannot be created: exit 1, claude does not run"
check_contains "$ERR" "cr: cannot create $HOME/notdir/logs" "logs/ cannot be created: stderr names it"

# bad_as <label> <message> <run> <arg>… -- <run>, the function that runs cr
# or the resolver, refuses the arguments with exit 1 and the message, and
# neither claude, its plugin list nor the enabled install's bin/cr runs.
bad_as() {
  local label=$1 message=$2
  shift 2
  "$@"
  check "$RC:$ERR:$(no_claude)$([ -e "$SANDBOX/list.ccd" ] && echo asked)$([ -e "$SANDBOX/enabled.args" ] && echo ran)" \
    "1:cr: $message:" "$label: exit 1 with a message, nothing runs"
}

# bad_as_cases <label> <run> <arg> -- every refusal of --as, by the function
# <run> given <arg> first.
bad_as_cases() {
  local label=$1 run=$2 arg=$3 bad
  bad_as "$label, no name" "--as needs an account name" "$run" "$arg" --as
  for bad in "" backup a.b "a/b" "a b" "é" backup.20260101_000000; do
    bad_as "$label, invalid name '$bad'" "--as: '$bad' is not a valid account name" "$run" "$arg" --as "$bad" x
  done
  for bad in none json dangling --model; do
    bad_as "$label, no directory for '$bad'" "--as: no account directory $HOME/.claude.$bad" "$run" "$arg" --as "$bad" x
  done
  bad_as "$label, twice" "--as is given twice" "$run" "$arg" --as work_1-a --cr-strict --as linked x
  bad_as "$label, =<name>" "spell the account as '--as <name>', not '--as=work_1-a'" "$run" "$arg" --as=work_1-a x
  bad_as "$label, =<name> after --cr-strict" "spell the account as '--as <name>', not '--as=work_1-a'" \
    "$run" "$arg" --cr-strict --as=work_1-a x
}
bad_as_cases "cr --as" run_cr "$REPO"

ERR=$(cd "$REPO" && env -u HOME PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" --as work_1-a x 2>&1)
check "$?:$ERR" "1:cr: --as: HOME is not set" "cr --as, HOME unset: exit 1 with a message"

# The account layer sits between the host and owner layers.
mkdir -p "$CFG/accounts" "$CFG/github.com/owner" "$REPO/.cc-tools"
write_layers
echo '{"order": ["account"], "model": "account", "fromAccount": "account"}' >"$CFG/accounts/work_1-a.json"
echo '{"order": ["other"]}' >"$CFG/accounts/linked.json"
run_cr "$REPO" --as work_1-a x
check "$(merged .order)" '["host","account","owner","machine","committed"]' \
  "--as: the account layer comes after the host layer and before the owner layer"
check "$(merged .fromAccount)" '"account"' "--as: the account layer reaches claude"
rm "$OWNER_L" "$MACHINE_L" "$COMMITTED_L"
run_cr "$REPO" --as work_1-a x
check "$(merged .model)" '"account"' "--as: the account layer overrides the host layer"
echo '{"model": "owner"}' >"$OWNER_L"
run_cr "$REPO" --as work_1-a x
check "$(merged .model)" '"owner"' "--as: the owner layer overrides the account layer"
run_cr "$REPO" x
check "$(merged .order)" '["host"]' "no --as: no account layer"
CLAUDE_CONFIG_DIR="$ACCOUNT" run_cr "$REPO" x
check "$(merged .order)" '["host"]' "no --as, inherited CLAUDE_CONFIG_DIR: no account layer"
run_cr "$LOCAL" --as work_1-a x
check "$(merged .order)" '["host","account"]' "--as, no origin: the account layer applies"
rm -r "$CFG" "$REPO/.cc-tools"

# --- bin/cr: exit status ----------------------------------------------------
reset
echo 7 >"$SANDBOX/claude.rc"
(cd "$REPO" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" x) >/dev/null 2>&1
check "$?" "7" "claude's exit status is cr's"

# --- bin/cr: a repo with no origin ------------------------------------------
run_cr "$LOCAL" x
check "$(sed -n 2p "$SANDBOX/claude.args")" "x (local)" "no origin: the repo is named (local)"

# local_layers <dir> -- all four layer files, the committed one in <dir>.
# Under the local identity only host and committed may reach claude.
local_layers() {
  mkdir -p "$CFG/github.com/owner" "$1/.cc-tools"
  echo '{"order": ["host"]}' >"$HOST_L"
  echo '{"order": ["owner"]}' >"$OWNER_L"
  echo '{"order": ["machine"]}' >"$MACHINE_L"
  echo '{"order": ["committed"]}' >"$1/.cc-tools/cr-settings.json"
}

local_layers "$LOCAL"
run_cr "$LOCAL" x
check "$RC:$(merged .order)" '0:["host","committed"]' "no origin: only the host and committed layers apply"
check "$GH" "" "no origin: no gh call"
check "$(dirname "$(settings_arg)")" "$XDG_STATE_HOME/cc-tools/local" "no origin: the merged file is under local/"
rm -r "$CFG" "$LOCAL/.cc-tools"

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

local_layers "$PLAIN"
run_cr "$PLAIN" x
check "$RC:$(merged .order)" '0:["host","committed"]' "git init directory: only the host and committed layers apply"
check "$GH" "" "git init directory: no gh call"
check "$(dirname "$(settings_arg)")" "$XDG_STATE_HOME/cc-tools/local" "git init directory: the merged file is under local/"

for sig in INT TERM; do
  reset
  echo "$sig" >"$SANDBOX/claude.signal"
  (cd "$PLAIN" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" x) >/dev/null 2>&1
  RC=$?
  check "$(grep -c git=yes "$SANDBOX/claude.env"):$([ -e "$PLAIN/.git" ] && echo left)" "1:" \
    "outside a repo, $sig: the .git is removed"
  SIG_MERGED=$(settings_arg)
  check "$(dirname "$SIG_MERGED"):$([ -e "$SIG_MERGED" ] && echo left)" "$XDG_STATE_HOME/cc-tools/local:" \
    "outside a repo, $sig: the merged file claude received is removed"
  check "$([ "$RC" -ne 0 ] && echo nonzero)" "nonzero" "outside a repo, $sig: cr exits non-zero"
done

# A signal claude survives: cr leaves the files in place until claude
# returns, then removes them and exits with claude's status.
for sig in INT TERM; do
  reset
  echo "$sig" >"$SANDBOX/claude.signal"
  : >"$SANDBOX/claude.survive"
  echo 7 >"$SANDBOX/claude.rc"
  (cd "$PLAIN" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$CR" x) >/dev/null 2>&1
  RC=$?
  check "$RC" "7" "$sig that claude survives: cr exits with claude's status"
  check_contains "$(cat "$SANDBOX/claude.env")" "after-git=yes
after-settings=yes" "$sig that claude survives: the .git and the merged file stay while claude runs"
  SIG_MERGED=$(settings_arg)
  check "$([ -e "$PLAIN/.git" ] && echo git):$([ -e "$SIG_MERGED" ] && echo settings)" ":" \
    "$sig that claude survives: the .git and the merged file are removed once claude returns"
done
rm -r "$CFG" "$PLAIN/.cc-tools"

# --- hooks/cr-resolver ------------------------------------------------------
# Two fake installs: the enabled one and a disabled one listed first. Each
# fake bin/cr records its arguments in a file of its own, and
# CLAUDE_CONFIG_DIR, `unset` when it is, in another.
for v in enabled disabled; do
  mkdir -p "$SANDBOX/install/$v/bin"
  cat >"$SANDBOX/install/$v/bin/cr" <<EOF
#!/bin/sh
: >"$SANDBOX/$v.args"
echo "\${CLAUDE_CONFIG_DIR-unset}" >"$SANDBOX/$v.ccd"
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
  rm -f "$SANDBOX/enabled.args" "$SANDBOX/enabled.ccd" "$SANDBOX/disabled.args" "$SANDBOX/list.ccd"
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
check "$(cat "$SANDBOX/list.ccd"):$(cat "$SANDBOX/enabled.ccd")" "unset:unset" "resolver, no --as: CLAUDE_CONFIG_DIR stays unset"

run_resolver "$SANDBOX/withjq" --cr-strict --as work_1-a "b c" --model opus
check "$(cat "$SANDBOX/list.ccd"):$(cat "$SANDBOX/enabled.ccd")" "$ACCOUNT:$ACCOUNT" \
  "resolver --as: the plugin list and bin/cr both run with CLAUDE_CONFIG_DIR set to the account's directory"
check "$(cat "$SANDBOX/enabled.args")" "$(lines --cr-strict --as work_1-a "b c" --model opus)" \
  "resolver --as: the arguments reach bin/cr unchanged, --as included"

run_resolver "$SANDBOX/withjq" --as linked --cr-strict x
check "$(cat "$SANDBOX/list.ccd"):$(lines "$(cat "$SANDBOX/enabled.args")")" \
  "$HOME/.claude.linked:$(lines --as linked --cr-strict x)" "resolver --as, a symlink to a directory: accepted"

run_resolver "$SANDBOX/withjq" foo --as x
check "$(cat "$SANDBOX/list.ccd"):$(cat "$SANDBOX/enabled.args")" "unset:$(lines foo --as x)" \
  "resolver, --as after a name word: passed on, CLAUDE_CONFIG_DIR stays unset"

CLAUDE_CONFIG_DIR="$HOME/inherited" run_resolver "$SANDBOX/withjq" x
check "$(cat "$SANDBOX/list.ccd")" "$HOME/inherited" "resolver, no --as, inherited CLAUDE_CONFIG_DIR: left as it is"

bad_as_cases "resolver --as" run_resolver "$SANDBOX/withjq"

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

# The exec fails three ways, each 126 under bash 3.2: the install has no
# bin/cr, the install directory is gone, and bin/cr is not executable.
mkdir -p "$SANDBOX/install/nocr/bin" "$SANDBOX/install/noexec/bin"
cp "$SANDBOX/install/enabled/bin/cr" "$SANDBOX/install/noexec/bin/cr"
chmod -x "$SANDBOX/install/noexec/bin/cr"
for v in nocr gone noexec; do
  echo "[$(entry cc-tools@thevoskamps true "$SANDBOX/install/$v")]" >"$SANDBOX/plugins.json"
  run_resolver "$SANDBOX/withjq" a
  check "$RC:$([ -f "$SANDBOX/enabled.args" ] && echo ran)" "126:" "resolver, exec fails ($v): exit 126, nothing runs"
done

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
