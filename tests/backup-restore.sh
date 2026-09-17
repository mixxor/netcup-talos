#!/usr/bin/env bash
# Longhorn backup and restore, proven end to end against a throwaway S3.
#
# Why this exists: an untested backup is not a backup. This stands up SeaweedFS
# inside the cluster as an S3 target, backs a volume up, DESTROYS the volume,
# restores it from the backup and compares the content byte for byte.
#
# The in-cluster target is a TEST HARNESS, not a backup destination. It shares
# the failure domain it is supposed to protect against - the cluster dies, the
# backup dies with it. It runs on local-path rather than Longhorn on purpose,
# because backing Longhorn up to Longhorn is circular. For real use point
# longhorn_backup_target at something outside the cluster.
#
# Usage:
#   tests/backup-restore.sh            # full cycle, cleans up afterwards
#   tests/backup-restore.sh --keep     # leave SeaweedFS and the volumes standing
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
# shellcheck source=../netcup/lib/generated.sh
. "$ROOT/netcup/lib/generated.sh"
GEN="$(gen_dir "$ROOT")" || exit 1
export KUBECONFIG="${KUBECONFIG:-$GEN/kubeconfig}"
NS=backup-test
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

cleanup() {
  [ "$KEEP" -eq 1 ] && { echo; echo "--keep: $NS, restored-vol and restored-pv are left in place"; return; }
  echo
  echo "== cleanup =="
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true
  kubectl delete pv restored-pv --wait=false >/dev/null 2>&1 || true
  kubectl -n longhorn-system delete volumes.longhorn.io restored-vol --wait=false >/dev/null 2>&1 || true
  # Put the backup target back, otherwise Longhorn logs errors about an
  # endpoint that no longer exists.
  kubectl -n longhorn-system patch backuptargets.longhorn.io default --type=merge \
    -p '{"spec":{"backupTargetURL":"","credentialSecret":""}}' >/dev/null 2>&1 || true
  kubectl -n longhorn-system delete secret seaweedfs-backup >/dev/null 2>&1 || true
}
trap cleanup EXIT

step() { echo; echo "########## $* ##########"; }

step "1/7  SeaweedFS as an S3 target"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - <<YAML >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: seaweedfs, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: {requests: {storage: 10Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: seaweedfs, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: seaweedfs}}
  template:
    metadata: {labels: {app: seaweedfs}}
    spec:
      containers:
        - name: seaweedfs
          image: chrislusf/seaweedfs:3.97
          args: ["server", "-dir=/data", "-s3", "-s3.port=8333", "-master.volumeSizeLimitMB=1024"]
          env:
            - {name: AWS_ACCESS_KEY_ID, value: testkey}
            - {name: AWS_SECRET_ACCESS_KEY, value: testsecret}
          ports: [{containerPort: 8333, name: s3}]
          volumeMounts: [{name: data, mountPath: /data}]
      volumes:
        - {name: data, persistentVolumeClaim: {claimName: seaweedfs}}
---
apiVersion: v1
kind: Service
metadata: {name: seaweedfs, namespace: $NS}
spec:
  selector: {app: seaweedfs}
  ports: [{port: 8333, targetPort: 8333, name: s3}]
YAML
kubectl -n "$NS" rollout status deploy/seaweedfs --timeout=5m
POD=$(kubectl -n "$NS" get pod -l app=seaweedfs -o jsonpath='{.items[0].metadata.name}')

# "Deployment rolled out" only means the container started. Master, volume
# server and filer come up afterwards and independently, and "weed shell" talks
# to the filer - so create the bucket in a retry loop and verify it exists
# rather than assuming. Skipping this is how the first run of this script
# failed: the bucket was never created and the BackupTarget stayed unavailable.
#
# The bare "weed shell" cannot find its own filer, hence the explicit addresses.
weed_shell() {
  kubectl -n "$NS" exec "$POD" -- sh -c \
    "echo '$1' | weed shell -filer=localhost:8888 -master=localhost:9333 2>/dev/null"
}
bucket_ok=0
for i in $(seq 1 30); do
  weed_shell "s3.bucket.create -name longhorn" >/dev/null 2>&1 || true
  if weed_shell "s3.bucket.list" 2>/dev/null | grep -q longhorn; then
    echo "  bucket 'longhorn' exists after $((i * 5))s"
    bucket_ok=1
    break
  fi
  sleep 5
done
[ "$bucket_ok" -eq 1 ] || { echo "  could not create the bucket" >&2; exit 1; }

step "2/7  point Longhorn at it"
kubectl -n longhorn-system create secret generic seaweedfs-backup \
  --from-literal=AWS_ACCESS_KEY_ID=testkey \
  --from-literal=AWS_SECRET_ACCESS_KEY=testsecret \
  --from-literal=AWS_ENDPOINTS="http://seaweedfs.$NS.svc.cluster.local:8333" \
  --from-literal=VIRTUAL_HOSTED_STYLE=false \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Longhorn 1.12 keeps the target in the BackupTarget CR, not in Settings. The
# module variable longhorn_backup_target only takes effect on a FRESH cluster,
# because inline manifests are applied at bootstrap and never reconciled.
kubectl -n longhorn-system patch backuptargets.longhorn.io default --type=merge \
  -p '{"spec":{"backupTargetURL":"s3://longhorn@us-east-1/","credentialSecret":"seaweedfs-backup","pollInterval":"5m0s"}}' >/dev/null
