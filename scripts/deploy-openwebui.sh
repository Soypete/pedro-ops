#!/bin/bash
set -euo pipefail

# OpenWebUI Deployment
#
# Deploys the full OpenWebUI stack, in dependency order:
#   1. CloudNativePG operator      (helm, upstream chart)
#   2. openwebui namespace
#   3. Postgres superuser secret   (generated if absent -- never committed)
#   4. openwebui-secrets           (app secrets, sourced from 1Password)
#   5. SeaweedFS buckets           (delegates to setup-seaweedfs-buckets.sh)
#   6. openwebui-db Cluster CR     (kubectl -- CNPG has no chart for a database)
#   7. pgvector extension
#   8. OpenWebUI + Redis + Tika + pipelines (helm, upstream chart)
#
# Idempotent: safe to re-run, and safe to run against a freshly rebuilt cluster.
# Existing secrets are NOT overwritten, so re-running will not rotate credentials
# out from under a running database.
#
# Usage:
#   ./scripts/deploy-openwebui.sh
#   SKIP_SECRETS=1 ./scripts/deploy-openwebui.sh   # secrets already exist
#
# Prerequisites:
#   - kubectl with KUBECONFIG set (~/.foundry/kubeconfig)
#   - helm
#   - SeaweedFS running (for S3 file storage)
#   - op (1Password CLI) unless SKIP_SECRETS=1 or the secret already exists

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${OPENWEBUI_NAMESPACE:-openwebui}"
RELEASE="${OPENWEBUI_RELEASE:-openwebui}"
VALUES="${REPO_ROOT}/helm/openwebui/values.yaml"
PG_MANIFEST="${REPO_ROOT}/k8s/openwebui/postgres.yaml"
PG_CLUSTER="openwebui-db"
PG_SECRET="openwebui-db-superuser"
APP_SECRET="openwebui-secrets"
SKIP_SECRETS="${SKIP_SECRETS:-0}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "      $1"; }
ok()    { echo -e "      ${GREEN}✓ $1${NC}"; }
warn()  { echo -e "      ${YELLOW}! $1${NC}"; }
fail()  { echo -e "      ${RED}✗ $1${NC}"; }

echo "=== OpenWebUI Deployment ==="
echo ""

# --- preflight -------------------------------------------------------------
for bin in kubectl helm; do
    command -v "$bin" >/dev/null || { fail "$bin not found in PATH"; exit 1; }
done

if ! kubectl get nodes &>/dev/null; then
    fail "Cannot access Kubernetes cluster"
    echo "  export KUBECONFIG=~/.foundry/kubeconfig"
    exit 1
fi

[ -f "$VALUES" ] || { fail "missing $VALUES"; exit 1; }
[ -f "$PG_MANIFEST" ] || { fail "missing $PG_MANIFEST"; exit 1; }

# --- 1. CNPG operator ------------------------------------------------------
echo "[1/8] CloudNativePG operator..."
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo add open-webui https://helm.openwebui.com >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

if kubectl get crd clusters.postgresql.cnpg.io &>/dev/null; then
    ok "CRDs already present"
else
    info "installing..."
fi
helm upgrade --install cnpg cnpg/cloudnative-pg \
    -n cnpg-system --create-namespace --wait --timeout 5m >/dev/null
ok "operator ready"
echo ""

# --- 2. namespace ----------------------------------------------------------
echo "[2/8] Namespace ${NAMESPACE}..."
kubectl create ns "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "namespace ready"
echo ""

# --- 3. postgres superuser secret -----------------------------------------
echo "[3/8] Postgres superuser secret..."
if kubectl -n "$NAMESPACE" get secret "$PG_SECRET" &>/dev/null; then
    ok "${PG_SECRET} exists (not overwriting -- rotating would break the running DB)"
else
    PGPW="$(openssl rand -base64 36 | tr -d '\n/+=' | head -c 40)"
    kubectl -n "$NAMESPACE" create secret generic "$PG_SECRET" \
        --type=kubernetes.io/basic-auth \
        --from-literal=username=postgres \
        --from-literal=password="$PGPW" >/dev/null
    ok "${PG_SECRET} created with a generated password"
    warn "store it in 1Password: kubectl -n ${NAMESPACE} get secret ${PG_SECRET} -o jsonpath='{.data.password}' | base64 -d"
fi
echo ""

