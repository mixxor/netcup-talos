#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016 disabled file-wide: the $ expressions inside the 'bash -c' blocks are
# meant to evaluate in the inner shell, not here.
# Health checks across both halves. Every check prints its raw output.
# Exits non-zero as soon as one fails.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The configuration that owns the cluster under test. Override to check a
# second cluster, or your own repo consuming modules/talos-netcup-k8s-cluster.
TOFU_DIR="${TOFU_DIR:-$ROOT/examples/cluster}"
export PATH="$HOME/.local/bin:$PATH"
# shellcheck source=netcup/lib/generated.sh
. "$ROOT/netcup/lib/generated.sh"
GEN="$(gen_dir "$ROOT")" || exit 1
export TALOSCONFIG="$GEN/talosconfig"
export KUBECONFIG="$GEN/kubeconfig"
FAIL=0
declare -a FAILED=()

check() {  # check NAME COMMAND...
  local name="$1"; shift
  echo; echo "=== $name ==="
  if "$@"; then
    echo "--- OK"
  else
    echo "--- FAILED"; FAIL=1; FAILED+=("$name")
  fi
}

# Node lists come from the inventory, not from the cluster, so the first check
# still works when the Kubernetes API does not answer.
set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a
# After sourcing, never before: an older .env carries its own CLUSTER_NAME and
# "set -a" would overwrite this. The credential directory names the cluster.
CLUSTER_NAME="$(basename "$GEN")"
export NC_GEN="$ROOT/generated"
# shellcheck source=netcup/lib/nodes.sh
source "$ROOT/netcup/lib/nodes.sh"
load_nodes || exit 1
# One read for all of them. Separate calls with 2>/dev/null and a default turned
# "outputs unreadable" into "nothing configured", and 0 nodes then passed the
# node count check with 0 == 0.
OUTPUTS=$(cd "$TOFU_DIR" && tofu output -json) || {
  echo "verify.sh: cannot read the outputs of $TOFU_DIR - run tofu apply there first" >&2
  exit 1
}
out() { printf '%s' "$OUTPUTS" | jq -r --arg c "$CLUSTER_NAME" --arg k "$1" '.[$k].value[$c] // empty'; }

COMPONENTS=$(printf '%s' "$OUTPUTS" | jq -c --arg c "$CLUSTER_NAME" '.installed_components.value[$c] // {}')
if [ "$COMPONENTS" = "{}" ]; then
  echo "verify.sh: no cluster named '$CLUSTER_NAME' in the outputs of $TOFU_DIR" >&2
  printf '%s' "$OUTPUTS" | jq -r '.installed_components.value | keys[] | "  " + .' >&2
  exit 1
fi

LH_REPLICAS=$(out longhorn_replica_counts); LH_REPLICAS="${LH_REPLICAS:-3}"
CLUSTER_DOMAIN=$(out cluster_domains)
# First load balancer, if any. The end-to-end check goes through one of them;
# that both answer is what the DNS records are for.
LB_IP=$(printf '%s' "$OUTPUTS" | jq -r --arg c "$CLUSTER_NAME" '.loadbalancer_ips.value[$c][0] // empty')
LB_API=$(out loadbalancer_serves_api); LB_API="${LB_API:-false}"

NODES_JSON=$(printf '%s' "$OUTPUTS" | jq -c --arg c "$CLUSTER_NAME" '.nodes.value[$c] // {}')
NODES_TOTAL=$(printf '%s' "$NODES_JSON" | jq 'length')
NODES_CP=$(printf '%s' "$NODES_JSON" | jq '[.[] | select(.role=="controlplane")] | length')
NODES_WORKERS=$(printf '%s' "$NODES_JSON" | jq '[.[] | select(.role=="worker")] | length')
if [ "$NODES_TOTAL" -eq 0 ]; then
  echo "verify.sh: the nodes output for '$CLUSTER_NAME' is empty" >&2
  exit 1
