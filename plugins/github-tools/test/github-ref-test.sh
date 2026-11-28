#!/usr/bin/env bash
#
# github-ref-test.sh -- drive plugins/github-tools/bin/github-ref under the
# bash 3.2 macOS ships, with a stub gh and a stub ssh first on PATH: every
# item and repository form, every part rule, --type, --in and --prefix,
# exits 2 and 3 with nothing on stderr, the locale case, and `origin` for
# each URL shape, an ssh alias, a second remote and each exit.
#
# Needs git on PATH. Reaches no network.
#
# Usage: github-ref-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF="$TEST_DIR/../bin/github-ref"
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/github-ref-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0

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

export GIT_CEILING_DIRECTORIES="$SANDBOX"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The stub gh appends its arguments, one line per call, to
# $SANDBOX/gh.calls and prints the contents of $SANDBOX/gh.url, or when
# that file is absent the https:// URL `repo view` was given, without
# `.git`, or https://github.com/upstream/upstream-repo when it was given
# none, as a real gh can pick a fork's `upstream`; it exits with the status
# in $SANDBOX/gh.rc, 0 when absent, saying so on stderr when non-zero.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$SANDBOX/gh.calls"
rc=\$(cat "$SANDBOX/gh.rc" 2>/dev/null || echo 0)
if [ "\$rc" -ne 0 ]; then echo "stub gh: refused" >&2; exit "\$rc"; fi
case "\$3" in
  https://*) u=\${3%.git} ;;
  *) u=https://github.com/upstream/upstream-repo ;;
esac
if [ -f "$SANDBOX/gh.url" ]; then cat "$SANDBOX/gh.url"; else echo "\$u"; fi
EOF
# The stub ssh answers `-G -- <host>` as `ssh -G` does, naming github.com
# for the alias github-work, ssh.github.com for the alias github-443, and
# <host> itself otherwise; it logs each call to $SANDBOX/ssh.calls and exits
# with the status in $SANDBOX/ssh.rc, 0 when absent.
cat >"$SANDBOX/bin/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$SANDBOX/ssh.calls"
case "\$3" in
  github-work) h=github.com ;;
  github-443) h=ssh.github.com ;;
  *) h=\$3 ;;
esac
printf 'host %s\nuser git\nhostname %s\nport 22\n' "\$3" "\$h"
exit "\$(cat "$SANDBOX/ssh.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/ssh"

REPO="$SANDBOX/repo"
git init -q "$REPO"
git -C "$REPO" remote add origin git@github.com:acme/widgets.git
NO_ORIGIN="$SANDBOX/no-origin"
git init -q "$NO_ORIGIN"
PLAIN="$SANDBOX/plain"
mkdir -p "$PLAIN"

# ref [--dir <dir>] <arg>... -- run github-ref from <dir>, $REPO by
# default; leaves OUT, ERR, RC and GH (gh's calls).
ref() {
  local dir=$REPO
  if [ "${1-}" = --dir ]; then
    dir=$2
    shift 2
  fi
  rm -f "$SANDBOX/gh.calls" "$SANDBOX/ssh.calls"
  OUT=$(cd "$dir" && PATH="$SANDBOX/bin:$PATH" /bin/bash "$REF" "$@" 2>"$SANDBOX/stderr")
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
  GH=$(cat "$SANDBOX/gh.calls" 2>/dev/null)
}

# accepts <expected line> <arg>... -- exit 0 with exactly that one line,
# nothing on stderr.
accepts() {
  local want=$1
  shift
  ref "$@"
  check "$RC|$OUT|$ERR" "0|$want|" "accepts $*"
}

# refuses <status> <arg>... -- that status, nothing on stdout or stderr.
refuses() {
  local want=$1
  shift
  ref "$@"
  check "$RC|$OUT|$ERR" "$want||" "refuses $* with $want"
}

IN=(--in ghe.example.com/corp/tools)

check "$([ -x "$REF" ] && echo yes)" "yes" "bin/github-ref is executable"

