#!/usr/bin/env bash
# Syncs the Discord webhook from OpenBao into the Secret consumed by
# AlertmanagerConfig. The webhook is never printed or written to the repo.
set -euo pipefail

: "${VAULT_ADDR:=http://100.70.90.12:8200}"
KEYS_FILE="${OPENBAO_KEYS_FILE:-$HOME/.foundry/openbao-keys/test/keys.json}"
VAULT_PATH="${DISCORD_VAULT_PATH:-foundry-core/monitoring/discord}"
NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
SECRET_NAME="${DISCORD_SECRET_NAME:-alertmanager-discord}"

for binary in vault jq kubectl; do
  command -v "$binary" >/dev/null || { echo "ERROR: $binary is required" >&2; exit 1; }
done
[ -r "$KEYS_FILE" ] || { echo "ERROR: cannot read $KEYS_FILE" >&2; exit 1; }

export VAULT_ADDR
export VAULT_TOKEN="$(jq -er '.root_token' "$KEYS_FILE")"
WEBHOOK_URL="$(vault kv get -field=webhook_url "$VAULT_PATH")"
[ -n "$WEBHOOK_URL" ] || { echo "ERROR: webhook_url is empty at $VAULT_PATH" >&2; exit 1; }

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=webhook-url="$WEBHOOK_URL" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "Synced $NAMESPACE/$SECRET_NAME from OpenBao path $VAULT_PATH"
