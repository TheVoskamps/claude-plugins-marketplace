#!/usr/bin/env bash
#
# cr-account-links-test.sh -- drive plugins/cc-tools/bin/cr-account-links
# under the bash 3.2 macOS ships, with HOME pointed at a scratch directory:
# what list reports, what add creates, keeps and refuses, what remove
# removes and leaves, and the refusals over arguments, the whitelist and yq.
#
# Needs mikefarah yq v4 or higher on PATH.
#
# Usage: cr-account-links-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINKS="$TEST_DIR/../bin/cr-account-links"
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cr-account-links-test.XXXXXX")" && pwd -P)"
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

export HOME="$SANDBOX/home"
CLAUDE="$HOME/.claude"
WHITELIST="$CLAUDE/.cc-tools/account-symlinks.yml"
WORK="$HOME/.claude.work"
# The whitelist is $HOME/.claude's whatever this holds.
export CLAUDE_CONFIG_DIR="$SANDBOX/decoy"

# whitelist <name>… -- write a whitelist naming the arguments.
whitelist() {
  local n
  {
    echo "schema-version: 1"
    echo "symlinks:"
    for n in "$@"; do echo "  - $n"; done
  } >"$WHITELIST"
}

# fresh -- a new home whose whitelist names CLAUDE.md, rules and skills,
# each present in ~/.claude, with no account.
fresh() {
  rm -rf "$HOME"
  mkdir -p "$CLAUDE/.cc-tools" "$CLAUDE/rules" "$CLAUDE/skills" "$CLAUDE/extra"
  echo text >"$CLAUDE/CLAUDE.md"
  whitelist CLAUDE.md rules skills
}

# run <arg>… -- run the script; leaves OUT, ERR and RC.
run() {
  OUT=$(/bin/bash "$LINKS" "$@" 2>"$SANDBOX/stderr")
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
}

# tree -- every path under the home but ~/.claude's own, with each
# symlink's target and each file's content, to compare before and after.
tree() {
  (cd "$HOME" && find . -path ./.claude -prune -o -print | sort | while IFS= read -r p; do
    if [ -L "$p" ]; then
      echo "$p -> $(readlink "$p")"
    elif [ -f "$p" ]; then
      echo "$p: $(cat "$p")"
    else
      echo "$p"
    fi
  done)
}

# row <state> <entry> -- one report line as the script prints it.
row() {
  printf '  %-15s  %s' "$1" "$2"
}

check "$([ -x "$LINKS" ] && echo yes)" "yes" "bin/cr-account-links is executable"

# --- arguments --------------------------------------------------------------
fresh
USAGE="1::cr-account-links: usage: cr-account-links list | add <name> | remove <name>"
for args in "" "bogus" "list x" "add" "remove" "add a b" "remove a b"; do
  read -ra words <<<"$args"
  run ${words[@]+"${words[@]}"}
  check "$RC:$OUT:$ERR" "$USAGE" "arguments '$args': refused with the usage"
done
for mode in add remove; do
  for bad in "" backup a.b a/b "a b" .. "é"; do
    before=$(tree)
    run "$mode" "$bad"
    check "$RC:$ERR" "1:cr-account-links: '$bad' is not a valid account name" "$mode '$bad': refused"
    check "$(tree)" "$before" "$mode '$bad': nothing changed"
  done
done

# --- add --------------------------------------------------------------------
run add work
check "$RC:$ERR" "0:" "add, new account: exit 0"
check "$OUT" "work  $WORK
$(row created CLAUDE.md)
$(row created rules)
$(row created skills)" "add, new account: each link reported created"
for e in CLAUDE.md rules skills; do
  check "$(readlink "$WORK/$e")" "$CLAUDE/$e" "add, new account: $e links to the same name under ~/.claude"
done
check "$([ -e "$WORK/extra" ] && echo there)$([ -e "$CLAUDE_CONFIG_DIR" ] && echo decoy)" "" \
  "add: nothing unlisted is linked, and CLAUDE_CONFIG_DIR is not touched"

before=$(tree)
run add work
check "$RC:$OUT" "0:work  $WORK
$(row linked CLAUDE.md)
$(row linked rules)
$(row linked skills)" "add again: each link reported linked"
check "$(tree)" "$before" "add again: nothing changed"

fresh
mkdir -p "$WORK/rules"
echo mine >"$WORK/CLAUDE.md"
echo mine >"$WORK/rules/r"
run add work
check "$RC:$OUT" "0:work  $WORK
$(row kept "CLAUDE.md (real file)")
$(row kept "rules (real directory)")
$(row created skills)" "add over a real file and directory: kept and reported, the missing link created"
check "$(cat "$WORK/CLAUDE.md" "$WORK/rules/r")" "mine
mine" "add over a real file and directory: their content stands"

