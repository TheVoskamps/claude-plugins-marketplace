#!/usr/bin/env bash
# Deployed by /gh-create-identity-app to:
#   ~/.config/claude-github-app/credential-helper.sh   (chmod 700)
#
# git invokes this with `get` and passes protocol=/host= on stdin.
# Echo those back plus the App token so git matches the credential
# correctly. Wired into a repo via:
#   git config --local credential.helper \
#     "!$HOME/.config/claude-github-app/credential-helper.sh"
# Contains no secret text; it shells out to get-token.sh for the token.
if [[ "${1:-}" == "get" ]]; then
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && break
    case "$key" in
      protocol|host) echo "$key=$value" ;;
    esac
  done
  echo "username=x-access-token"
  echo "password=$(~/.config/claude-github-app/get-token.sh)"
fi
