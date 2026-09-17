#!/usr/bin/env bash
# Counterpart to remove-node.sh: clears the flags that removal left behind.
#
# Adding a server back to worker_servers and applying gets the node into the
# cluster, but Longhorn remembers its own node object across the absence -
# including allowScheduling=false and evictionRequested=true from the removal.
# Without clearing those the node rejoins Kubernetes and stays useless to
# Longhorn, and volumes remain degraded.
#
# Usage: rejoin-node.sh <node>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
# shellcheck source=lib/generated.sh
. "$ROOT/netcup/lib/generated.sh"
GEN="$(gen_dir "$ROOT")" || exit 1
export KUBECONFIG="${KUBECONFIG:-$GEN/kubeconfig}"

NODE="${1:-}"
[ -n "$NODE" ] || { echo "usage: rejoin-node.sh <node>" >&2; exit 2; }

kubectl get node "$NODE" >/dev/null 2>&1 || {
  echo "no such node: $NODE - is it in terraform.tfvars and applied?" >&2
  exit 1
}

echo "== uncordon =="
kubectl uncordon "$NODE"

if kubectl get nodes.longhorn.io -n longhorn-system "$NODE" >/dev/null 2>&1; then
  echo "== re-enabling Longhorn scheduling =="
  kubectl -n longhorn-system patch nodes.longhorn.io "$NODE" --type=merge \
    -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}'

  echo "== waiting for volumes to become healthy again =="
  for i in $(seq 1 60); do
    bad=$(kubectl -n longhorn-system get volumes.longhorn.io \
      -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' 2>/dev/null \
      | grep -cv '^healthy$' || true)
    [ "${bad:-0}" -eq 0 ] && { echo "   all volumes healthy after $((i * 10))s"; break; }
    [ $((i % 6)) -eq 0 ] && echo "   $bad volumes still not healthy"
    sleep 10
  done
fi

echo
echo "Volumes that are detached stay 'unknown' until something mounts them -"
echo "that is not a fault. Attach one and Longhorn rebuilds the missing replica."
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness --no-headers 2>/dev/null || true