# refused_add <label> <message>… -- add work exits 1 with each message on
# stderr, and changes nothing.
refused_add() {
  local label=$1 before message
  shift
  before=$(tree)
  run add work
  check "$RC:$OUT" "1:" "$label: exit 1"
  for message in "$@"; do
    check_contains "$ERR" "cr-account-links: $message" "$label: stderr says '$message'"
  done
  check "$(tree)" "$before" "$label: nothing changed"
}

fresh
mkdir "$WORK"
ln -s "$CLAUDE/extra" "$WORK/skills"
refused_add "add, wrong target" "$WORK/skills is a symlink to $CLAUDE/extra (wrong target)" "nothing was changed"

fresh
mkdir "$WORK"
ln -s "$CLAUDE/gone" "$WORK/skills"
refused_add "add, dangling link" "$WORK/skills is a symlink to $CLAUDE/gone (dangling)"

fresh
rm -r "$CLAUDE/skills"
refused_add "add, missing source, no account" "$CLAUDE/skills does not exist" "nothing was changed"
check "$([ -e "$WORK" ] && echo there)" "" "add, missing source: the account directory is not created"
mkdir "$WORK"
ln -s "$CLAUDE/skills" "$WORK/skills"
refused_add "add, link whose source is gone" "$WORK/skills is a symlink to $CLAUDE/skills (dangling)"

fresh
echo text >"$HOME/.claude.work"
refused_add "add, a plain file in the account's place" "$WORK exists and is not a directory"
fresh
ln -s "$HOME/nowhere" "$WORK"
refused_add "add, a dangling symlink in the account's place" "$WORK exists and is not a directory"

fresh
mkdir -p "$HOME/deep/er"
ln -s "$HOME/deep/er" "$WORK"
run add work
check "$RC:$(readlink "$HOME/deep/er/skills")" "0:$CLAUDE/skills" "add, the account directory is a symlink: links created in it"

# A relative link to the same name is right wherever the account is.
fresh
mkdir "$WORK"
ln -s ../.claude/skills "$WORK/skills"
ln -s "$CLAUDE/rules/" "$WORK/rules"
run add work
check "$RC:$OUT" "0:work  $WORK
$(row created CLAUDE.md)
$(row linked rules)
$(row linked skills)" "add: a relative target and a trailing slash each count as linked"

# A whitelist entry more is a link more.
whitelist CLAUDE.md rules skills extra extra
run add work
check "$RC:$(readlink "$WORK/extra")" "0:$CLAUDE/extra" "add, a name added to the whitelist: linked, once though listed twice"
echo "symlinks: []
schema-version: 7" >"$WHITELIST"
run add empty
check "$RC:$OUT:$([ -d "$HOME/.claude.empty" ] && ls -A "$HOME/.claude.empty")" "0:empty  $HOME/.claude.empty:" \
  "add, an empty whitelist of a higher schema-version: an empty account"

# --- list -------------------------------------------------------------------
fresh
run list
check "$RC:$OUT" "0:no accounts" "list: no accounts"

mkdir "$WORK" "$HOME/.claude.backup" "$HOME/.claude.backup.20260101_000000" "$HOME/.claude.backup.20260101_000000.2" "$HOME/elsewhere"
echo '{}' >"$HOME/.claude.json"
ln -s "$HOME/elsewhere" "$HOME/.claude.linked"
whitelist CLAUDE.md rules skills docs plugins settings.json
mkdir "$CLAUDE/docs" "$CLAUDE/plugins"
echo '{}' >"$CLAUDE/settings.json"
ln -s "$CLAUDE/CLAUDE.md" "$WORK/CLAUDE.md"
ln -s "$CLAUDE/extra" "$WORK/rules"
ln -s "$CLAUDE/gone" "$WORK/skills"
mkdir "$WORK/docs"
echo mine >"$WORK/settings.json"
ln -s "$CLAUDE/extra" "$WORK/extra"
ln -s "$CLAUDE/gone/deep" "$WORK/.hidden"
ln -s "$HOME/elsewhere" "$WORK/outside"
before=$(tree)
run list
check "$RC:$ERR:$OUT" "0::linked  $HOME/.claude.linked
$(row missing CLAUDE.md)
$(row missing rules)
$(row missing skills)
$(row missing docs)
$(row missing plugins)
$(row missing settings.json)
work  $WORK
$(row linked CLAUDE.md)
$(row "wrong target" "rules -> $CLAUDE/extra")
$(row dangling "skills -> $CLAUDE/gone")
$(row "real directory" docs)
$(row missing plugins)
$(row "real file" settings.json)
$(row "not whitelisted" ".hidden -> $CLAUDE/gone/deep")
$(row "not whitelisted" "extra -> $CLAUDE/extra")" \
  "list: every state, unlisted links into ~/.claude, no backup directory, no plain file"
check "$(tree)" "$before" "list: nothing changed"

whitelist extra
run list
check_contains "$OUT" "$(row linked extra)" "list, a name added to the whitelist: covered"

