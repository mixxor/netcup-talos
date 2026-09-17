#!/usr/bin/env bash
# One call against the netcup SCP API, with the retries that API needs.
#
# Usage:  scp-api.sh METHOD PATH [CONTENT_TYPE] [BODY]
#   scp-api.sh POST   /servers/123/rescuesystem
#   scp-api.sh DELETE /servers/123/rescuesystem
#   scp-api.sh PATCH  /servers/123?stateOption=POWEROFF application/merge-patch+json '{"state":"OFF"}'
#
# Reads REFRESH_TOKEN from the environment. SCP_API and SCP_IDP have defaults.
#
# Can also be sourced, which gives you scp_api and scp_run without running
# anything - that is how teardown-node.sh uses it.
#
# This lives in a file rather than inside a heredoc in the .tf on purpose:
# shell embedded in HCL needs $${...} and %%{...} escaping, gets no syntax
# highlighting and is invisible to shellcheck.
set -euo pipefail

SCP_API="${SCP_API:-https://www.servercontrolpanel.de/scp-core/api/v1}"
SCP_IDP="${SCP_IDP:-https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect}"

# How stubborn to be. The lock clears in seconds; a task can legitimately take
# minutes (formatting a 256 GB disk, for instance).
TRANSPORT_RETRIES=5
LOCK_RETRIES=30
RETRY_WAIT=5
TASK_POLLS=180

scp_token() {
  local token
  token=$(curl -sSf --connect-timeout 15 --max-time 60 "$SCP_IDP/token" \
    -d client_id=scp -d "refresh_token=${REFRESH_TOKEN:?REFRESH_TOKEN not set}" \
    -d grant_type=refresh_token | jq -r '.access_token // empty')
  [ -n "$token" ] || { echo "scp-api: token refresh failed" >&2; return 1; }
  printf '%s' "$token"
}

# scp_api METHOD PATH [CONTENT_TYPE] [BODY] -> body, then the HTTP code on its
# own last line.
#
# Retries transport failures. The SCP API does drop connections mid-response
# ("curl: (56) Recv failure"), and under "set -e" a single blip would otherwise
# take a whole apply down - which is exactly how one rebuild died.
scp_api() {
  local method="$1" path="$2" ctype="${3:-application/json}" body="${4:-}"
  local -a args=(-sS --connect-timeout 15 --max-time 120
    -X "$method" -H "Authorization: Bearer $SCP_TOKEN" -w '\n%{http_code}')

  # netcup rejects any write without a Content-Type, even one with no body:
  # HTTP 400 error.content.type.invalid.
  case "$method" in POST | PUT | PATCH) args+=(-H "Content-Type: $ctype") ;; esac
  [ -n "$body" ] && args+=(--data-binary "$body")

  local out rc attempt=0
  while :; do
    if out=$(curl "${args[@]}" "$SCP_API$path"); then
      printf '%s' "$out"
      return 0
    fi
    rc=$?
    if [ "$attempt" -lt "$TRANSPORT_RETRIES" ]; then
      attempt=$((attempt + 1))
      sleep "$RETRY_WAIT"
      continue
    fi
    echo "scp-api: $method $path -> curl exit $rc after $attempt retries" >&2
    return 1
  done
}

# scp_run METHOD PATH [CONTENT_TYPE] [BODY]
#
# Every write is asynchronous: 202 plus a TaskInfo. Success is exactly the state
# FINISHED; ERROR, CANCELED and ROLLBACK are failures.
#
# netcup keeps a lock on a server for a moment after every power operation, even
# once the state already reads SHUTOFF. A concurrent write then gets HTTP 409
# server.lock.error, and the provider has no retry for it - so it is here.
scp_run() {
  local out code body uuid state attempt=0
  while :; do
    out=$(scp_api "$@")
    code=${out##*$'\n'}
    body=${out%$'\n'*}
    if [ "$code" = 409 ] && [[ "$body" == *server.lock.error* ]] && [ "$attempt" -lt "$LOCK_RETRIES" ]; then
      attempt=$((attempt + 1))
      sleep "$RETRY_WAIT"
      continue
    fi
    break
  done

  case "$code" in
    2*) ;;
    *) echo "scp-api: $1 $2 -> HTTP $code: $body" >&2; return 1 ;;
  esac

  uuid=$(printf '%s' "$body" | jq -r '.uuid // empty')
  [ -n "$uuid" ] || return 0

  for _ in $(seq 1 "$TASK_POLLS"); do
    state=$(scp_api GET "/tasks/$uuid" | sed '$d' | jq -r '.state // empty')
    case "$state" in
      FINISHED) return 0 ;;
      ERROR | CANCELED | ROLLBACK) echo "scp-api: task $uuid -> $state" >&2; return 1 ;;
    esac
    sleep "$RETRY_WAIT"
  done
  echo "scp-api: task $uuid timed out" >&2
  return 1
}

# Sourced? Provide the functions and stop here.
(return 0 2>/dev/null) && { SCP_TOKEN=$(scp_token); export SCP_TOKEN; return 0; }

[ $# -ge 2 ] || { echo "usage: $(basename "$0") METHOD PATH [CONTENT_TYPE] [BODY]" >&2; exit 2; }
SCP_TOKEN=$(scp_token)
scp_run "$@"
