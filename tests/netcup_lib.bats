#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export NC_GEN="$BATS_TEST_TMPDIR/generated"
  export NETCUP_REFRESH_TOKEN="dummy-refresh"
  mkdir -p "$NC_GEN"
  source "$REPO_ROOT/netcup/lib/netcup.sh"
}

@test "nc_token fetches a token and caches it" {
  curl() { printf '{"access_token":"AT-1","expires_in":300}'; }
  run nc_token
  [ "$status" -eq 0 ]
  [ "$output" = "AT-1" ]
  [ -f "$NC_GEN/access_token" ]
}

@test "nc_token uses the cache and does not call curl again" {
  printf 'CACHED' > "$NC_GEN/access_token"
  curl() { printf '{"access_token":"SHOULD-NOT-BE-USED"}'; }
  run nc_token
  [ "$status" -eq 0 ]
  [ "$output" = "CACHED" ]
}

@test "nc_token fails loudly when the refresh returns no token" {
  curl() { printf '{"error":"invalid_grant"}'; }
  run nc_token
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid_grant"* ]]
}

@test "nc_api returns the body and sets NC_HTTP_CODE" {
  printf 'AT-1' > "$NC_GEN/access_token"
  curl() { printf '{"id":940440}\n200'; }
  run nc_api GET /api/v1/servers/940440
  [ "$status" -eq 0 ]
  [ "$output" = '{"id":940440}' ]
}

@test "nc_api fails on HTTP 422 and names the path and code" {
  printf 'AT-1' > "$NC_GEN/access_token"
  curl() { printf '{"message":"nope"}\n422'; }
  run nc_api POST /api/v1/servers/940440/user-image '{}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"422"* ]]
  [[ "$output" == *"/api/v1/servers/940440/user-image"* ]]
}

@test "nc_task returns successfully on FINISHED" {
  printf 'AT-1' > "$NC_GEN/access_token"
  nc_api() { printf '{"uuid":"u1","state":"FINISHED"}'; }
  run nc_task u1 30
  [ "$status" -eq 0 ]
}

@test "nc_task fails on ERROR" {
  printf 'AT-1' > "$NC_GEN/access_token"
  nc_api() { printf '{"uuid":"u1","state":"ERROR","message":"disk busy"}'; }
  run nc_task u1 30
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "nc_task times out when the task stays RUNNING" {
  printf 'AT-1' > "$NC_GEN/access_token"
  nc_api() { printf '{"uuid":"u1","state":"RUNNING"}'; }
  NC_POLL_INTERVAL=0
  run nc_task u1 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"timeout"* ]]
}

@test "nc_api sets Content-Type on a POST with no body" {
  printf 'AT-1' > "$NC_GEN/access_token"
  curl() { printf '%s\n200' "$*"; }
  run nc_api POST /api/v1/servers/940445/rescuesystem
  [ "$status" -eq 0 ]
  [[ "$output" == *"Content-Type: application/json"* ]]
}

@test "nc_api sets no Content-Type on GET" {
  printf 'AT-1' > "$NC_GEN/access_token"
  curl() { printf '%s\n200' "$*"; }
  run nc_api GET /api/v1/servers
  [ "$status" -eq 0 ]
  [[ "$output" != *"Content-Type"* ]]
}

@test "nc_patch uses merge-patch+json" {
  printf 'AT-1' > "$NC_GEN/access_token"
  curl() { printf '%s\n200' "$*"; }
  run nc_patch 940445 'stateOption=POWERCYCLE' '{"state":"ON"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Content-Type: application/merge-patch+json"* ]]
  [[ "$output" == *"stateOption=POWERCYCLE"* ]]
}

@test "nc_api retries HTTP 409 server.lock.error and then succeeds" {
  printf 'AT-1' > "$NC_GEN/access_token"
  export NC_LOCK_WAIT=0
  # First two calls are locked, the third gets through.
  cat > "$BATS_TEST_TMPDIR/attempts" <<< "0"
  curl() {
    local n; n=$(cat "$BATS_TEST_TMPDIR/attempts"); n=$((n+1)); echo "$n" > "$BATS_TEST_TMPDIR/attempts"
    if [ "$n" -lt 3 ]; then
      printf '{"code":"server.lock.error","message":"Write operation for server is currently running."}\n409'
    else
      printf '{"uuid":"u1"}\n202'
    fi
  }
  run nc_api POST /api/v1/servers/940440/rescuesystem
  [ "$status" -eq 0 ]
  [ "$output" = '{"uuid":"u1"}' ]
  [ "$(cat "$BATS_TEST_TMPDIR/attempts")" = "3" ]
}

@test "nc_api gives up on a persistent lock and says so" {
  printf 'AT-1' > "$NC_GEN/access_token"
  export NC_LOCK_WAIT=0 NC_LOCK_RETRIES=2
  curl() { printf '{"code":"server.lock.error","message":"locked"}\n409'; }
  run nc_api POST /api/v1/servers/940440/rescuesystem
  [ "$status" -ne 0 ]
  [[ "$output" == *"server.lock.error"* ]]
}

@test "nc_api does NOT retry other 409s" {
  printf 'AT-1' > "$NC_GEN/access_token"
  export NC_LOCK_WAIT=0
  cat > "$BATS_TEST_TMPDIR/n" <<< "0"
  curl() {
    local n; n=$(cat "$BATS_TEST_TMPDIR/n"); n=$((n+1)); echo "$n" > "$BATS_TEST_TMPDIR/n"
    printf '{"code":"some.other.conflict"}\n409'
  }
  run nc_api POST /api/v1/servers/940440/snapshots
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/n")" = "1" ]
}

@test "nc_api retries when curl itself fails (transport error)" {
  printf 'AT-1' > "$NC_GEN/access_token"
  export NC_LOCK_WAIT=0 NC_RETRY_WAIT=0
  cat > "$BATS_TEST_TMPDIR/n" <<< "0"
  curl() {
    local n; n=$(cat "$BATS_TEST_TMPDIR/n"); n=$((n+1)); echo "$n" > "$BATS_TEST_TMPDIR/n"
    if [ "$n" -lt 3 ]; then return 56; fi   # curl(56) Recv failure
    printf '{"ok":true}\n200'
  }
  run nc_api GET /api/v1/servers
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ "$(cat "$BATS_TEST_TMPDIR/n")" = "3" ]
}

@test "nc_api gives up on a persistent transport error" {
  printf 'AT-1' > "$NC_GEN/access_token"
  export NC_LOCK_WAIT=0 NC_RETRY_WAIT=0 NC_RETRIES=2
  curl() { return 56; }
  run nc_api GET /api/v1/servers
  [ "$status" -ne 0 ]
  [[ "$output" == *"curl"* ]]
}
