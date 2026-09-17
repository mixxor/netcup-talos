#!/usr/bin/env bash
# Rolling Talos upgrade, one node at a time.
#
# This is deliberately NOT part of "tofu apply". Changing machine.install.image
# does nothing to a running node - that field only decides what a future install
# writes. A Talos upgrade replaces the running system in place and keeps STATE
# and EPHEMERAL, which is exactly what a reinstall would destroy.
#
# The provider offers no upgrade resource (machine_secrets, machine_configuration_apply,
# machine_bootstrap, cluster_kubeconfig, image_factory_schematic - that is all),
# so this is talosctl.
#
# Usage:
#   upgrade-talos.sh                 # to the version in tofu (var.talos_version)
#   upgrade-talos.sh v1.15.0         # to a specific version
#   upgrade-talos.sh --check         # only show what is running where
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOFU_DIR="${TOFU_DIR:-$ROOT/examples/cluster}"
export PATH="$HOME/.local/bin:$PATH"
# shellcheck source=lib/generated.sh
. "$ROOT/netcup/lib/generated.sh"
GEN="$(gen_dir "$ROOT")" || exit 1
export TALOSCONFIG="${TALOSCONFIG:-$GEN/talosconfig}"
set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a
export TF_VAR_netcup_refresh_token="$NETCUP_REFRESH_TOKEN"
export NC_GEN="$ROOT/generated"
# shellcheck source=lib/nodes.sh
source "$HERE/lib/nodes.sh"
load_nodes

CHECK_ONLY=0
WANTED=""
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  "")      ;;
  -*)      echo "unknown option: $1" >&2; exit 2 ;;
  *)       WANTED="$1" ;;
esac

installer=$(cd "$TOFU_DIR" && tofu output -json installer_image | jq -r --arg c "$(basename "$GEN")" '.[$c] // empty')
[ -n "$installer" ] || { echo "no installer_image output for $(basename "$GEN") - run 'cd examples/cluster && tofu apply' first" >&2; exit 1; }
if [ -n "$WANTED" ]; then
  # Keep the schematic, swap the version tag.
  installer="${installer%:*}:$WANTED"
fi
target="${installer##*:}"

echo "target:    $target"
echo "installer: $installer"
echo

running_version() {  # running_version IP
  talosctl version --nodes "$1" 2>/dev/null \
    | awk '/^Server:/{f=1} f&&/Tag:/{print $2; exit}'
}

echo "== current =="
for id in "${NODE_IDS[@]}"; do
  printf '  %-10s %-16s %s\n' "${NODE_NAME[$id]}" "${NODE_IP[$id]}" "$(running_version "${NODE_IP[$id]}")"
done
[ "$CHECK_ONLY" -eq 1 ] && exit 0

# Workers first, control plane last: a worker going down costs capacity, a
# control plane node costs an etcd member. Within the control plane it is one at
# a time by definition of this loop.
declare -a ORDER=("${WORKER_IDS[@]}" "${CP_IDS[@]}")

echo
for id in "${ORDER[@]}"; do
  ip="${NODE_IP[$id]}"
  label="${NODE_NAME[$id]}"
  have=$(running_version "$ip")

  if [ "$have" = "$target" ]; then
    echo "[$label] already on $target, skipping"
    continue
  fi

  echo "[$label] $have -> $target"
  # --wait blocks until the node is back and healthy. Talos keeps STATE and
  # EPHEMERAL, so Longhorn replicas and etcd data survive.
  talosctl upgrade --nodes "$ip" --image "$installer" --wait

  echo "[$label] waiting for the node to be Ready again"
  if [ -f "$GEN/kubeconfig" ]; then
    KUBECONFIG="$GEN/kubeconfig" kubectl wait --for=condition=Ready \
      "node/$label" --timeout=10m || true
  fi
  echo "[$label] done"
  echo
done

echo "== after =="
for id in "${NODE_IDS[@]}"; do
  printf '  %-10s %-16s %s\n' "${NODE_NAME[$id]}" "${NODE_IP[$id]}" "$(running_version "${NODE_IP[$id]}")"
done

echo
echo "Now set talos_version = \"$target\" in examples/cluster/terraform.tfvars so that a future"
echo "reinstall writes the same version. Applying that changes machine.install.image"
echo "only - it does not touch the running nodes."
