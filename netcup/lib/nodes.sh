#!/usr/bin/env bash
# shellcheck disable=SC2034
# SC2034 disabled file-wide: NODE_* and *_IDS are read exclusively by the
# scripts that source this file, never in here.
#
# Node inventory. The single source of truth is the OpenTofu "nodes" output,
# which in turn is discovered from the netcup API - so there is no second copy
# to drift.
NC_GEN="${NC_GEN:-$PWD/generated}"

if [ -z "${BASH_VERSION:-}" ]; then
  echo "nodes.sh requires bash (associative arrays)." >&2
  # shellcheck disable=SC2317  # reachable when the file is executed instead of sourced
  return 1 2>/dev/null || exit 1
fi

declare -A NODE_IP NODE_MAC NODE_ROLE NODE_NAME NODE_SRV
declare -a NODE_IDS CP_IDS WORKER_IDS

load_nodes() {
  local root json dir
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  # The configuration that owns the live cluster. Override TOFU_DIR to point the
  # day-2 scripts at a different root - a second cluster, or your own repo that
  # consumes modules/talos-netcup-k8s-cluster.
  dir="${TOFU_DIR:-$root/examples/cluster}"

  if ! json=$(cd "$dir" && tofu output -json nodes 2>/dev/null) || [ -z "$json" ] || [ "$json" = "null" ]; then
    echo "nodes.sh: could not read the 'nodes' output from $dir." >&2
    echo "Run 'cd $dir && tofu apply' first, or set TOFU_DIR." >&2
    return 1
  fi

  # The output is keyed by cluster name, because one configuration can build
  # several. CLUSTER picks one; with exactly one there is nothing to pick.
  local count
  count=$(printf '%s' "$json" | jq 'length')
  if [ -n "${CLUSTER:-}" ]; then
    json=$(printf '%s' "$json" | jq -c --arg c "$CLUSTER" '.[$c] // {}')
    if [ "$(printf '%s' "$json" | jq 'length')" -eq 0 ]; then
      echo "nodes.sh: no cluster named '$CLUSTER' in the 'nodes' output of $dir" >&2
      return 1
    fi
  elif [ "$count" -eq 1 ]; then
    json=$(printf '%s' "$json" | jq -c '.[]')
  else
    echo "nodes.sh: $count clusters in $dir - set CLUSTER to pick one:" >&2
    printf '%s' "$json" | jq -r 'keys[] | "  " + .' >&2
    return 1
  fi

  NODE_IDS=(); CP_IDS=(); WORKER_IDS=()
  local line label id ip mac role name
  while IFS=$'\t' read -r label id ip mac role name; do
    [ -n "$id" ] || continue
    NODE_IDS+=("$id")
    NODE_NAME["$id"]="$label"; NODE_IP["$id"]="$ip"
    NODE_MAC["$id"]="$mac";    NODE_ROLE["$id"]="$role"
    NODE_SRV["$id"]="$name"
    if [ "$role" = "controlplane" ]; then CP_IDS+=("$id"); else WORKER_IDS+=("$id"); fi
  done < <(printf '%s' "$json" | jq -r 'to_entries[] | [.key, (.value.id|tostring), .value.ip, .value.mac, .value.role, .value.name] | @tsv' | sort)

  if [ "${#NODE_IDS[@]}" -eq 0 ]; then
    echo "nodes.sh: the 'nodes' output is empty" >&2
    return 1
  fi
}