# --- remove -----------------------------------------------------------------
whitelist CLAUDE.md rules
before=$(tree)
run remove work
check "$RC:$OUT" "0:work  $WORK
$(row removed CLAUDE.md)
$(row removed extra)" "remove: each same-name link reported, whitelisted or not"
check "$(tree)" "$(printf '%s\n' "$before" | grep -v -e '^./.claude.work/CLAUDE.md ' -e '^./.claude.work/extra ')" \
  "remove: the directory and everything else stay"
run remove work
check "$RC:$OUT" "0:work  $WORK" "remove again: nothing to remove"

fresh
run add work
rm -r "$CLAUDE/skills"
run remove work
check "$RC:$([ -L "$WORK/skills" ] && echo left)" "0:" "remove: a same-name link whose source is gone is removed"
run remove none
check "$RC:$ERR" "1:cr-account-links: no account directory $HOME/.claude.none" "remove, no such account: refused"

# --- the whitelist ----------------------------------------------------------
# refused_whitelist <label> <message> -- every mode exits 1 with the
# message, which names the whitelist, and changes nothing.
refused_whitelist() {
  local mode before
  before=$(tree)
  for mode in list "add work" "add other" "remove work"; do
    read -ra words <<<"$mode"
    run "${words[@]}"
    check "$RC:$OUT:$ERR" "1::cr-account-links: $2" "$1, $mode: exit 1 naming the whitelist"
  done
  check "$(tree)" "$before" "$1: nothing changed"
}

fresh
run add work
rm "$WORK/rules"
rm "$WHITELIST"
refused_whitelist "whitelist absent" "no whitelist at $WHITELIST"
mkdir "$WHITELIST"
refused_whitelist "whitelist a directory" "no whitelist at $WHITELIST"
rmdir "$WHITELIST"

# Each malformed whitelist, as printf's %b takes it.
for text in '' 'schema-version: [1\n' '- rules\n' 'text\n' 'schema-version: 1\n' 'schema-version: 1\nsymlinks: rules\n' \
  'schema-version: 1\nsymlinks: {rules: 1}\n' 'schema-version: 1\nsymlinks: [rules, 42]\n' \
  'schema-version: 1\nsymlinks: [[rules]]\n' 'schema-version: 1\nsymlinks: [~]\n' \
  'schema-version: one\nsymlinks: [rules]\n' 'schema-version: 1.5\nsymlinks: [rules]\n' \
  'schema-version: 1\nsymlinks: [rules]\n---\nschema-version: 1\nsymlinks: [rules]\n'; do
  printf '%b' "$text" >"$WHITELIST"
  refused_whitelist "whitelist '$text'" "$WHITELIST is malformed"
done
echo 'symlinks: [rules]' >"$WHITELIST"
refused_whitelist "whitelist with no stamp" "$WHITELIST has no schema-version"
for stamp in 0 -1; do
  printf 'schema-version: %s\nsymlinks: [rules]\n' "$stamp" >"$WHITELIST"
  refused_whitelist "whitelist stamped $stamp" "$WHITELIST has schema-version $stamp, and 1 or higher is needed"
done
for entry in '""' . .. a/b /a a/ '"a\nb"'; do
  printf 'schema-version: 1\nsymlinks: [rules, %s, skills]\n' "$entry" >"$WHITELIST"
  refused_whitelist "whitelist entry $entry" "$WHITELIST has an entry that is empty, '.', '..', or holds a '/' or a line break"
done

# The same account under a good whitelist runs, so the refusals above are
# the whitelist's.
whitelist CLAUDE.md rules skills
run add work
check "$RC" "0" "negative control: a good whitelist: add runs"

# --- yq and HOME ------------------------------------------------------------
# A PATH with no yq, then with a yq that is not mikefarah's v4.
mkdir "$SANDBOX/bin"
before=$(tree)
for mode in list "add other" "remove work"; do
  read -ra words <<<"$mode"
  ERR=$(PATH="$SANDBOX/bin" /bin/bash "$LINKS" "${words[@]}" 2>&1)
  check "$?:$ERR" "1:cr-account-links: yq is not on PATH; mikefarah yq v4 or higher is needed" "no yq, $mode: exit 1 naming yq"
done
for version in "yq 3.4.3" "yq (https://github.com/mikefarah/yq/) version 3.4.1"; do
  printf '#!/bin/sh\necho "%s"\n' "$version" >"$SANDBOX/bin/yq"
  chmod +x "$SANDBOX/bin/yq"
  ERR=$(PATH="$SANDBOX/bin" /bin/bash "$LINKS" list 2>&1)
  check "$?:$ERR" "1:cr-account-links: the yq on PATH is not mikefarah yq v4 or higher: $version" "$version: exit 1 naming yq"
done
check "$(tree)" "$before" "no usable yq: nothing changed"

for home in "-u HOME" "HOME="; do
  read -ra words <<<"$home"
  ERR=$(env "${words[@]}" /bin/bash "$LINKS" list 2>&1)
  check "$?:$ERR" "1:cr-account-links: HOME is not set" "env $home: refused"
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
