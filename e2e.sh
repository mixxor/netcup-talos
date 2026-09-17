#!/usr/bin/env bash
# Build every preset for real, check it, tear it down, move on.
#
# This is the test the static checks cannot be: a preset can name every
# attribute correctly and still produce a cluster that never becomes Ready. It
# costs time and hammers the netcup API, so it is not part of test.sh.
#
#   bash e2e.sh                          # every preset, in order
#   bash e2e.sh gitops two-clusters      # only these
#   E2E_KEEP=1 bash e2e.sh gitops        # leave it standing for a look
#
# Servers are taken from the account by nickname: anything without one is free.
# A run refuses to start if a preset needs more than are free, and it never
# touches a server that belongs to a cluster.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=netcup/lib/netcup.sh
. "$ROOT/netcup/lib/netcup.sh"
# The API client reads NETCUP_*, OpenTofu wants TF_VAR_*. env.sh exports both
# from .env, so the script works without anything being sourced beforehand.
# shellcheck source=netcup/env.sh
. "$ROOT/netcup/env.sh" >/dev/null

SRC="$ROOT/examples/cluster"
# A sibling of examples/cluster, so "../../modules" still resolves and the
# example's own terraform.tfvars stays out of it.
RUN="$ROOT/examples/e2e-run"
KEEP="${E2E_KEEP:-0}"

PRESETS=("$@")
if [ ${#PRESETS[@]} -eq 0 ]; then
  PRESETS=(minimal complete gitops two-clusters)
fi

say() { echo; echo "=============== $* ==============="; }

preset_file() {
  case "$1" in
    minimal) echo "$SRC/terraform.tfvars.example" ;;
    *) echo "$SRC/presets/$1.tfvars" ;;
  esac
}

# Free servers: no nickname. A nickname means some cluster claims it, and the
# module would refuse it anyway.
free_servers() {
  nc_api GET "/api/v1/servers" | jq -r '.[] | select((.nickname // "") == "") | .name'
}

# By id, not by name: a name returns HTTP 400 and an empty jq result, which
# reads exactly like a cleared nickname.
server_info() {
  nc_api GET "/api/v1/servers/$1"
}

server_id_of() {
  nc_api GET "/api/v1/servers" | jq -r --arg n "$1" '.[] | select(.name == $n) | .id'
}

# Replace the placeholder names in a preset with real ones, in the order they
# first appear. Keeps the preset itself free of anybody's server names.
materialise() {
  local src="$1" dst="$2"; shift 2
  local -a real=("$@")
  local -a placeholders
  mapfile -t placeholders < <(grep -o 'v2202[0-9]\{15\}' "$src" | awk '!seen[$0]++')

  if [ ${#placeholders[@]} -gt ${#real[@]} ]; then
    echo "  needs ${#placeholders[@]} servers, ${#real[@]} free" >&2
    return 1
  fi

  cp "$src" "$dst"
  local i=0
  for ph in "${placeholders[@]}"; do
    # BSD and GNU sed disagree about -i, so write through a temporary file.
    sed "s/$ph/${real[$i]}/g" "$dst" > "$dst.tmp" && mv "$dst.tmp" "$dst"
    i=$((i + 1))
  done
  printf '%s\n' "${placeholders[@]}"
}

cluster_names() {
  tofu -chdir="$RUN" output -json cluster_endpoints 2>/dev/null | jq -r 'keys[]' 2>/dev/null
}

teardown() {
  [ -d "$RUN" ] || return 0
  echo "--- destroying"
  tofu -chdir="$RUN" destroy -auto-approve -no-color -var-file="$RUN/run.tfvars"
}

FAILED=()
run_preset() {
  local name="$1" src
  src="$(preset_file "$name")"
  say "$name"

  if [ ! -f "$src" ]; then
    echo "  no such preset: $src"; return 1
  fi

  local -a free
  mapfile -t free < <(free_servers)
  echo "  free servers: ${#free[@]}"

  rm -rf "$RUN"
  mkdir -p "$RUN"
  cp "$SRC"/*.tf "$RUN/"

  # materialise prints the placeholders it replaced, one per line. A process
  # substitution swallows its exit code, so an empty result is the failure.
  local -a used
  mapfile -t used < <(materialise "$src" "$RUN/run.tfvars" "${free[@]}")
  if [ ${#used[@]} -eq 0 ]; then
    echo "  could not fill in the server names"
    return 1
  fi
  local -a servers=("${free[@]:0:${#used[@]}}")
  echo "  using: ${servers[*]}"

  tofu -chdir="$RUN" init -no-color -input=false >/dev/null || return 1

  echo "--- applying"
  tofu -chdir="$RUN" apply -auto-approve -no-color -var-file="$RUN/run.tfvars" || {
    echo "  APPLY FAILED"; teardown; return 1
  }

  local rc=0 c
  for c in $(cluster_names); do
    echo "--- verifying $c"
    CLUSTER="$c" TOFU_DIR="$RUN" bash "$ROOT/verify.sh" || { echo "  VERIFY FAILED for $c"; rc=1; }
  done

  if [ "$KEEP" = "1" ] && [ "$rc" -eq 0 ]; then
    echo "  E2E_KEEP=1, leaving it standing. Destroy with:"
    echo "    tofu -chdir=$RUN destroy -var-file=$RUN/run.tfvars"
    return 0
  fi

  teardown || { echo "  DESTROY FAILED"; return 1; }

  # What a plan cannot tell you: a server that keeps its nickname blocks every
  # future cluster.
  echo "--- after the destroy"
  local id info st nick
  for s in "${servers[@]}"; do
    id="$(server_id_of "$s")"
    if [ -z "$id" ]; then
      echo "  $s: could not resolve the server id - not checked"
      rc=1
      continue
    fi
    info="$(server_info "$id")"
    st="$(printf '%s' "$info" | jq -r '.serverLiveInfo.state // ""')"
    nick="$(printf '%s' "$info" | jq -r '.nickname // ""')"
    if [ -z "$st" ]; then
      echo "  $s (id $id): no state in the API response - not checked"
      rc=1
      continue
    fi
    printf '  %-22s id=%-7s state=%-8s nickname=%s\n' "$s" "$id" "$st" "${nick:--}"
    [ "$st" = "SHUTOFF" ] || { echo "    still running"; rc=1; }
    [ -z "$nick" ] || { echo "    nickname not cleared - blocks the next cluster"; rc=1; }
  done

  return "$rc"
}

trap 'echo; echo "interrupted - tearing down"; teardown; exit 130' INT TERM

for p in "${PRESETS[@]}"; do
  if run_preset "$p"; then
    echo "--- $p OK"
  else
    echo "--- $p FAILED"
    FAILED+=("$p")
  fi
done

say "summary"
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "every preset built, verified and destroyed cleanly: ${PRESETS[*]}"
  exit 0
fi
echo "failed: ${FAILED[*]}"
exit 1