fi
echo "Checking $CLUSTER_NAME: $NODES_TOTAL nodes, $NODES_CP control plane, components $COMPONENTS"

# Straight after an apply the API is not answering yet and half of kube-system
# is Pending, so the checks below would report the clock. "kubectl wait" alone
# does not help: against an apiserver that is still starting it returns
# "connection refused" in a second and the timeout never applies.
settle() {
  local budget="${VERIFY_SETTLE:-900}" deadline start
  [ "$budget" = "0" ] && return 0
  start=$(date +%s)
  deadline=$((start + budget))

  local ready pods pending waited nodes
  while :; do
    waited=$(( $(date +%s) - start ))
    # Count what IS Ready: right after the bootstrap kubectl returns no nodes,
    # and zero not-Ready nodes would read as settled.
    if kubectl get --raw /readyz >/dev/null 2>&1; then
      nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c . || true)
      ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | grep -c . || true)
      # Every namespace: Longhorn, Traefik and ArgoCD take longer than the CNI.
      pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c . || true)
      pending=$(kubectl get pods -A --no-headers 2>/dev/null \
        | awk '$4 != "Running" && $4 != "Completed"' | grep -c . || true)
      if [ "${ready:-0}" -eq "$NODES_TOTAL" ] && [ "${nodes:-0}" -eq "$NODES_TOTAL" ] \
         && [ "${pods:-0}" -gt 0 ] && [ "${pending:-1}" -eq 0 ]; then
        echo "Settled after ${waited}s"
        return 0
      fi
    else
      ready="?"; pending="?"
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Not settled within ${budget}s (Ready nodes: ${ready:-?}/$NODES_TOTAL, pods not Running: ${pending:-?}) - checking anyway"
      kubectl get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed"' >&2 || true
      return 0
    fi
    sleep 10
  done
}
echo "Waiting up to ${VERIFY_SETTLE:-900}s for the cluster to settle"
settle

have() { printf '%s' "$COMPONENTS" | jq -e --arg k "$1" '.[$k] == true' >/dev/null 2>&1; }

skip() {
  echo; echo "=== $1 ==="
  echo "--- SKIPPED ($2 is not configured)"
}

CP_LIST=$(IFS=,; ids=(); for i in "${CP_IDS[@]}"; do ids+=("${NODE_IP[$i]}"); done; echo "${ids[*]}")
WK_LIST=$(IFS=,; ids=(); for i in "${WORKER_IDS[@]}"; do ids+=("${NODE_IP[$i]}"); done; echo "${ids[*]}")
CP1="${NODE_IP[${CP_IDS[0]}]}"

# With a load balancer the name points at one address, without it at every
# control plane. The check follows whichever is configured.
# Without a domain there is nothing to resolve: the endpoint is a control plane
# IP. Asking dig for the empty string returns the root servers, which used to
# be reported as a failed DNS check.
if [ -z "$CLUSTER_DOMAIN" ]; then
  skip "DNS" "cluster_domain"
elif [ "$LB_API" = true ] && [ -n "$LB_IP" ]; then
check "DNS: $CLUSTER_DOMAIN points at the load balancer" bash -c '
  got=$(dig +short A '"$CLUSTER_DOMAIN"' | sort | tee /dev/stderr)
  echo "  expected: '"$LB_IP"'" >&2
  echo "$got" | grep -qx "'"$LB_IP"'"'
else
check "DNS: one A record per control plane (client-side failover)" bash -c '
  dig +short A '"$CLUSTER_DOMAIN"' | sort | tee /dev/stderr >/dev/null
  [ "$(dig +short A '"$CLUSTER_DOMAIN"' | grep -c .)" -eq '"$NODES_CP"' ]'
fi

# talosctl health takes exactly one --nodes value and wants the roles spelled
# out; the talosconfig holds all of them.
check "Talos: cluster health" \
  talosctl health --nodes "$CP1" \
    --control-plane-nodes "$CP_LIST" --worker-nodes "$WK_LIST" \
    --wait-timeout 10m