# --- 4. app secrets --------------------------------------------------------
echo "[4/8] Application secrets..."
if kubectl -n "$NAMESPACE" get secret "$APP_SECRET" &>/dev/null; then
    ok "${APP_SECRET} exists"
    # A stale DATABASE_URL (left over from a previous cluster) causes the same
    # "password authentication failed" crashloop as a mismatched DB password,
    # so verify it carries the current superuser password.
    if kubectl -n "$NAMESPACE" get secret "$PG_SECRET" &>/dev/null; then
        _pw="$(kubectl -n "$NAMESPACE" get secret "$PG_SECRET" -o jsonpath='{.data.password}' | base64 -d)"
        _url="$(kubectl -n "$NAMESPACE" get secret "$APP_SECRET" -o jsonpath='{.data.DATABASE_URL}' | base64 -d)"
        if [ -n "$_url" ] && ! printf '%s' "$_url" | grep -qF "$_pw"; then
            warn "DATABASE_URL does not contain the current superuser password -- refreshing it"
            kubectl -n "$NAMESPACE" patch secret "$APP_SECRET" --type=merge -p \
                "{\"data\":{\"DATABASE_URL\":\"$(printf 'postgresql://postgres:%s@%s-rw:5432/openwebui' "$_pw" "$PG_CLUSTER" | base64 | tr -d '\n')\"}}" >/dev/null
            ok "DATABASE_URL refreshed"
        fi
    fi
elif [ "$SKIP_SECRETS" = "1" ]; then
    warn "${APP_SECRET} missing and SKIP_SECRETS=1 -- OpenWebUI will not start"
else
    # S3 credentials live in the Foundry stack config, not in a k8s Secret --
    # SeaweedFS receives them through chart values at install time.
    # NOTE: this is the SAME key pair Loki and Velero use, so OpenWebUI can read
    # and delete their objects. Splitting these into per-app least-privilege
    # credentials is tracked in the audit doc; do not treat this as good practice.
    STACK="${FOUNDRY_STACK:-$HOME/.foundry/stack.yaml}"
    if [ ! -f "$STACK" ]; then
        fail "cannot read S3 credentials: ${STACK} not found"
        echo ""
        echo "  Create ${APP_SECRET} manually, then re-run:"
        echo "    kubectl -n ${NAMESPACE} create secret generic ${APP_SECRET} \\"
        echo "      --from-literal=WEBUI_SECRET_KEY=\$(openssl rand -hex 32) \\"
        echo "      --from-literal=DATABASE_URL=postgresql://postgres:<pw>@${PG_CLUSTER}-rw:5432/openwebui \\"
        echo "      --from-literal=AWS_ACCESS_KEY_ID=... \\"
        echo "      --from-literal=AWS_SECRET_ACCESS_KEY=..."
        exit 1
    fi
    info "sourcing S3 credentials from ${STACK}..."
    S3_KEY="$(awk '/^[[:space:]]*s3_access_key:/ {print $2; exit}' "$STACK")"
    S3_SEC="$(awk '/^[[:space:]]*s3_secret_key:/ {print $2; exit}' "$STACK")"
    if [ -z "$S3_KEY" ] || [ -z "$S3_SEC" ]; then
        fail "could not parse s3_access_key / s3_secret_key from ${STACK}"
        exit 1
    fi
    PGPW="$(kubectl -n "$NAMESPACE" get secret "$PG_SECRET" -o jsonpath='{.data.password}' | base64 -d)"
    kubectl -n "$NAMESPACE" create secret generic "$APP_SECRET" \
        --from-literal=WEBUI_SECRET_KEY="$(openssl rand -hex 32)" \
        --from-literal=DATABASE_URL="postgresql://postgres:${PGPW}@${PG_CLUSTER}-rw:5432/openwebui" \
        --from-literal=AWS_ACCESS_KEY_ID="$S3_KEY" \
        --from-literal=AWS_SECRET_ACCESS_KEY="$S3_SEC" >/dev/null
    ok "${APP_SECRET} created"
    warn "WEBUI_SECRET_KEY was generated -- save it to 1Password, it invalidates sessions if lost"
fi
echo ""

# --- 5. S3 buckets ---------------------------------------------------------
echo "[5/8] SeaweedFS buckets..."
if kubectl -n seaweedfs get pod seaweedfs-filer-0 &>/dev/null; then
    # Surface only the per-bucket result lines; the child script's trailing
    # remediation notes are not useful inline here.
    "${REPO_ROOT}/scripts/setup-seaweedfs-buckets.sh" openwebui openwebui-pg 2>&1 \
        | grep -E '(created|already exists|still missing|bucket\(s\) present)' \
        | sed 's/^ */      /'
