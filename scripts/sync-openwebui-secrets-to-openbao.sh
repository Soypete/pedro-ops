#!/bin/bash
set -euo pipefail

# Sync OpenWebUI cluster secrets into OpenBAO
#
# WHY: WEBUI_SECRET_KEY is generated at deploy time and currently lives ONLY in
# the Kubernetes Secret. If the cluster is rebuilt it is lost, and losing it
# invalidates every existing OpenWebUI session. The Postgres superuser password
# has the same problem. These are cluster secrets, so OpenBAO is their home.
#
# This reads the live Kubernetes secrets and writes them to OpenBAO. It does NOT
# read anything back out or print secret values.
#
# OpenBAO runs OUTSIDE the k8s cluster (host-level Foundry component), currently
# at http://100.70.90.12:8200. It survived the 2026-08-03 rebuild.
#
# Usage:
#   ./scripts/sync-openwebui-secrets-to-openbao.sh            # write
#   DRY_RUN=1 ./scripts/sync-openwebui-secrets-to-openbao.sh  # show paths only
#
# Auth: uses $VAULT_TOKEN if set, otherwise the root token from
#       ~/.foundry/openbao-keys/<cluster>/keys.json

VAULT_ADDR="${VAULT_ADDR:-http://100.70.90.12:8200}"
KEYS_FILE="${OPENBAO_KEYS_FILE:-$HOME/.foundry/openbao-keys/test/keys.json}"
MOUNT="${OPENBAO_MOUNT:-foundry-core}"
NAMESPACE="${OPENWEBUI_NAMESPACE:-openwebui}"
DRY_RUN="${DRY_RUN:-0}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== Sync OpenWebUI secrets -> OpenBAO ==="
echo ""
echo "  OpenBAO: ${VAULT_ADDR}"
echo "  Mount:   ${MOUNT}"
echo ""

if ! kubectl get nodes &>/dev/null; then
    echo -e "${RED}Cannot access Kubernetes cluster${NC}"
    echo "  export KUBECONFIG=~/.foundry/kubeconfig"
    exit 1
fi

# --- auth -----------------------------------------------------------------
if [ -z "${VAULT_TOKEN:-}" ]; then
    if [ ! -f "$KEYS_FILE" ]; then
        echo -e "${RED}No \$VAULT_TOKEN and no keys file at ${KEYS_FILE}${NC}"
        exit 1
    fi
    VAULT_TOKEN="$(python3 -c "import json;print(json.load(open('${KEYS_FILE}'))['root_token'])")"
    echo -e "      ${YELLOW}! using root token from ${KEYS_FILE}${NC}"
    echo -e "      ${YELLOW}  (prefer a scoped token via \$VAULT_TOKEN for routine use)${NC}"
fi

HEALTH="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "${VAULT_ADDR}/v1/sys/health" || echo 000)"
if [ "$HEALTH" != "200" ]; then
    echo -e "${RED}OpenBAO not healthy at ${VAULT_ADDR} (HTTP ${HEALTH})${NC}"
    echo "  If the address changed, re-run with:"
    echo "    VAULT_ADDR=http://<host>:8200 $0"
    exit 1
fi
echo -e "      ${GREEN}✓ OpenBAO reachable and unsealed${NC}"
echo ""

# --- helpers --------------------------------------------------------------
# Read one key out of a k8s secret. Returns empty if absent.
k8s_secret_value() {
    kubectl -n "$NAMESPACE" get secret "$1" -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# Write a KV-v2 secret. Values are passed via stdin as JSON so they never
# appear in the process list.
bao_put() {
    local path="$1" json="$2"
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "      ${YELLOW}[dry-run]${NC} would write ${MOUNT}/${path} keys: $(printf '%s' "$json" | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["data"].keys()))')"
        return
    fi
    local code
    code="$(printf '%s' "$json" | curl -s -m 15 -o /dev/null -w '%{http_code}' \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -X POST --data-binary @- "${VAULT_ADDR}/v1/${MOUNT}/data/${path}")"
    if [ "$code" = "200" ] || [ "$code" = "204" ]; then
        echo -e "      ${GREEN}✓${NC} ${MOUNT}/${path}"
    else
        echo -e "      ${RED}✗${NC} ${MOUNT}/${path} (HTTP ${code})"
        return 1
    fi
}

# Build KV-v2 payload from key=value pairs without interpolating into a shell
# string (avoids quoting bugs and keeps values out of argv).
build_payload() {
    python3 -c '
import json,sys
data = {}
for line in sys.stdin.read().split("\0"):
    if not line: continue
    k, _, v = line.partition("=")
    if v: data[k] = v
print(json.dumps({"data": data}))
'
}

# --- openwebui app secrets ------------------------------------------------
echo "[1/2] openwebui app secrets..."
WEBUI_KEY="$(k8s_secret_value openwebui-secrets WEBUI_SECRET_KEY)"
DB_URL="$(k8s_secret_value openwebui-secrets DATABASE_URL)"
S3_ID="$(k8s_secret_value openwebui-secrets AWS_ACCESS_KEY_ID)"
S3_SECRET="$(k8s_secret_value openwebui-secrets AWS_SECRET_ACCESS_KEY)"

if [ -z "$WEBUI_KEY" ]; then
    echo -e "      ${RED}✗ openwebui-secrets/WEBUI_SECRET_KEY not found in ns ${NAMESPACE}${NC}"
    exit 1
fi

printf 'WEBUI_SECRET_KEY=%s\0DATABASE_URL=%s\0AWS_ACCESS_KEY_ID=%s\0AWS_SECRET_ACCESS_KEY=%s\0' \
    "$WEBUI_KEY" "$DB_URL" "$S3_ID" "$S3_SECRET" \
    | build_payload | { read -r payload; bao_put "apps/openwebui" "$payload"; }
echo ""

# --- postgres superuser ---------------------------------------------------
echo "[2/2] openwebui-db superuser..."
PG_USER="$(k8s_secret_value openwebui-db-superuser username)"
PG_PASS="$(k8s_secret_value openwebui-db-superuser password)"

if [ -z "$PG_PASS" ]; then
    echo -e "      ${YELLOW}! openwebui-db-superuser not found, skipping${NC}"
else
    printf 'username=%s\0password=%s\0' "$PG_USER" "$PG_PASS" \
        | build_payload | { read -r payload; bao_put "apps/openwebui-db" "$payload"; }
fi
echo ""

echo -e "${GREEN}=== Done ===${NC}"
echo ""
echo "Verify (prints key names only, not values):"
echo "  curl -s -H \"X-Vault-Token: \$VAULT_TOKEN\" \\"
echo "    ${VAULT_ADDR}/v1/${MOUNT}/data/apps/openwebui | python3 -c \\"
echo "    'import json,sys;print(list(json.load(sys.stdin)[\"data\"][\"data\"].keys()))'"
echo ""
echo "NOTE: these secrets are also still in 1Password-less generated form. After"
echo "verifying, treat OpenBAO as the source of truth and re-run this after any"
echo "credential rotation."