# --- item: every form, under --in -----------------------------------------
accepts "ghe.example.com|corp|tools|7|issue" item --type issue "${IN[@]}" 7
accepts "ghe.example.com|corp|tools|7|issue" item --type issue "${IN[@]}" '#7'
accepts "ghe.example.com|corp|tools|7|pr" item --type pr "${IN[@]}" '#7'
accepts "ghe.example.com|corp|tools|007|issue" item --type issue "${IN[@]}" 007
accepts "ghe.example.com|corp|other|7|issue" item --type issue "${IN[@]}" other#7
accepts "ghe.example.com|octo|lib|7|issue" item --type issue "${IN[@]}" octo/lib#7
accepts "h.example|o|r|7|issue" item --type issue "${IN[@]}" h.example/o/r#7
accepts "h.example|o|r|7|issue" item --type issue "${IN[@]}" h.example/o/r/#7
accepts "h.example|o|r|7|issue" item --type issue "${IN[@]}" https://h.example/o/r#7
accepts "h.example|o|r|7|issue" item --type issue "${IN[@]}" https://h.example/o/r/issues/7
accepts "h.example|o|r|7|issue" item --type issue "${IN[@]}" https://h.example/o/r/issues/7/
accepts "h.example|o|r|7|pr" item --type pr "${IN[@]}" https://h.example/o/r/pull/7
accepts "h.example|o|r|7|pr" item --type pr "${IN[@]}" https://h.example/o/r/pull/7/
accepts "ghe.example.com|corp|-b|7|issue" item --type issue "${IN[@]}" -b#7
accepts "ghe.example.com|corp|tools|7|issue" item --type issue "${IN[@]}" -- 7
accepts "ghe.example.com|corp|.b_|7|issue" item "${IN[@]}" --type issue -- .b_#7
check "$GH" "" "item: a reference resolved under --in makes no gh call"

# --prefix: <P>N only under that P, and N and #N still.
accepts "ghe.example.com|corp|tools|7|issue" item --type issue "${IN[@]}" --prefix GH- GH-7
accepts "ghe.example.com|corp|tools|7|issue" item --type issue "${IN[@]}" --prefix GH- 7
accepts "ghe.example.com|corp|tools|7|issue" item --type issue "${IN[@]}" --prefix GH- '#7'
accepts "ghe.example.com|corp|tools|7|issue" item --type issue "${IN[@]}" --prefix '' 7
accepts "ghe.example.com|corp|other|7|issue" item --type issue "${IN[@]}" --prefix other other#7
accepts "ghe.example.com|corp|tools|77|issue" item --type issue "${IN[@]}" --prefix 7 77
refuses 2 item --type issue "${IN[@]}" GH-7
refuses 2 item --type issue "${IN[@]}" --prefix XY- GH-7
accepts "ghe.example.com|corp|GH-|7|issue" item --type issue "${IN[@]}" --prefix GH- GH-#7

# --type.
refuses 2 item "${IN[@]}" 7
refuses 2 item --type commit "${IN[@]}" 7
refuses 2 item --type issue "${IN[@]}" https://h.example/o/r/pull/7
refuses 2 item --type pr "${IN[@]}" https://h.example/o/r/issues/7
refuses 2 item --type pr --in h.example/o/r https://h.example/o/r/commits/7

# Malformed items, none reaching gh.
for bad in '' x 7x -7 '#' '#x' '##7' other# other#x other#-7 'a#b#7' a//b#7 /a/b#7 a/b/c/d#7 'a b#7' \
  https://github.com/octo/lib/issues/x https://github.com/octo/issues/7 https://github.com/a/b/c/issues/7 \
  http://github.com/octo/lib/issues/7 https://github.com//lib/issues/7 https://github.com/a/b/c#7 \
  'https://github.com/octo/lib/issues/7#x'; do
  refuses 2 item --type issue "$bad"
  check "$GH" "" "item \`$bad\`: no gh call"
done

# --- repo: every form ------------------------------------------------------
accepts "ghe.example.com|corp|r" repo "${IN[@]}" r
accepts "ghe.example.com|o|r" repo "${IN[@]}" o/r
accepts "ghe.example.com|o|r" repo "${IN[@]}" o/r/
accepts "h.example|o|r" repo "${IN[@]}" h.example/o/r
accepts "h.example|o|r" repo "${IN[@]}" https://h.example/o/r
accepts "h.example|o|r" repo "${IN[@]}" https://h.example/o/r/
accepts "h.example|o|r" repo h.example/o/r
check "$GH" "" "repo: a reference naming every part makes no gh call"
for bad in '' / o//r /r a/b/c/d http://h.example/o/r https://h.example/o https://h.example/o/r/x 'o/r#7' \
  h.example//r; do
  refuses 2 repo "${IN[@]}" "$bad"
