# shellcheck shell=bash
# Source this, do not execute it:
#
#   source netcup/env.sh
#
# It exports what OpenTofu expects from .env, so that the user id and the
# refresh token live in exactly one place. Putting the id into
# terraform.tfvars as well would give it two, and two places holding the same
# number is two places it can be wrong.
#
# No "set -e" and no "set -u" anywhere in here: this runs in your interactive
# shell, and turning those on would follow you around for the rest of the
# session.

# BASH_SOURCE in bash, $0 in zsh - sourced files set one or the other.
_nc_self="${BASH_SOURCE[0]:-$0}"
_nc_root="$(cd "$(dirname "$_nc_self")/.." && pwd)"
_nc_env="${NETCUP_ENV_FILE:-$_nc_root/.env}"

if [ ! -r "$_nc_env" ]; then
  echo "env.sh: no readable $_nc_env - run netcup/00-auth.sh first" >&2
else
  # shellcheck disable=SC1090
  . "$_nc_env"
  [ -n "${NETCUP_REFRESH_TOKEN:-}" ] && export TF_VAR_netcup_refresh_token="$NETCUP_REFRESH_TOKEN"
  [ -n "${NETCUP_USER_ID:-}" ] && export TF_VAR_netcup_user_id="$NETCUP_USER_ID"
  [ -n "${ADMIN_CIDR:-}" ] && export TF_VAR_admin_cidr="$ADMIN_CIDR"
  # Never interpolate the token itself - this runs in an interactive shell and
  # would land in the scrollback.
  if [ -n "${NETCUP_REFRESH_TOKEN:-}" ]; then _nc_tok="set"; else _nc_tok="MISSING"; fi
  echo "env.sh: user id ${NETCUP_USER_ID:-<unset>}, refresh token $_nc_tok"
fi
unset _nc_self _nc_root _nc_env _nc_tok
