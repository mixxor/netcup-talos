#!/usr/bin/env bash
# Take a node out of Kubernetes before OpenTofu resets it.
#
# Runs as a destroy-time provisioner, before the machine configuration is
# destroyed - so removing a name from worker_servers and applying is enough,
# with no separate script to remember.
#
# Best effort by design: it never blocks a destroy. A drain that cannot happen
# is announced loudly and skipped, because a teardown that refuses to finish is
# worse than one that killed some pods. Longhorn replication is what actually
# protects the data.
#
# Environment: NODE, KUBECONFIG_PATH, TALOSCONFIG_PATH, NODE_IP, NODE_ROLE.
set -uo pipefail

: "${NODE:?NODE not set}"
export KUBECONFIG="${KUBECONFIG_PATH:-}"

say()  { echo "[$NODE] $*"; }
skip() { say "SKIPPED: $*"; exit 0; }

command -v kubectl >/dev/null 2>&1 || skip "no kubectl on this machine"
[ -r "${KUBECONFIG:-}" ] || skip "no readable kubeconfig"
kubectl version -o json >/dev/null 2>&1 || skip "the Kubernetes API does not answer"
kubectl get node "$NODE" >/dev/null 2>&1 || skip "not a node in this cluster"

# During a full teardown every node is going away, and draining into a shrinking
# cluster achieves nothing. Two Ready nodes is the point where it stops helping.
ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready || echo 0)
[ "${ready:-0}" -ge 2 ] || skip "only $ready node(s) Ready, the cluster is going away"

say "cordon"
kubectl cordon "$NODE" >/dev/null 2>&1 || true

say "drain"
# --force: pods without a controller would block forever, and on a node that is
# about to be wiped nothing would recreate them anyway.
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force \
  --timeout=120s --skip-wait-for-delete-timeout=30 2>&1 | sed "s/^/[$NODE] /" || \
  say "drain did not finish cleanly, continuing"

# Longhorn keeps its own node object. Asking it to evacuate moves the replicas
# off; if there is nowhere to move them it will not, and that is worth saying.
if kubectl get nodes.longhorn.io -n longhorn-system "$NODE" >/dev/null 2>&1; then
  say "evacuating Longhorn replicas"
  kubectl -n longhorn-system patch nodes.longhorn.io "$NODE" --type=merge \
    -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' >/dev/null 2>&1 || true
  for i in $(seq 1 24); do
    left=$(kubectl -n longhorn-system get replicas.longhorn.io -o json 2>/dev/null \
      | jq -r --arg n "$NODE" '[.items[]|select(.spec.nodeID==$n)]|length' 2>/dev/null || echo 0)
    [ "${left:-0}" -eq 0 ] && { say "replicas moved after $((i * 5))s"; break; }
    [ "$i" -eq 24 ] && say "WARNING: $left replica(s) still here - not enough nodes to move them to"
    sleep 5
  done
fi

# etcd wants an odd number of members, and on_destroy is not graceful - that is
# right for a full teardown and wrong for removing one member.
if [ "${NODE_ROLE:-}" = controlplane ] && [ -n "${NODE_IP:-}" ] && [ -n "${TALOSCONFIG_PATH:-}" ]; then
  say "leaving etcd"
  TALOSCONFIG="$TALOSCONFIG_PATH" talosctl -n "$NODE_IP" etcd leave 2>&1 | sed "s/^/[$NODE] /" || \
    say "etcd leave failed, continuing"
fi

say "deleting the node object"
kubectl delete node "$NODE" --wait=false >/dev/null 2>&1 || true

# Only now. Longhorn refuses to drop its own node object while the Kubernetes
# node still exists, and once it is gone Longhorn usually collects it anyway -
# so this is a nudge, and the warning only fires if it really stayed behind.
if kubectl get nodes.longhorn.io -n longhorn-system "$NODE" >/dev/null 2>&1; then
  kubectl -n longhorn-system delete nodes.longhorn.io "$NODE" >/dev/null 2>&1 || true
  sleep 5
  kubectl get nodes.longhorn.io -n longhorn-system "$NODE" >/dev/null 2>&1 && \
    say "Longhorn kept its node object - if this node returns, run netcup/rejoin-node.sh"
fi

say "done"