else
    warn "SeaweedFS not found -- skipping bucket creation (file storage will fail)"
fi
echo ""

# --- 6. postgres cluster ---------------------------------------------------
echo "[6/8] Postgres cluster ${PG_CLUSTER}..."
kubectl apply -f "$PG_MANIFEST" >/dev/null
info "waiting for cluster to become ready (up to 5m)..."
for _ in $(seq 1 60); do
    READY="$(kubectl -n "$NAMESPACE" get cluster "$PG_CLUSTER" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)"
    [ "${READY:-0}" -ge 1 ] && break
    sleep 5
done
if [ "${READY:-0}" -ge 1 ]; then
    ok "cluster healthy (${READY} ready instance(s))"
else
    fail "cluster did not become ready"
    kubectl -n "$NAMESPACE" get cluster "$PG_CLUSTER" 2>&1 | sed 's/^/      /'
    exit 1
fi
echo ""

# --- 7. pgvector + superuser password reconcile ----------------------------
# Two first-bootstrap gotchas, both idempotent to repair:
#
#  a) postInitSQL only runs on FIRST bootstrap, so a cluster that already
#     existed (or was recovered from backup) can be missing pgvector.
#
#  b) If the cluster bootstrapped BEFORE superuserSecret existed, CNPG keeps the
#     password it generated at bootstrap and does not retroactively adopt the
#     Secret. OpenWebUI then fails with:
#       FATAL: password authentication failed for user "postgres"
#     Step 3 runs before step 6 so a clean install is fine, but an
#     already-bootstrapped cluster needs the password aligned to the Secret.
echo "[7/8] pgvector extension + superuser password..."
PRIMARY="$(kubectl -n "$NAMESPACE" get cluster "$PG_CLUSTER" -o jsonpath='{.status.currentPrimary}')"

PGPW="$(kubectl -n "$NAMESPACE" get secret "$PG_SECRET" -o jsonpath='{.data.password}' | base64 -d)"
if kubectl -n "$NAMESPACE" exec "$PRIMARY" -c postgres -- \
        env PGPASSWORD="$PGPW" psql -h 127.0.0.1 -U postgres -d openwebui -tAc "select 1;" >/dev/null 2>&1; then
    ok "superuser password matches ${PG_SECRET}"
else
    warn "database password does not match ${PG_SECRET} -- aligning it"
    kubectl -n "$NAMESPACE" exec "$PRIMARY" -c postgres -- \
        psql -U postgres -d openwebui -c "ALTER USER postgres WITH PASSWORD '${PGPW}';" >/dev/null
    if kubectl -n "$NAMESPACE" exec "$PRIMARY" -c postgres -- \
            env PGPASSWORD="$PGPW" psql -h 127.0.0.1 -U postgres -d openwebui -tAc "select 1;" >/dev/null 2>&1; then
        ok "superuser password aligned"
    else
        fail "could not align superuser password"
        exit 1
    fi
fi

kubectl -n "$NAMESPACE" exec "$PRIMARY" -c postgres -- \
    psql -U postgres -d openwebui -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1
VEC="$(kubectl -n "$NAMESPACE" exec "$PRIMARY" -c postgres -- \
    psql -U postgres -d openwebui -tAc "select extversion from pg_extension where extname='vector';" 2>/dev/null | tr -d '\r')"
if [ -n "$VEC" ]; then
    ok "pgvector ${VEC} installed"
else
    fail "pgvector not installed -- VECTOR_DB=pgvector will fail"
    exit 1
fi
echo ""

# --- 8. openwebui ----------------------------------------------------------
echo "[8/8] OpenWebUI (+ Redis, Tika, pipelines)..."
helm upgrade --install "$RELEASE" open-webui/open-webui \
    -n "$NAMESPACE" -f "$VALUES" --wait --timeout 10m >/dev/null
ok "helm release deployed"
echo ""

echo -e "${GREEN}=== Deployment complete ===${NC}"
echo ""
kubectl -n "$NAMESPACE" get pods
echo ""
echo "Access (no ingress -- ingress.enabled=false, Tailscale was the intended path):"
echo "  kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-open-webui 8080:8080"
echo ""
echo "NOTE: this cluster has NO backup for ${PG_CLUSTER}. See issue #13."
