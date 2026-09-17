#!/usr/bin/env bash
# Resolve one cluster's credential directory. Source it, do not execute it.
#
# Every cluster writes generated/<cluster name>/{kubeconfig,talosconfig}, so a
# repository that has built more than one has more than one candidate. CLUSTER
# picks it; with exactly one candidate it can be left unset.
gen_dir() {
  local root="$1" d found=()

  if [ -n "${CLUSTER:-}" ]; then
    if [ ! -f "$root/generated/$CLUSTER/kubeconfig" ]; then
      echo "no credentials at $root/generated/$CLUSTER/ - run tofu apply first" >&2
      return 1
    fi
    printf '%s\n' "$root/generated/$CLUSTER"
    return 0
  fi

  for d in "$root"/generated/*/; do
    [ -f "$d/kubeconfig" ] && found+=("${d%/}")
  done

  case ${#found[@]} in
    1) printf '%s\n' "${found[0]}" ;;
    0)
      echo "no cluster credentials under $root/generated/ - run tofu apply in examples/cluster first" >&2
      return 1
      ;;
    *)
      echo "several clusters under $root/generated/: $(basename -a "${found[@]}" | tr '\n' ' ')" >&2
      echo "set CLUSTER to pick one, e.g. CLUSTER=prod $0" >&2
      return 1
      ;;
  esac
}