done
refuses 2 repo --type issue "${IN[@]}" r
refuses 2 repo --prefix '#' "${IN[@]}" r
refuses 2 repo "${IN[@]}" a b

# --- name -------------------------------------------------------------------
accepts "" name my_repo.js
accepts "" name -- -b
refuses 2 name .
refuses 2 name 'a/b'
refuses 2 name "${IN[@]}" r
refuses 2 name

# --- the part rules -------------------------------------------------------
O39=ooooooooooooooooooooooooooooooooooooooo
R100=rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr
L63=hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh
for owner in a a-b-c My-Org mona-cat_octo a_1 "$O39" "${O39%oo}_x"; do
  accepts "h.example|$owner|r" repo "h.example/$owner/r"
done
for owner in -a a- a--b a_ _a a_b_c a_b-c a-_b a.b 'a+b' "${O39}o" "${O39%o}_xx"; do
  refuses 2 repo "h.example/$owner/r"
done
for name in r -r .r r. a_b.c-d "$R100"; do
  accepts "h.example|o|$name" repo "h.example/o/$name"
done
for name in . .. "${R100}r" 'a+b' 'a@b'; do
  refuses 2 repo "h.example/o/$name"
done
LONG_HOST="$L63.$L63.$L63.${L63%hhhhhhhhhhhhh}x.com"
for host in h h-1.example.com "$L63.example.com" "$LONG_HOST"; do
  accepts "$host|o|r" repo "$host/o/r"
done
for host in -h.example h-.example h..example h.example. .h.example h_x.example "${L63}h.example" "a$LONG_HOST"; do
  refuses 2 repo "$host/o/r"
done

# A non-ASCII letter is refused under a UTF-8 locale as under C, in every
# part.
for locale in C en_US.UTF-8; do
  for bad in h.example/caf$'\xc3\xa9'/r h.example/o/caf$'\xc3\xa9' caf$'\xc3\xa9'.example/o/r; do
    rm -f "$SANDBOX/gh.calls"
    OUT=$(cd "$REPO" && LC_ALL=$locale PATH="$SANDBOX/bin:$PATH" /bin/bash "$REF" repo "$bad" 2>"$SANDBOX/stderr")
    check "$?|$OUT|$(cat "$SANDBOX/stderr")" "2||" "LC_ALL=$locale: repo $bad is refused"
  done
  OUT=$(cd "$REPO" && LC_ALL=$locale PATH="$SANDBOX/bin:$PATH" /bin/bash "$REF" name caf$'\xc3\xa9' 2>&1)
  check "$?|$OUT" "2|" "LC_ALL=$locale: name café is refused"
  OUT=$(cd "$REPO" && LC_ALL=$locale PATH="$SANDBOX/bin:$PATH" /bin/bash "$REF" repo h.example/cafe/r 2>&1)
  check "$?|$OUT" "0|h.example|cafe|r" "LC_ALL=$locale: the ASCII spelling is accepted"
done

# --in must name a whole, valid repository.
for bad in o/r h.example/o/r/ https://h.example/o/r h.example/-o/r h.example/o/..; do
  refuses 2 item --type issue --in "$bad" 7
done
refuses 2 item --type issue --in '' 7
refuses 2 item --type issue --in

# --- the checkout's repository, without --in --------------------------------
accepts "github.com|acme|widgets|7|issue" item --type issue 7
check "$GH" "repo view https://github.com/acme/widgets.git --json url --jq .url" \
  "short form: the context comes from gh repo view of origin's URL"
accepts "github.com|acme|other|7|issue" item --type issue other#7
accepts "github.com|octo|lib|7|pr" item --type pr octo/lib#7
accepts "github.com|acme|other" repo other
accepts "github.com|octo|lib" repo octo/lib
accepts "h.example|o|r|7|issue" item --type issue h.example/o/r#7
check "$GH" "" "a reference naming every part makes no gh call"
refuses 2 item --type issue 'other#x'
check "$GH" "" "a malformed short form is refused before any gh call"

