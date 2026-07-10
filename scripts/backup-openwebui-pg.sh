#!/bin/bash
set -euo pipefail

NAMESPACE="openwebui"
CLUSTER_NAME="openwebui-db"
BACKUP_NAME="openwebui-backup-$(date +%Y%m%d-%H%M%S)"
TIMEOUT=300

echo "Creating Longhorn snapshot backup for ${CLUSTER_NAME}..."

for pvc in $(kubectl get pvc -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} -o jsonpath='{.items[*].metadata.name}'); do
    echo "Creating snapshot for PVC: ${pvc}"
    cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${BACKUP_NAME}-${pvc}
  namespace: ${NAMESPACE}
spec:
  volumeSnapshotClassName: longhorn
  source:
    persistentVolumeClaimName: ${pvc}
EOF
done

echo "Backup initiated: ${BACKUP_NAME}"
echo "PVCs backed up: $(kubectl get pvc -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} -o jsonpath='{.items[*].metadata.name}')"
echo ""
echo "To list snapshots:"
echo "  kubectl get volumesnapshot -n ${NAMESPACE}"
echo ""
echo "To restore from backup:"
echo "  kubectl apply -f - <<EOF"
echo "  apiVersion: v1"
echo "  kind: PersistentVolumeClaim"
echo "  metadata:"
echo "    name: <new-pvc-name>"
echo "    namespace: ${NAMESPACE}"
echo "  spec:"
echo "    dataSource:"
echo "      name: ${BACKUP_NAME}-<pvc-name>"
echo "      kind: VolumeSnapshot"
echo "      apiGroup: snapshot.storage.k8s.io"
echo "    storageClassName: longhorn"
echo "    accessModes:"
echo "      - ReadWriteOnce"
echo "    resources:"
echo "      requests:"
echo "        storage: 10Gi"
echo "EOF"