#!/bin/bash
set -euo pipefail

# SeaweedFS Bucket Provisioning
#
# Creates the S3 buckets the cluster depends on. Idempotent: existing buckets
# are left alone, so this is safe to re-run and safe to run during a rebuild.
#
# Why this exists: the 2026-08-03 rebuild left SeaweedFS with filer metadata
# referencing volumes that no longer existed, and with buckets missing entirely.
# That single fault crashlooped Loki and broke Velero. Bucket creation was a
# manual step nobody had written down.
#
# Usage:
#   ./scripts/setup-seaweedfs-buckets.sh            # create the default set
#   ./scripts/setup-seaweedfs-buckets.sh foo bar    # create specific buckets

NAMESPACE="${SEAWEEDFS_NAMESPACE:-seaweedfs}"
FILER_POD="${SEAWEEDFS_FILER_POD:-seaweedfs-filer-0}"

# Buckets required by the stack. Keep in sync with:
#   loki       -> foundry stack.yaml components.loki.s3_bucket
#   velero     -> foundry stack.yaml components.velero (BSL objectStorage.bucket)
#   openwebui  -> helm/openwebui/values.yaml persistence.s3.bucket
#   openwebui-pg -> CNPG barman-cloud ObjectStore (see issue #13)
DEFAULT_BUCKETS=(loki velero openwebui openwebui-pg)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [ "$#" -gt 0 ]; then
    BUCKETS=("$@")
else
    BUCKETS=("${DEFAULT_BUCKETS[@]}")
fi

echo "=== SeaweedFS Bucket Provisioning ==="
echo ""

if ! kubectl get nodes &>/dev/null; then
    echo -e "${RED}Cannot access Kubernetes cluster!${NC}"
    echo "Make sure kubeconfig is set:"
    echo "  export KUBECONFIG=~/.foundry/kubeconfig"
    exit 1
fi

if ! kubectl -n "$NAMESPACE" get pod "$FILER_POD" &>/dev/null; then
    echo -e "${RED}✗ Filer pod ${NAMESPACE}/${FILER_POD} not found${NC}"
    echo "  Is SeaweedFS deployed? kubectl -n ${NAMESPACE} get pods"
    exit 1
fi

# Run a command in `weed shell` on the filer pod.
weed_shell() {
    kubectl -n "$NAMESPACE" exec "$FILER_POD" --request-timeout=60s -- \
        sh -c "echo '$1' | weed shell" 2>/dev/null
}

# weed shell prints banner lines and its ">" prompt to the same stream as
# results, and the first result shares a line with the prompt ("> \tloki\tsize:0").
# Match on the trailing "size:" marker and strip any leading prompt/whitespace,
# rather than a bare grep which would false-positive on the command echo.
list_buckets() {
    weed_shell "s3.bucket.list" \
        | sed -n 's/.*[[:space:]>]\{1,\}\([A-Za-z0-9._-]\{1,\}\)[[:space:]]\{1,\}size:.*/\1/p'
}

echo "[1/3] Reading existing buckets..."
EXISTING="$(list_buckets || true)"
if [ -n "$EXISTING" ]; then
    echo "$EXISTING" | sed 's/^/      /'
else
    echo "      (none)"
fi
echo ""

echo "[2/3] Creating missing buckets..."
CREATED=0
for bucket in "${BUCKETS[@]}"; do
    if echo "$EXISTING" | grep -qx "$bucket"; then
        echo -e "      ${YELLOW}= ${bucket}${NC} already exists, skipping"
    else
        weed_shell "s3.bucket.create -name ${bucket}" >/dev/null
        echo -e "      ${GREEN}+ ${bucket}${NC} created"
        CREATED=$((CREATED + 1))
    fi
done
echo ""

echo "[3/3] Verifying..."
FINAL="$(list_buckets || true)"
MISSING=0
for bucket in "${BUCKETS[@]}"; do
    if ! echo "$FINAL" | grep -qx "$bucket"; then
        echo -e "      ${RED}✗ ${bucket} still missing${NC}"
        MISSING=$((MISSING + 1))
    fi
done

if [ "$MISSING" -gt 0 ]; then
    echo ""
    echo -e "${RED}✗ ${MISSING} bucket(s) could not be created${NC}"
    exit 1
fi

echo -e "      ${GREEN}✓ all ${#BUCKETS[@]} bucket(s) present${NC}"
echo ""
echo -e "${GREEN}=== Done (${CREATED} created) ===${NC}"
echo ""
echo "NOTE: a bucket existing does not prove S3 reads work. If the filer holds"
echo "metadata for volumes that no longer exist, GETs return HTTP 500 while the"
echo "bucket still lists fine. Verify with:"
echo "  kubectl -n ${NAMESPACE} logs deploy/seaweedfs-s3 --tail=50"
echo ""
echo "If you see 'volume N not found for fileId', the filer has orphaned entries"
echo "from a previous cluster whose volume data is gone. The referenced objects are"
echo "unrecoverable; only dead metadata remains. Clear a affected bucket with:"
echo ""
echo "  # DESTRUCTIVE -- deletes all objects in the bucket. Confirm the data is"
echo "  # genuinely orphaned first (fs.meta.cat shows a volumeId that does not"
echo "  # exist in 'weed shell -> volume.list')."
echo "  kubectl -n ${NAMESPACE} exec ${FILER_POD} -- \\"
echo "    sh -c \"echo 's3.bucket.delete -name <bucket>' | weed shell\""
echo "  ./scripts/setup-seaweedfs-buckets.sh <bucket>   # recreate empty"
