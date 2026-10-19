#!/usr/bin/env bash
#
# cr-deploy.sh -- SessionStart hook: keep ~/.local/bin/cr a copy of the
# resolver beside this script. When the two match it does nothing and
# prints nothing. When the target is missing or differs, it creates
# ~/.local/bin if absent, replaces the target atomically with an
# executable copy, and emits a systemMessage saying so, adding a note when
# ~/.local/bin is not on PATH. It never edits PATH, never blocks the
# session, and exits 0 on every path, a failed write included. Runs under
# the bash 3.2 macOS ships.
set -u

source_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-resolver"
target_dir="$HOME/.local/bin"
target="$target_dir/cr"

# say <message> -- print <message> as the hook's systemMessage, escaped by
# hand so the hook does not need jq.
say() {
  local text=$1
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  printf '{"systemMessage": "%s"}\n' "$text"
}

if cmp -s "$source_file" "$target"; then
  exit 0
fi

tmp=
if mkdir -p "$target_dir" 2>/dev/null &&
  tmp=$(mktemp "$target_dir/.cr.XXXXXX" 2>/dev/null) &&
  cp "$source_file" "$tmp" 2>/dev/null &&
  chmod 755 "$tmp" 2>/dev/null &&
  mv -f "$tmp" "$target" 2>/dev/null; then
  message="cc-tools updated the cr launcher at $target; restart your shell and run cr to use it."
  case ":${PATH-}:" in
    *":$target_dir:"*) ;;
    *) message="$message $target_dir is not on PATH, so add it before cr can be found." ;;
  esac
  say "$message"
else
  [ -z "$tmp" ] || rm -f "$tmp"
  say "cc-tools could not update the cr launcher at $target."
fi
exit 0
