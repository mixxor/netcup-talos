#!/usr/bin/env bash
# Reclaims storage reserved on the host side.
#
# Reinstalling repeatedly grows the reserved allocation and never shrinks it:
# measured from 2 GiB per node to 16-22 GiB after three rounds, whatever the
# guest actually uses. requiredStorageOptimization then flips from NO to FAST.
#
# CAREFUL: optimising deletes every snapshot of the server. Anyone keeping them as
#
# Measured: the FAST level takes seconds, not hours - the hour-long warning in
# SCP applies to the heavy levels (SLOW, COMPAT).
#
# ACHTUNG 2: Die Optimierung SCHALTET DEN SERVER AUS und laesst ihn aus. Das steht
# nirgends in der API-Doku, und der Endpoint nimmt auch keinen Parameter dagegen.
# This script therefore records the state first and restores it afterwards
# first - otherwise the whole cluster goes down with the call.
#
# Usage: optimize-storage.sh [--yes] [--node ID]...
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a
export NC_GEN="$ROOT/generated"
# shellcheck source=lib/netcup.sh
source "$HERE/lib/netcup.sh"
# shellcheck source=lib/nodes.sh
source "$HERE/lib/nodes.sh"
load_nodes

ASSUME_YES=0
declare -a TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --yes)  ASSUME_YES=1; shift ;;
    --node) TARGETS+=("$2"); shift 2 ;;
    *) echo "unbekannte Option: $1" >&2; exit 2 ;;
  esac
done
[ "${#TARGETS[@]}" -gt 0 ] || TARGETS=("${NODE_IDS[@]}")

alloc()  { nc_api GET "/api/v1/servers/$1" | jq -r '.serverLiveInfo.disks[0].allocationInMiB'; }
needed() { nc_api GET "/api/v1/servers/$1" | jq -r '.serverLiveInfo.requiredStorageOptimization'; }
state()  { nc_api GET "/api/v1/servers/$1" | jq -r '.serverLiveInfo.state'; }

wait_state() {  # wait_state ID STATE TIMEOUT
  local id="$1" want="$2" timeout="$3" start; start=$(date +%s)
  while [ "$(state "$id")" != "$want" ]; do
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      echo "Timeout: server $id not in state $want after ${timeout}s" >&2; return 1
    fi
    sleep 5
  done
}

echo "== Ist-Zustand =="
declare -A WAS_RUNNING=()
before_total=0
for id in "${TARGETS[@]}"; do
  [ "$(state "$id")" = "RUNNING" ] && WAS_RUNNING["$id"]=1
  a=$(alloc "$id"); before_total=$((before_total + a))
  sn=$(nc_api GET "/api/v1/servers/$id/snapshots" | jq -c '[.[].name]')
  printf '  %-10s %6s MiB  opt=%-6s snapshots=%s\n' "${NODE_NAME[$id]}" "$a" "$(needed "$id")" "$sn"
done
echo "  Summe: $((before_total / 1024)) GiB"

echo
echo "The optimisation DELETES every snapshot on these servers."
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Weiter? (yes/NO) " ans
  [ "$ans" = "yes" ] || { echo "Abgebrochen."; exit 1; }
fi

echo
echo "== Snapshots entfernen =="
for id in "${TARGETS[@]}"; do
  mapfile -t names < <(nc_api GET "/api/v1/servers/$id/snapshots" | jq -r '.[].name')
  if [ "${#names[@]}" -eq 0 ]; then
    printf '  %-10s none\n' "${NODE_NAME[$id]}"
    continue
  fi
  for n in "${names[@]}"; do
    nc_do DELETE "/api/v1/servers/$id/snapshots/$n" >/dev/null
    printf '  %-10s %s geloescht\n' "${NODE_NAME[$id]}" "$n"
  done
done

echo
echo "== Optimierung =="
for id in "${TARGETS[@]}"; do
  nc_do POST "/api/v1/servers/$id/storageoptimization" "" >/dev/null
  printf '  %-10s fertig\n' "${NODE_NAME[$id]}"
done

echo
# Die Optimierung laesst die Server ausgeschaltet zurueck.
echo "== wieder einschalten =="
for id in "${TARGETS[@]}"; do
  if [ -n "${WAS_RUNNING[$id]:-}" ]; then
    [ "$(state "$id")" = "RUNNING" ] || nc_patch "$id" '' '{"state":"ON"}' >/dev/null
    printf '  %-10s eingeschaltet\n' "${NODE_NAME[$id]}"
  else
    printf '  %-10s war vorher aus, bleibt aus\n' "${NODE_NAME[$id]}"
  fi
done
for id in "${TARGETS[@]}"; do
  [ -n "${WAS_RUNNING[$id]:-}" ] && wait_state "$id" RUNNING 300
done

echo
echo "== Ergebnis =="
after_total=0
for id in "${TARGETS[@]}"; do
  a=$(alloc "$id"); after_total=$((after_total + a))
  printf '  %-10s %6s MiB  opt=%s\n' "${NODE_NAME[$id]}" "$a" "$(needed "$id")"
done
echo "  Summe: $((after_total / 1024)) GiB  (vorher $((before_total / 1024)) GiB)"
echo "  freigegeben: $(( (before_total - after_total) / 1024 )) GiB"
