# Two clusters in one netcup account. Separate firewall policies, separate
# nicknames, separate credential directories - the map key decides all three.
#
# A server may appear only once across all clusters: a validation refuses the
# rest, and the module refuses a server whose nickname says it belongs
# elsewhere.
#
#   tofu apply -var-file=presets/two-clusters.tfvars
#
# Building both at once is slower than building one - four servers install in
# parallel over the same account, and the machine configuration apply goes from
# about a minute to four.
clusters = {
  prod = {
    control_plane_servers  = ["v2202000000000000001"]
    worker_servers         = ["v2202000000000000002"]
    install_traefik        = true
    public_ingress_ports   = ["80", "443"]
    longhorn_replica_count = 1
  }

  # etcd needs an odd number of control plane nodes; one is odd. It also means
  # no redundancy at all, which is usually fine for staging and never for prod.
  staging = {
    control_plane_servers  = ["v2202000000000000003"]
    worker_servers         = ["v2202000000000000004"]
    install_longhorn       = false
    longhorn_replica_count = 1
  }
}
