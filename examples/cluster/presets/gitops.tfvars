# Only what has to be inline is: Cilium, because nothing becomes Ready without
# a CNI; Longhorn, because it is netcup specific; ArgoCD, the one piece of
# GitOps that cannot itself be GitOps. Everything else arrives from git.
#
#   tofu apply -var-file=presets/gitops.tfvars
clusters = {
  talos = {
    control_plane_servers = [
      "v2202000000000000001",
      "v2202000000000000002",
      "v2202000000000000003",
    ]

    worker_servers = [
      "v2202000000000000004",
      "v2202000000000000005",
    ]

    install_argocd = true

    # Traefik and metrics-server come through ArgoCD instead of inline.
    install_traefik        = false
    install_metrics_server = false

    # The App-of-Apps root: your fork of this repository, which is where the
    # ApplicationSets in gitops/ live. Leave it out and ArgoCD manages nothing,
    # which is a reasonable place to start.
    #
    # The ApplicationSets carry the repository URL themselves as well - see
    # gitops/README.md for the one sed command that points them at your fork.
    # argocd_apps_repo = "https://github.com/YOUR-ORG/netcup-talos.git"

    # Traefik arrives through ArgoCD, so the ports have to be open for it.
    public_ingress_ports = ["80", "443"]

    # Below the number of workers, so a drain has somewhere to move a replica.
    longhorn_replica_count = 1
  }
}