check "etcd: $NODES_CP members" bash -c "
  talosctl etcd members --nodes $CP1 | tee /dev/stderr | tail -n +2 | grep -c . | grep -qx $NODES_CP"

check "Kubernetes: every declared node Ready" bash -c '
  want="'"$NODES_TOTAL"'"
  out=$(kubectl get nodes -o wide); echo "$out"
  have=$(echo "$out" | tail -n +2 | grep -cw Ready)
  echo "  declared: $want, Ready: $have"
  [ "$have" -eq "$want" ]'

check "Kubernetes: control plane count matches" bash -c '
  want="'"$NODES_CP"'"
  have=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | grep -c .)
  echo "  declared: $want, found: $have"
  [ "$have" -eq "$want" ]'

check "kube-system: no CrashLoops" bash -c '
  out=$(kubectl -n kube-system get pods); echo "$out"
  ! echo "$out" | grep -qE "CrashLoopBackOff|Error|ImagePull"'

if have cilium; then
check "Cilium: WireGuard active" bash -c '
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status \
    | grep -iE "^(Encryption|KubeProxyReplacement)" | tee /dev/stderr \
    | grep -qi "Encryption:.*Wireguard"'

# Peers are all other nodes, so node count minus one.
check "Cilium: every other node is an encrypted peer" bash -c '
  n=$(kubectl get nodes --no-headers | grep -c .)
  want=$((n - 1))
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status \
    | grep -i "^Encryption" | tee /dev/stderr | grep -q "Peers: $want"
  rc=$?
  echo "  nodes: $n, expected peers: $want" >&2
  exit $rc'

if [ "$NODES_WORKERS" -lt 2 ]; then
  skip "Cilium: pod to pod across nodes" "a second worker"
else
check "Cilium: pod to pod across nodes" bash -c '
  # Unique names per run. Fixed ones made this flaky: the cleanup does not wait,
  # so a second run within seconds hit "already exists", created nothing, and
  # then failed on an empty pod IP.
  a="xping-a-$$"; b="xping-b-$$"
  trap "kubectl delete pod $a $b --ignore-not-found --wait=false >/dev/null 2>&1" EXIT
  read -r -a W <<< "$(kubectl get nodes -l "!node-role.kubernetes.io/control-plane" -o jsonpath="{.items[*].metadata.name}")"
  [ "${#W[@]}" -ge 2 ] || { echo "  needs two workers, found ${#W[@]}" >&2; exit 1; }
  kubectl run "$a" --image=busybox:1.36 --overrides="{\"spec\":{\"nodeName\":\"${W[0]}\"}}" --restart=Never -- sleep 300 >/dev/null 2>&1
  kubectl run "$b" --image=busybox:1.36 --overrides="{\"spec\":{\"nodeName\":\"${W[1]}\"}}" --restart=Never -- sleep 300 >/dev/null 2>&1
  kubectl wait --for=condition=Ready "pod/$a" "pod/$b" --timeout=3m >/dev/null 2>&1 || { echo "  test pods never became Ready" >&2; exit 1; }
  IP=""
  for _ in 1 2 3 4 5; do
    IP=$(kubectl get pod "$b" -o jsonpath="{.status.podIP}" 2>/dev/null) && [ -n "$IP" ] && break
    sleep 3
  done
  [ -n "$IP" ] || { echo "  no pod IP for $b" >&2; exit 1; }
  kubectl exec "$a" -- ping -c 3 -W 3 "$IP" 2>&1 | tail -3 | tee /dev/stderr | grep -q "0% packet loss"'
fi

else
  skip "Cilium" "cilium"
fi

if have longhorn; then
check "Longhorn: StorageClass is default" bash -c '
  kubectl get storageclass | tee /dev/stderr | grep -q "longhorn (default)"'

