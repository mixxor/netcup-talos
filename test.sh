#!/usr/bin/env bash
# Static test suite: everything that can be checked without a cluster.
#
# Formatting, configuration validity for every example, shell linting and the
# bats unit tests for the netcup API client. Runs in a few seconds and needs
# neither credentials nor a running cluster - e2e.sh calls it before it
# tears anything down.
#
# Usage: test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1
export PATH="$HOME/.local/bin:$PATH"

PASS=0
declare -a FAILED=()

# shellcheck disable=SC2329  # the check_* helpers below run indirectly through check()
check() {
  local name="$1"; shift
  echo
  echo "=== $name ==="
  if "$@"; then
    echo "--- OK"
    PASS=$((PASS + 1))
  else
    echo "--- FAILED"
    FAILED+=("$name")
  fi
}

# --- 1. Formatting -----------------------------------------------------------
# -check exits non-zero and prints the offending files, it never rewrites them.
check "tofu fmt: every .tf file formatted" \
  tofu fmt -recursive -check -diff -no-color .

# --- 2. Configuration validity ----------------------------------------------
# There is one example configuration; the shapes it can take live in
# examples/cluster/presets/ and are checked separately below.
# shellcheck disable=SC2329
validate_example() {
  local dir="$1"
  # -backend=false so this needs no state and no credentials.
  tofu -chdir="$dir" init -backend=false -input=false -no-color >/dev/null || return 1
  tofu -chdir="$dir" validate -no-color
}

