#!/usr/bin/env bash
# Deployed by /gh-create-identity-app to:
#   ~/.config/claude-github-app/get-token.sh   (chmod 700)
#
# Mints a fresh GitHub App installation token (cached on disk until
# ~5 min before expiry) and prints it to stdout. Reads App identity
# from ~/.config/claude-github-app/config and signs a JWT with the
# App's private key. Contains NO secret text itself — the secrets it
# reads (config, private-key.pem, .token-cache) live alongside it in
# the un-mirrored ~/.config/claude-github-app/ directory and are never
# committed or mirrored (see the skill's secret-boundary notes).
set -euo pipefail

CONFIG_DIR="$HOME/.config/claude-github-app"
CACHE_FILE="$CONFIG_DIR/.token-cache"
# shellcheck source=/dev/null
source "$CONFIG_DIR/config"

# Reuse cached token if it has >5 min left
if [[ -f "$CACHE_FILE" ]]; then
  expires_at=$(jq -r .expires_at_epoch "$CACHE_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if (( expires_at - now > 300 )); then
    jq -r .token "$CACHE_FILE"
    exit 0
  fi
fi

# Build JWT (RS256) signed with the App's private key
header=$(printf '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-')
now=$(date +%s)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now-60)) $((now+540)) "$APP_ID" \
  | base64 | tr -d '=' | tr '/+' '_-')
sig=$(printf '%s.%s' "$header" "$payload" \
  | openssl dgst -sha256 -sign "$PRIVATE_KEY" \
  | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
jwt="$header.$payload.$sig"

# Exchange JWT for installation token
resp=$(curl -sS -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens")

token=$(echo "$resp" | jq -r .token)
expires_at=$(echo "$resp" | jq -r .expires_at)

if [[ "$token" == "null" || -z "$token" ]]; then
  echo "Failed to mint installation token: $resp" >&2
  exit 1
fi

expires_at_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null \
  || date -d "$expires_at" +%s)

jq -n --arg t "$token" --arg ea "$expires_at" --argjson eae "$expires_at_epoch" \
  '{token:$t, expires_at:$ea, expires_at_epoch:$eae}' > "$CACHE_FILE"
chmod 600 "$CACHE_FILE"

echo "$token"