check "Longhorn: nothing on the control plane" bash -c '
  CP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath="{.items[*].metadata.name}")
  total=0
  for n in $CP; do
    c=$(kubectl -n longhorn-system get pods --field-selector "spec.nodeName=$n" --no-headers 2>/dev/null | grep -c .)
    echo "  $n: $c Pods" >&2
    total=$((total + c))
  done
  [ "$total" -eq 0 ]'

check "Longhorn: write, read, $LH_REPLICAS replicas" bash -c '
  kubectl delete pod/vtest pvc/vtest --ignore-not-found >/dev/null 2>&1
  kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: vtest, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: vtest, namespace: default }
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh","-c","echo VERIFY-OK > /data/f && sync && cat /data/f && sleep 120"]
      volumeMounts: [{ name: v, mountPath: /data }]
  volumes: [{ name: v, persistentVolumeClaim: { claimName: vtest } }]
EOF
  kubectl wait --for=condition=Ready pod/vtest --timeout=5m >/dev/null 2>&1
  kubectl logs vtest 2>&1 | tee /dev/stderr | grep -q VERIFY-OK && \
  [ "$(kubectl -n longhorn-system get replicas.longhorn.io --no-headers 2>/dev/null | grep -c .)" -ge '"$LH_REPLICAS"' ]
  rc=$?
  kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NODE:.spec.nodeID --no-headers 2>/dev/null | sort >&2
  kubectl delete pod/vtest pvc/vtest --ignore-not-found >/dev/null 2>&1
  exit $rc'

else
  skip "Longhorn" "longhorn"
fi

check "Firewall: default-deny on every node" bash -c '
  set -a; . "'"$ROOT"'/.env"; set +a
  export NC_GEN="'"$ROOT"'/generated"
  . "'"$ROOT"'/netcup/lib/netcup.sh"
  CLUSTER="'"$CLUSTER_NAME"'" . "'"$ROOT"'/netcup/lib/nodes.sh"; CLUSTER="'"$CLUSTER_NAME"'" load_nodes
  ok=1
  for id in "${NODE_IDS[@]}"; do
    r=$(nc_api GET "/api/v1/servers/$id/interfaces/${NODE_MAC[$id]}/firewall" \
        | jq -r "[.ingressImplicitRule, .egressImplicitRule, (.userPolicies[0].name // \"-\")] | @tsv")
    echo "  ${NODE_NAME[$id]}  $r" >&2
    echo "$r" | grep -q "DROP_ALL.*DROP_ALL.*'"$CLUSTER_NAME"'" || ok=0
  done
  [ "$ok" -eq 1 ]'

check "Firewall works: an unrelated port is closed from outside" bash -c '
  # 10250 (kubelet) must only be reachable from node IPs, not from here. The
  # address comes from the inventory rather than from DNS: the cluster does not
  # need a domain, so this check must not either.
  IP="'"$CP1"'"
  echo "  probing $IP:10250 from the admin IP - expecting no connect" >&2
  if nc -z -w 5 "$IP" 10250 2>/dev/null; then echo "  REACHABLE - the rule is not working" >&2; false
  else echo "  not reachable, correct" >&2; true; fi'

