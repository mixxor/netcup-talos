#!/usr/bin/env bash
# etcd snapshot of the running cluster.
#
# This is the one backup without which nothing else matters. Longhorn replicas
# protect a volume against losing a node; they do not protect the cluster
# against losing etcd quorum. Lose two of three control plane nodes and the
# cluster is gone - every Deployment, Secret, PVC binding and CRD with it.
#
# Talos takes the snapshot itself over the API; no etcdctl, no exec into a pod.
# The snapshot is a consistent point-in-time copy of the whole key space.
#
# Usage:
#   backup-etcd.sh                    # snapshot into generated/<cluster>/etcd-backups/
#   backup-etcd.sh --dir /some/where  # somewhere else
#   backup-etcd.sh --keep 30          # retention, default 14
#   backup-etcd.sh --list             # what is there
#
# Off-box copies: set BACKUP_S3_BUCKET (plus BACKUP_S3_ENDPOINT for anything
# that is not AWS) and the script uploads with the aws CLI. Without it the
# snapshot stays local - which is not a backup, only a copy, see README.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOFU_DIR="${TOFU_DIR:-$ROOT/examples/cluster}"
export PATH="$HOME/.local/bin:$PATH"
# shellcheck source=lib/generated.sh
. "$ROOT/netcup/lib/generated.sh"
GEN="$(gen_dir "$ROOT")" || exit 1
export TALOSCONFIG="${TALOSCONFIG:-$GEN/talosconfig}"
export NC_GEN="$ROOT/generated"

DIR="$GEN/etcd-backups"
KEEP=14
LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)  DIR="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$LIST" -eq 1 ]; then
  command ls -lh "$DIR" 2>/dev/null || echo "no snapshots in $DIR"
  exit 0
fi

# shellcheck source=lib/nodes.sh
source "$HERE/lib/nodes.sh"
load_nodes

# Any control plane node can serve the snapshot - etcd is replicated. Take the
# first one that actually answers, so a single dead node does not stop a backup.
node=""
for id in "${CP_IDS[@]}"; do
  if talosctl -n "${NODE_IP[$id]}" etcd members >/dev/null 2>&1; then
    node="${NODE_IP[$id]}"
    echo "snapshot from ${NODE_NAME[$id]} (${NODE_IP[$id]})"
    break
  fi
  echo "  ${NODE_NAME[$id]} does not answer, trying the next one" >&2
done
[ -n "$node" ] || { echo "no control plane node answered" >&2; exit 1; }

mkdir -p "$DIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$DIR/etcd-$stamp.snapshot"

talosctl -n "$node" etcd snapshot "$out"

# A truncated snapshot restores into a broken cluster, so check it here rather
# than find out during an outage. An etcd snapshot is a bbolt database and
# starts with the magic 0xED0CDAED in its meta page.
[ -s "$out" ] || { echo "snapshot is empty" >&2; rm -f "$out"; exit 1; }
magic=$(od -An -tx4 -N4 -j16 "$out" | tr -d ' \n')
[ "$magic" = "ed0cdaed" ] || { echo "not a bbolt database (magic $magic)" >&2; rm -f "$out"; exit 1; }
size=$(du -h "$out" | cut -f1)
echo "  ok: $out ($size, bbolt magic verified)"

if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
  if command -v aws >/dev/null 2>&1; then
    args=(s3 cp "$out" "s3://$BACKUP_S3_BUCKET/etcd/$(basename "$out")")
    [ -n "${BACKUP_S3_ENDPOINT:-}" ] && args+=(--endpoint-url "$BACKUP_S3_ENDPOINT")
    echo "uploading to s3://$BACKUP_S3_BUCKET/etcd/"
    aws "${args[@]}"
  else
    echo "BACKUP_S3_BUCKET is set but the aws CLI is missing - snapshot stays local" >&2
  fi
fi

# Retention. Sorted by name, which is sorted by timestamp because the stamp is
# ISO 8601 in UTC.
mapfile -t all < <(command ls -1 "$DIR"/etcd-*.snapshot 2>/dev/null | sort)
if [ "${#all[@]}" -gt "$KEEP" ]; then
  drop=$(( ${#all[@]} - KEEP ))
  echo "retention: $drop of ${#all[@]} snapshots removed, keeping $KEEP"
  for f in "${all[@]:0:$drop}"; do rm -f "$f"; echo "  removed $(basename "$f")"; done
fi
