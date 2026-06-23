#!/usr/bin/env bash
# Deployed by /gh-create-identity-app to:
#   ~/.config/claude-github-app/init-repo.sh   (chmod 700)
#
# Applies the per-repo bot-identity override to the current repo:
# sets local user.name/user.email to the bot identity, wires the
# credential helper, and switches an SSH origin to HTTPS so the helper
# is actually consulted. Does NOT touch ~/.gitconfig. Run from inside
# the target repo:  cd /path/to/repo && ~/.config/claude-github-app/init-repo.sh
# Contains no secret text; the bot identity is sourced from `config`.
set -euo pipefail
source ~/.config/claude-github-app/config

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Not a git repo: $(pwd)" >&2
  exit 1
fi

git config --local user.name  "$BOT_NAME"
git config --local user.email "$BOT_EMAIL"
git config --local credential.helper "!$HOME/.config/claude-github-app/credential-helper.sh"

origin=$(git remote get-url origin 2>/dev/null || true)
if [[ "$origin" == git@github.com:* ]]; then
  https_url="https://github.com/${origin#git@github.com:}"
  https_url="${https_url%.git}.git"
  git remote set-url origin "$https_url"
  echo "Switched origin to HTTPS: $https_url"
fi

echo "Repo configured for $BOT_NAME"