for i in $(seq 1 24); do
  [ "$(kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}')" = true ] \
    && { echo "  available after $((i * 5))s"; break; }
  sleep 5
done
[ "$(kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}')" = true ] \
  || {
    echo "  BackupTarget never becomes available" >&2
    kubectl -n longhorn-system get backuptargets.longhorn.io default \
      -o jsonpath='{"    URL: "}{.spec.backupTargetURL}{"\n    conditions: "}{.status.conditions[*].message}{"\n"}' >&2
    exit 1
  }

step "3/7  a volume with test data"
kubectl apply -f - <<YAML >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: backup-src, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: writer, namespace: $NS}
spec:
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh","-c","sleep 3600"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes:
    - {name: d, persistentVolumeClaim: {claimName: backup-src}}
YAML
kubectl -n "$NS" wait --for=condition=Ready pod/writer --timeout=5m >/dev/null
MARKER="BACKUP-PROOF-$(date +%s)"
kubectl -n "$NS" exec writer -- sh -c "echo '$MARKER' > /data/marker.txt; sync"
VOL=$(kubectl -n "$NS" get pvc backup-src -o jsonpath='{.spec.volumeName}')
echo "  written: $MARKER"
echo "  Volume:      $VOL"

step "4/7  snapshot and backup"
SNAP="snap-$(date +%s)"
kubectl apply -f - <<YAML >/dev/null
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata: {name: $SNAP, namespace: longhorn-system}
spec: {volume: $VOL, createSnapshot: true}
YAML
for _ in $(seq 1 24); do
  [ "$(kubectl -n longhorn-system get snapshots.longhorn.io "$SNAP" -o jsonpath='{.status.readyToUse}')" = true ] && break
  sleep 5
done
BK="bk-$(date +%s)"
kubectl apply -f - <<YAML >/dev/null
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata: {name: $BK, namespace: longhorn-system}
spec: {snapshotName: $SNAP}
YAML
for i in $(seq 1 36); do
  [ "$(kubectl -n longhorn-system get backups.longhorn.io "$BK" -o jsonpath='{.status.state}')" = Completed ] \
    && { echo "  backup completed after $((i * 5))s"; break; }
  sleep 5
done
URL=$(kubectl -n longhorn-system get backups.longhorn.io "$BK" -o jsonpath='{.status.url}')
[ -n "$URL" ] || { echo "  the backup has no URL - it failed" >&2; exit 1; }
echo "  size: $(kubectl -n longhorn-system get backups.longhorn.io "$BK" -o jsonpath='{.status.size}') bytes"

step "5/7  destroy the source"
kubectl -n "$NS" delete pod writer --wait=true >/dev/null
kubectl -n "$NS" delete pvc backup-src --wait=true >/dev/null
for i in $(seq 1 36); do
  kubectl -n longhorn-system get volumes.longhorn.io "$VOL" >/dev/null 2>&1 \
    || { echo "  volume deleted after $((i * 5))s"; break; }
  sleep 5
done
if kubectl -n longhorn-system get volumes.longhorn.io "$VOL" >/dev/null 2>&1; then
  echo "  the volume still exists - the test would be worthless" >&2; exit 1
fi
reps=$(kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r --arg v "$VOL" '[.items[]|select(.spec.volumeName==$v)]|length')
echo "  replicas left: $reps"
[ "$reps" -eq 0 ] || { echo "  replicas are still lying around" >&2; exit 1; }

step "6/7  restore from the backup"
kubectl apply -f - <<YAML >/dev/null
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata: {name: restored-vol, namespace: longhorn-system}
spec:
  size: "1073741824"
  numberOfReplicas: 3
  dataEngine: v1
  frontend: blockdev
  fromBackup: "$URL"
YAML
# restoreRequired reads false before the field is populated at all, so wait for
# a state as well - otherwise this returns instantly and proves nothing.
for i in $(seq 1 60); do
  st=$(kubectl -n longhorn-system get volumes.longhorn.io restored-vol -o jsonpath='{.status.state}' 2>/dev/null)
  rr=$(kubectl -n longhorn-system get volumes.longhorn.io restored-vol -o jsonpath='{.status.restoreRequired}' 2>/dev/null)
  [ -n "$st" ] && [ "$st" != creating ] && [ "$rr" = false ] && { echo "  restore finished after $((i * 5))s (state=$st)"; break; }
  sleep 5
done

step "7/7  compare the content"
kubectl apply -f - <<YAML >/dev/null
apiVersion: v1
kind: PersistentVolume
metadata: {name: restored-pv}
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn-static
  volumeMode: Filesystem
  csi: {driver: driver.longhorn.io, fsType: ext4, volumeHandle: restored-vol}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: backup-restored, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-static
  volumeName: restored-pv
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: reader, namespace: $NS}
spec:
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh","-c","sleep 3600"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes:
    - {name: d, persistentVolumeClaim: {claimName: backup-restored}}
YAML
kubectl -n "$NS" wait --for=condition=Ready pod/reader --timeout=10m >/dev/null
GOT=$(kubectl -n "$NS" exec reader -- cat /data/marker.txt)
echo "  written before the backup: $MARKER"
echo "  read after the restore:     $GOT"
echo
if [ "$MARKER" = "$GOT" ]; then
  echo "BACKUP AND RESTORE PASSED"
else
  echo "MISMATCH - the restore returned different data" >&2
  exit 1
fi
