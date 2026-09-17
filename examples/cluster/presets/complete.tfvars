# Everything on: three control planes for a real etcd quorum, two workers,
# Traefik on hostPort behind an haproxy load balancer.
#
# Six servers, which is what a starter netcup order tends to be.
#
#   tofu apply -var-file=presets/complete.tfvars
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

    # Add a second server here and the name gets a second A record. Measured,
    # that buys less than it sounds: a browser on macOS tries one address and
    # gives up, and Linux pays about 134 s before it retries, because netcup
    # black-holes a closed port instead of refusing it.
    loadbalancer_servers = ["v2202000000000000006"]

    # The API stays off the load balancer. It does not need one - kubectl walks
    # the control plane addresses itself - and coupling it to the ingress entry
    # point means a dead box takes away the ability to fix the cluster.
    loadbalancer_serves_api = false

    # Traefik is a DaemonSet on hostPort, so the node firewall has to let the
    # load balancers through. It opens to them only, not to the internet.
    install_traefik      = true
    public_ingress_ports = ["80", "443"]

    # Below the number of workers on purpose: with a replica on every worker
    # there is nowhere to evacuate one to, and a drain has nothing to do.
    longhorn_replica_count = 1

    # No DNS? Leave both out and the endpoint becomes the first control plane
    # IP, which is already in the certificate SANs.
    # cluster_endpoint = "https://k8s.example.com:6443"
    # cluster_domain   = "k8s.example.com"
  }
}
