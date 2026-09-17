#!/usr/bin/env bash
# Log in to netcup once and write what everything else needs into .env.
#
# The SCP API has no API keys. It speaks OAuth 2.0, and the only grant that
# survives without a browser is a device flow with offline_access - which is
# what this does. The refresh token it produces is long lived but not eternal:
# it dies after 30 days without use.
#
# It also reads your SCP user id, which is NOT the customer number. Both appear
# in the OIDC userinfo response, which is confusing enough to be worth spelling
# out:
#
#   "id":                 100200     <- SCP user id, what the API wants
#   "preferred_username": 300400     <- customer number, what you log in with
#
# Usage: 00-auth.sh          # writes .env
#        00-auth.sh --print  # print only, change nothing
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
IDP="https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect"
PRINT_ONLY=0
[ "${1:-}" = "--print" ] && PRINT_ONLY=1

dev=$(curl -sS -X POST "$IDP/auth/device" -d client_id=scp -d 'scope=offline_access openid')
code=$(printf '%s' "$dev" | jq -r .device_code)
uri=$(printf '%s' "$dev" | jq -r .verification_uri_complete)
user_code=$(printf '%s' "$dev" | jq -r .user_code)

echo "Open this in a browser and confirm 'Grant Access':"
echo "  $uri"
echo "Code to check against: $user_code"
echo

refresh=""
access=""
for _ in $(seq 1 110); do
  resp=$(curl -sS -X POST "$IDP/token" \
    -d 'grant_type=urn:ietf:params:oauth:grant-type:device_code' \
    -d "device_code=$code" -d client_id=scp)
  refresh=$(printf '%s' "$resp" | jq -r '.refresh_token // empty')
  access=$(printf '%s' "$resp" | jq -r '.access_token // empty')
  [ -n "$refresh" ] && break
  err=$(printf '%s' "$resp" | jq -r '.error // "unknown"')
  case "$err" in
    authorization_pending | slow_down) sleep 5 ;;
    *) echo "Failed: $resp" >&2; exit 1 ;;
  esac
done
[ -n "$refresh" ] || { echo "Timed out - the device code expired." >&2; exit 1; }

info=$(curl -sS -H "Authorization: Bearer $access" "$IDP/userinfo")
user_id=$(printf '%s' "$info" | jq -r '.id // empty')
customer=$(printf '%s' "$info" | jq -r '.preferred_username // empty')
name=$(printf '%s' "$info" | jq -r '.name // empty')
[ -n "$user_id" ] || { echo "userinfo returned no id: $info" >&2; exit 1; }

echo "Signed in as $name"
echo "  SCP user id:     $user_id   <- this is what the API wants   "
echo "  customer number: $customer   <- not this one, that is your login"
echo

if [ "$PRINT_ONLY" -eq 1 ]; then
  echo "NETCUP_USER_ID=$user_id"
  echo "NETCUP_REFRESH_TOKEN=$refresh"
  exit 0
fi

# Update in place rather than overwrite: .env may hold things this script knows
# nothing about, and the token is the one secret here.
[ -f "$ENV_FILE" ] || cp "$ROOT/.env.example" "$ENV_FILE"
tmp=$(mktemp)
awk -v uid="$user_id" -v rt="$refresh" '
  /^NETCUP_USER_ID=/       { print "NETCUP_USER_ID=" uid; seen_uid=1; next }
  /^NETCUP_REFRESH_TOKEN=/ { print "NETCUP_REFRESH_TOKEN=" rt; seen_rt=1; next }
  { print }
  END {
    if (!seen_uid) print "NETCUP_USER_ID=" uid
    if (!seen_rt)  print "NETCUP_REFRESH_TOKEN=" rt
  }
' "$ENV_FILE" > "$tmp"
mv "$tmp" "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "Written to $ENV_FILE (mode 600)."
echo "Nothing else to copy: 'source netcup/env.sh' exports both the token and"
echo "the user id as TF_VAR_, so neither belongs in terraform.tfvars."
