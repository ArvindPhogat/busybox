#!/bin/zsh
set -euo pipefail

BACKUP_DIR="/Users/seemaphogat/projects/S3/backup-etcd"
TS=$(date -u +%Y%m%d-%H%M%S)
OUT_FILE="${BACKUP_DIR}/etcd-snapshot-${TS}.db"
REMOTE_FILE="/var/lib/etcd/etcd-snapshot-${TS}.db"

mkdir -p "${BACKUP_DIR}"

ETCD_POD=$(kubectl -n kube-system get pod -l component=etcd -o jsonpath='{.items[0].metadata.name}')
if [[ -z "${ETCD_POD}" ]]; then
  echo "ERROR: etcd pod not found in kube-system"
  exit 1
fi

CONTROL_PLANE_NODE=$(kubectl -n kube-system get pod "${ETCD_POD}" -o jsonpath='{.spec.nodeName}')
if [[ -z "${CONTROL_PLANE_NODE}" ]]; then
  echo "ERROR: unable to resolve control-plane node for etcd pod"
  exit 1
fi

kubectl -n kube-system exec "${ETCD_POD}" -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save "${REMOTE_FILE}"

docker cp "${CONTROL_PLANE_NODE}:${REMOTE_FILE}" "${OUT_FILE}"
docker exec "${CONTROL_PLANE_NODE}" rm -f "${REMOTE_FILE}" || true

# Keep only last 5 days (5 x 24 x 60 = 7200 minutes)
find "${BACKUP_DIR}" -type f -name 'etcd-snapshot-*.db' -mmin +7200 -delete

echo "Backup created: ${OUT_FILE}"