for ex in examples/*/; do
  [ -f "$ex/main.tf" ] || continue
  # e2e.sh's scratch working directory, not an example.
  [ "$ex" = "examples/e2e-run/" ] && continue
  check "tofu validate: ${ex%/}" validate_example "${ex%/}"
done

# --- 3. Shell ----------------------------------------------------------------
# -x follows sourced files, so lib/netcup.sh is checked in context.
check "shellcheck: every script" \
  shellcheck -x netcup/*.sh netcup/lib/*.sh modules/*/scripts/*.sh tests/*.sh verify.sh test.sh e2e.sh

# --- 4. Unit tests -----------------------------------------------------------
check "bats: netcup API client" \
  bats tests/netcup_lib.bats

# --- 5. No personal values left in the module --------------------------------
# The module must not carry anyone's account id or domain as a default, or it
# silently builds against the wrong account when someone forgets a variable.
# shellcheck disable=SC2329
no_personal_data() {
  local uid hits bad=0

  # The real values live in .env, which is gitignored. Reading them from there
  # rather than listing them here keeps this check out of the business of
  # knowing anybody's account number - and makes it look for the actual one.
  if [ -f .env ]; then
    uid=$(grep -m1 '^NETCUP_USER_ID=' .env | cut -d= -f2 | tr -d '"' | tr -d "'")
    if [ -n "$uid" ]; then
      hits=$(git ls-files -z | xargs -0 grep -nIF -e "$uid" 2>/dev/null || true)
      if [ -n "$hits" ]; then
        echo "  the SCP user id from .env appears in tracked files:"
        echo "$hits"
        bad=1
      else
        echo "  the SCP user id from .env appears in no tracked file"
      fi
    fi
  else
    echo "  no .env to compare against"
  fi

  # Real server names are v2202 plus fifteen digits; the ones in the examples
  # are deliberately v2202000000000000NNN.
  hits=$(git ls-files -z | xargs -0 grep -nIE 'v2202[0-9]{15}' 2>/dev/null \
    | grep -vE 'v2202000000000000[0-9]{3}' || true)
  if [ -n "$hits" ]; then
    echo "  real-looking server names in tracked files:"
    echo "$hits"
    bad=1
  else
    echo "  no real server names in tracked files"
  fi

  [ "$bad" -eq 0 ]
}
check "no personal data in tracked files" no_personal_data

# --- 6. No provider blocks in the module -------------------------------------
# A module with its own provider blocks cannot be used with count or for_each
# and cannot be handed an aliased provider - which rules out two clusters from
# one configuration.
# shellcheck disable=SC2329
no_provider_blocks() {
  local hits
  # --include='*.tf': a "tofu init" inside a module directory leaves a
  # .terraform/ tree and a lock file, and both mention provider blocks.
  hits=$(grep -rn --include='*.tf' '^provider "' modules/ || true)
  if [ -n "$hits" ]; then
    echo "$hits"
    return 1
  fi
  echo "  no provider blocks in the modules"
}
check "modules configure no providers" no_provider_blocks

# --- 7. No script points at the old tofu/ directory ---------------------------
# The layout moved to modules/ + examples/. A leftover path into the old
# directory fails only at runtime, and only for whoever runs that one script.
# A linter cannot see it, so it is checked here.
# shellcheck disable=SC2329
no_stale_tofu_dir() {
  local hits
  # --exclude test.sh: this file carries the pattern itself.
  # generated/ holds one directory per cluster now, so a bare
  # generated/kubeconfig is a path that no apply ever writes.
  hits=$(grep -rn 'ROOT/tofu\|cd tofu\b\|generated/kubeconfig\|generated/talosconfig' \
    --include='*.sh' --exclude='test.sh' . || true)
  if [ -n "$hits" ]; then
    echo "$hits"
    return 1
  fi
  echo "  no script points at the old tofu/ or at a bare generated/kubeconfig"
}
check "no script points at a path that moved" no_stale_tofu_dir

# --- 10. The documented way in still works ---------------------------------
# Twice now a replacement in the README silently did nothing and left people
# following instructions that ended in an interactive prompt. env.sh is the one
# documented way to hand OpenTofu its credentials, so nothing should be telling
# readers to assemble TF_VAR_ by hand.
# shellcheck disable=SC2329
docs_match_env_sh() {
  local hits
  hits=$(grep -rn 'export TF_VAR_netcup' README.md examples/*/main.tf examples/*/terraform.tfvars.example 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "$hits"
    echo "  use 'source netcup/env.sh' instead"
    return 1
  fi
  grep -q 'source netcup/env.sh' README.md || {
    echo "  the README no longer mentions netcup/env.sh"
    return 1
  }
  echo "  the README points at netcup/env.sh and nowhere else"
}
check "documentation matches env.sh" docs_match_env_sh

# --- 12. Every preset still fits the variable type ---------------------------
# tofu validate does not read tfvars, so a preset can name an attribute the
# clusters object does not have and nothing notices until someone applies it.
# tofu console does read them - and exits 0 either way, so the check is whether
# it printed an error, not what it returned.
# shellcheck disable=SC2329
presets_evaluate() {
  local dir=examples/cluster f err bad=0
  tofu -chdir="$dir" init -backend=false -input=false -no-color >/dev/null || return 1

  for f in "$dir/terraform.tfvars.example" "$dir"/presets/*.tfvars; do
    [ -f "$f" ] || continue
    err=$(echo 'keys(var.clusters)' | tofu -chdir="$dir" console -no-color \
      -var-file="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" \
      -var netcup_user_id=1 -var netcup_refresh_token=dummy 2>&1 >/dev/null)
    if echo "$err" | grep -q 'Error:'; then
      echo "  $(basename "$f"): $(echo "$err" | grep -m1 -A2 'Error:' | tr '\n' ' ')"
      bad=1
    else
      echo "  $(basename "$f"): evaluates"
    fi
  done
  [ "$bad" -eq 0 ]
}
check "presets fit the clusters variable" presets_evaluate

# --- Summary -----------------------------------------------------------------
echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "ALL $PASS CHECKS PASSED"
  exit 0
fi
echo "FAILED (${#FAILED[@]} of $((PASS + ${#FAILED[@]}))):"
printf '  %s\n' "${FAILED[@]}"
exit 1