if have metrics_server; then
# A UDP accept without a destination port opens every UDP port to anyone who
# sets the right source port - Cilium's unauthenticated VXLAN included.
check "Firewall: no UDP rule opens every port" bash -c '
  set -a; . "'"$ROOT"'/.env"; set +a
  export NC_GEN="'"$ROOT"'/generated"
  . "'"$ROOT"'/netcup/lib/netcup.sh"
  pol=$(nc_api GET "/api/v1/users/$NETCUP_USER_ID/firewall-policies" \
    | jq -r --arg n "'"$CLUSTER_NAME"'" ".[] | select(.name == \$n) | .id")
  [ -n "$pol" ] || { echo "  no policy named '"$CLUSTER_NAME"'" >&2; exit 1; }
  wide=$(nc_api GET "/api/v1/users/$NETCUP_USER_ID/firewall-policies/$pol" \
    | jq -r ".rules[] | select(.direction=="INGRESS" and .protocol=="UDP" and .action=="ACCEPT")
             | select((.destinationPorts // "") == "")
             | .description")
  if [ -n "$wide" ]; then
    echo "  UDP rules with no destination port:" >&2; echo "$wide" >&2; exit 1
  fi
  echo "  every UDP accept names a destination port" >&2'

check "metrics-server: APIService available" bash -c '
  out=$(kubectl get apiservice v1beta1.metrics.k8s.io \
        -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}")
  echo "  v1beta1.metrics.k8s.io Available=$out"
  [ "$out" = "True" ]'

else
  skip "metrics-server" "metrics_server"
fi

if have traefik; then
check "Traefik: DaemonSet on every worker" bash -c '
  kubectl -n traefik get ds traefik \
    -o custom-columns=DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady --no-headers | tee /dev/stderr
  read -r want ready < <(kubectl -n traefik get ds traefik \
    -o jsonpath="{.status.desiredNumberScheduled} {.status.numberReady}")
  [ -n "$want" ] && [ "$want" -gt 0 ] && [ "$want" = "$ready" ]'

# The real proof: from this machine, across the open internet,
# through the netcup firewall onto a worker hostPort 80. The Host header
# replaces DNS here - this is about reachability, not name resolution.
check "Traefik: reachable from outside, end to end" bash -c '
  ns=ingress-check-$$
  trap "kubectl delete ns $ns --wait=false >/dev/null 2>&1 || true" EXIT
  kubectl create ns "$ns" >/dev/null
  kubectl -n "$ns" create deployment echo --image=hashicorp/http-echo \
    -- /http-echo -listen=:5678 -text=INGRESS-OK >/dev/null
  kubectl -n "$ns" expose deployment echo --port=80 --target-port=5678 >/dev/null
  kubectl -n "$ns" create ingress echo --class=traefik \
    --rule="ingress-check.example.com/*=echo:80" >/dev/null
  kubectl -n "$ns" rollout status deploy/echo --timeout=3m >/dev/null

  # With a load balancer the direct path to a worker is firewalled off, which
  # is the point - so test through it.
  target='"${LB_IP:-}"'
  if [ -z "$target" ]; then
    target=$(kubectl get nodes -l "!node-role.kubernetes.io/control-plane" \
      -o jsonpath="{.items[0].status.addresses[?(@.type==\"InternalIP\")].address}")
    echo "  target: worker directly" >&2
  else
    echo "  target: through the load balancer" >&2
  fi
  worker="$target"
  echo "  http://$worker/ mit Host ingress-check.example.com"

  for _ in $(seq 1 30); do
    body=$(curl -sS --max-time 5 -H "Host: ingress-check.example.com" "http://$worker/" 2>/dev/null || true)
    case "$body" in *INGRESS-OK*) break ;; esac
    sleep 2
  done
  echo "  response: ${body:-<empty>}"
  case "${body:-}" in *INGRESS-OK*) exit 0 ;; *) exit 1 ;; esac'

else
  skip "Traefik" "traefik"
fi

# kubectl top needs metrics-server; without it the number comes from Talos.
if have metrics_server; then
check "RAM headroom against the 4 GB limit" bash -c '
  out=$(kubectl top nodes) || exit 1
  echo "$out"
  # No node above 80% - at 3896 MB there is no room left above that
  # for workloads.
  worst=$(echo "$out" | tail -n +2 | awk "{gsub(/%/,\"\",\$5); print \$5}" | sort -n | tail -1)
  echo "  hoechste RAM-Auslastung: ${worst}%"
  [ "${worst:-100}" -lt 80 ]'
else
check "RAM headroom (via talosctl, no metrics-server)" bash -c '
  talosctl memory | tee /dev/stderr | tail -n +2 | awk "{ if (\$3/\$2 > 0.8) bad=1 } END { exit bad+0 }"'
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "FAILED: ${FAILED[*]}"
fi
exit "$FAIL"
