#!/usr/bin/env bash
# netcup SCP REST API client. Source it, do not execute it.
# Public: nc_token nc_api nc_patch nc_task nc_do

# Bash only: sourcing it from zsh fails with misleading "command not found".
if [ -z "${BASH_VERSION:-}" ]; then
  echo "netcup.sh needs bash. In zsh:  bash -c '. netcup/lib/netcup.sh; ...'" >&2
  # shellcheck disable=SC2317  # reachable when the file is executed, not sourced
  return 1 2>/dev/null || exit 1
fi

NC_BASE="${NC_BASE:-https://www.servercontrolpanel.de/scp-core}"
NC_IDP="${NC_IDP:-https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect}"
NC_GEN="${NC_GEN:-$PWD/generated}"
NC_TOKEN_TTL="${NC_TOKEN_TTL:-240}"      # the token lives 300s
NC_POLL_INTERVAL="${NC_POLL_INTERVAL:-5}"
# netcup keeps a lock on the server for a moment after a power task, even once
# serverLiveInfo.state says SHUTOFF. Any write can hit HTTP 409 until it clears.
NC_LOCK_RETRIES="${NC_LOCK_RETRIES:-30}"
NC_LOCK_WAIT="${NC_LOCK_WAIT:-5}"
# The netcup API occasionally hits a transport error
# (curl(56) Recv failure: Operation timed out). Einzelne Aussetzer, die beim
# gone on the next attempt - but they would otherwise abort a whole run.
NC_RETRIES="${NC_RETRIES:-4}"
NC_RETRY_WAIT="${NC_RETRY_WAIT:-3}"
NC_HTTP_CODE=""

nc__mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

nc_token() {
  local cache="$NC_GEN/access_token"
  if [ -f "$cache" ]; then
    local age=$(( $(date +%s) - $(nc__mtime "$cache") ))
    if [ "$age" -lt "$NC_TOKEN_TTL" ]; then cat "$cache"; return 0; fi
  fi
  : "${NETCUP_REFRESH_TOKEN:?NETCUP_REFRESH_TOKEN not set - run netcup/00-auth.sh}"
  mkdir -p "$NC_GEN"
  local resp tok
  resp=$(curl -sS "$NC_IDP/token" \
    -d client_id=scp \
    -d "refresh_token=$NETCUP_REFRESH_TOKEN" \
    -d grant_type=refresh_token)
  tok=$(printf '%s' "$resp" | jq -r '.access_token // empty')
  if [ -z "$tok" ]; then
    echo "nc_token: Refresh fehlgeschlagen: $resp" >&2
    return 1
  fi
  ( umask 077; printf '%s' "$tok" > "$cache" )
  printf '%s' "$tok"
}

# nc__curl METHOD PATH CONTENT_TYPE [BODY]
nc__curl() {
  local method="$1" path="$2" ctype="$3" body="${4:-}"
  local token; token=$(nc_token) || return 1
  local -a args=(-sS -X "$method" -H "Authorization: Bearer $token" -w '\n%{http_code}')
  # netcup wants Content-Type on every write, even with an empty body
  # (POST /rescuesystem has none): otherwise HTTP 400 error.content.type.invalid.
  case "$method" in
    POST|PUT|PATCH) args+=(-H "Content-Type: $ctype") ;;
  esac
  if [ -n "$body" ]; then args+=(--data-binary "$body"); fi
  local out code payload attempt=0 transport=0 rc
  while :; do
    if ! out=$(curl "${args[@]}" "$NC_BASE$path"); then
      rc=$?
      if [ "$transport" -lt "$NC_RETRIES" ]; then
        transport=$((transport + 1))
        [ "$NC_RETRY_WAIT" -gt 0 ] && sleep "$NC_RETRY_WAIT"
        continue
      fi
      echo "nc_api: $method $path -> curl failed with exit $rc after $transport retries" >&2
      return 1
    fi
    code="${out##*$'\n'}"
    payload="${out%$'\n'*}"

    # Transient server lock: retry rather than lose the whole run.
    if [ "$code" = "409" ] && [[ "$payload" == *"server.lock.error"* ]] \
       && [ "$attempt" -lt "$NC_LOCK_RETRIES" ]; then
      attempt=$((attempt + 1))
      [ "$NC_LOCK_WAIT" -gt 0 ] && sleep "$NC_LOCK_WAIT"
      continue
    fi
    break
  done

  # shellcheck disable=SC2034  # read by the scripts that source this
  NC_HTTP_CODE="$code"
  printf '%s' "$payload"
  case "$code" in
    2*) return 0 ;;
    *)  echo "nc_api: $method $path -> HTTP $code: $payload" >&2; return 1 ;;
  esac
}

nc_api() { nc__curl "$1" "$2" 'application/json' "${3:-}"; }

# nc_patch SERVER_ID QUERY BODY
# PATCH /servers/{id} verlangt merge-patch+json und genau ein Attribut pro Request.
nc_patch() {
  local id="$1" query="$2" body="$3"
  local path="/api/v1/servers/$id"
  [ -n "$query" ] && path="$path?$query"
  nc__curl PATCH "$path" 'application/merge-patch+json' "$body"
}

# nc_task UUID [TIMEOUT_SECONDS]
nc_task() {
  local uuid="$1" timeout="${2:-900}" start state info
  start=$(date +%s)
  while :; do
    info=$(nc_api GET "/api/v1/tasks/$uuid") || return 1
    state=$(printf '%s' "$info" | jq -r '.state // empty')
    case "$state" in
      FINISHED) return 0 ;;
      ERROR|CANCELED|ROLLBACK)
        echo "nc_task: $uuid -> $state: $(printf '%s' "$info" | jq -r '.message // "-"')" >&2
        return 1 ;;
    esac
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      echo "nc_task: timeout nach ${timeout}s, uuid=$uuid state=$state" >&2
      return 1
    fi
    [ "$NC_POLL_INTERVAL" -gt 0 ] && sleep "$NC_POLL_INTERVAL"
  done
}

# nc_do METHOD PATH [BODY] - Call absetzen und ein etwaiges TaskInfo auspollen
nc_do() {
  local resp uuid
  resp=$(nc_api "$@") || return 1
  uuid=$(printf '%s' "$resp" | jq -r '.uuid // empty' 2>/dev/null)
  if [ -n "$uuid" ]; then nc_task "$uuid" || return 1; fi
  printf '%s' "$resp"
}