refuses 3 --dir "$NO_ORIGIN" item --type issue 7
refuses 3 --dir "$PLAIN" item --type issue other#7
check "$GH" "" "outside a work tree: no gh call"
accepts "h.example|o|r|7|issue" --dir "$PLAIN" item --type issue h.example/o/r#7
echo 1 >"$SANDBOX/gh.rc"
refuses 3 item --type issue 7
refuses 3 repo r
rm "$SANDBOX/gh.rc"
echo https://github.com/acme/.. >"$SANDBOX/gh.url"
refuses 2 item --type issue 7
rm "$SANDBOX/gh.url"

# --- origin -----------------------------------------------------------------
accepts "github.com|acme|widgets" origin
check "$GH" "repo view https://github.com/acme/widgets.git --json url --jq .url" "origin: gh is given origin's URL"

for form in git@github.com:acme/widgets.git org-1@github.com:acme/widgets.git github.com:acme/widgets.git \
  ssh://git@github.com/acme/widgets.git ssh://git@github.com:22/acme/widgets.git \
  git+ssh://git@github.com/acme/widgets.git ssh+git://git@github.com/acme/widgets.git \
  https://user@github.com/acme/widgets.git https://github.com/acme/widgets; do
  git -C "$REPO" remote set-url origin "$form"
  ref origin
  check "$RC|$OUT" "0|github.com|acme|widgets" "origin $form: resolves"
  check "$GH" "repo view https://github.com/acme/widgets${form##*widgets} --json url --jq .url" \
    "origin $form: gh is given its https:// form"
done

for form in git@github-work:acme/widgets.git ssh://git@github-work:22/acme/widgets.git \
  git+ssh://git@github-work/acme/widgets.git ssh+git://git@github-work/acme/widgets.git \
  git@github-443:acme/widgets.git; do
  git -C "$REPO" remote set-url origin "$form"
  ref origin
  check "$RC|$OUT" "0|github.com|acme|widgets" "ssh alias origin $form: the alias's real host"
done
check "$(cat "$SANDBOX/ssh.calls")" "-G -- github-443" "ssh alias origin: ssh -G is asked about the origin's host alone"

git -C "$REPO" remote set-url origin https://github-work/acme/widgets.git
ref origin
check "$RC|$OUT|$([ -e "$SANDBOX/ssh.calls" ] && echo ssh)" "0|github-work|acme|widgets|" \
  "https origin: no ssh call, its host as written"

git -C "$REPO" remote set-url origin git@github-work:acme/widgets.git
echo 255 >"$SANDBOX/ssh.rc"
ref origin
check "$RC|$OUT" "0|github-work|acme|widgets" "ssh -G fails: the origin's host as written"
rm "$SANDBOX/ssh.rc"
git -C "$REPO" remote set-url origin git@github.com:acme/widgets.git

# A second remote: gh asked with no URL would pick `upstream`.
git -C "$REPO" remote add upstream git@github.com:upstream/upstream-repo.git
accepts "github.com|acme|widgets" origin
accepts "github.com|acme|widgets|7|issue" item --type issue 7
git -C "$REPO" remote remove upstream

echo https://github.com/acme/widgets/ >"$SANDBOX/gh.url"
accepts "github.com|acme|widgets" origin
rm "$SANDBOX/gh.url"

refuses 3 --dir "$NO_ORIGIN" origin
refuses 3 --dir "$PLAIN" origin
check "$GH" "" "origin outside a work tree: no gh call"
echo 1 >"$SANDBOX/gh.rc"
refuses 3 origin
rm "$SANDBOX/gh.rc"
refuses 2 origin x
refuses 2 origin --in h.example/o/r

# A refused part: one stdout line, the URL and the part, nothing on stderr.
for case in "https://github.com/acme/..|.." "https://github.com/ac%20me/widgets|ac%20me" \
  "https://github.com/acme/widgets/extra|widgets/extra" "https://-h.example/acme/widgets|-h.example" \
  "https://github.com/acme|https://github.com/acme" "https://github.com/acme/|https://github.com/acme/" \
  "http://github.com/acme/widgets|http://github.com/acme/widgets"; do
  echo "${case%|*}" >"$SANDBOX/gh.url"
  ref origin
  check "$RC|$OUT|$ERR" "2|$case|" "origin returning ${case%|*}: exit 2 naming the part"
done
rm "$SANDBOX/gh.url"

# --- usage ------------------------------------------------------------------
refuses 2
refuses 2 nope 7
refuses 2 item --type
refuses 2 item --type issue "${IN[@]}" 7 8

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
