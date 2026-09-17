#!/usr/bin/env bash
# What a "tofu destroy" leaves behind: a powered-off server with an empty disk.
#
# netcup cannot delete servers through the API, so this is as close to
# as-delivered as the platform gets.
#
# Environment: SERVER_ID, NODE, WIPE (true/false), REFRESH_TOKEN.
set -euo pipefail

# shellcheck source=scp-api.sh
source "$(dirname "${BASH_SOURCE[0]}")/scp-api.sh"

: "${SERVER_ID:?SERVER_ID not set}"
: "${NODE:?NODE not set}"
WIPE="${WIPE:-false}"

state() { scp_api GET "/servers/$SERVER_ID" | sed '$d' | jq -r '.serverLiveInfo.state'; }

# The Talos reset already shuts the node down, but a node that never received a
# config was never reset - so make sure either way.
if [ "$(state)" != SHUTOFF ]; then
  echo "[$NODE] powering off"
  scp_run PATCH "/servers/$SERVER_ID?stateOption=POWEROFF" application/merge-patch+json '{"state":"OFF"}' >/dev/null
  for _ in $(seq 1 60); do
    [ "$(state)" = SHUTOFF ] && break
    sleep 5
  done
fi
echo "[$NODE] powered off"

# Release the claim. The nickname is how another cluster is told this server is
# taken, and leaving it behind on a wiped disk blocks the next cluster for a
# reason that no longer exists. Measured: a destroy without this left every
# server carrying its old name and the precondition refused a fresh build.
echo "[$NODE] clearing the nickname"
scp_api PATCH "/servers/$SERVER_ID" application/merge-patch+json '{"nickname":""}' >/dev/null || \
  echo "[$NODE] could not clear the nickname" >&2

[ "$WIPE" = true ] || exit 0

echo "[$NODE] formatting /dev/vda"
scp_run POST "/servers/$SERVER_ID/disks/vda:format"
echo "[$NODE] disk wiped"
