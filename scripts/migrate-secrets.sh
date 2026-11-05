#!/bin/bash
# Copies the vault secrets the pulled @aaronge/* workflows need from their
# source repos into this ops repo, entirely through swamp's vault commands.
# Each value goes from `vault read-secret` to `vault put` through a pipe.
# It never appears in argv, in the terminal, or in a temp file.
#
# Re-runnable. A vault that already exists in the ops repo is reused, and
# `vault put` overwrites the key with the current source value.
#
# To add a secret, add a line to SECRETS: "<source repo> <vault> <key>".
set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS="$HOME/Repositories"

SECRETS=(
  "news-w-anchor news-secrets DISCORD_WEBHOOK_URL"
)

# Always run against the local repos, never a serve picked up from the env.
unset SWAMP_SERVE_URL SWAMP_SERVER_URL

vault_exists() {
  swamp vault list-keys "$1" --repo-dir "$OPS_DIR" --json >/dev/null 2>&1
}

for entry in "${SECRETS[@]}"; do
  read -r src vault key <<<"$entry"

  if ! vault_exists "$vault"; then
    echo "Creating local_encryption vault '$vault' in the ops repo"
    swamp vault create local_encryption "$vault" --repo-dir "$OPS_DIR" >/dev/null
  fi

  echo "Copying $vault/$key from $src"
  swamp vault read-secret "$vault" "$key" --repo-dir "$REPOS/$src" --json --force \
    | jq -er '.value' \
    | swamp vault put "$vault" "$key" --repo-dir "$OPS_DIR" >/dev/null

  # Compare hashes so the value itself is never shown.
  digest() {
    swamp vault read-secret "$vault" "$key" --repo-dir "$1" --json --force \
      | jq -jr '.value' | sha256sum | cut -c1-12
  }
  if [ "$(digest "$REPOS/$src")" = "$(digest "$OPS_DIR")" ]; then
    echo "  ok (sha256 matches)"
  else
    echo "  MISMATCH between source and ops repo" >&2
    exit 1
  fi
done
