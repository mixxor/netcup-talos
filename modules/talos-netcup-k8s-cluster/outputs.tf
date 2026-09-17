output "talosconfig" {
  description = "Client configuration for talosctl."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Admin kubeconfig for the cluster."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "cp_ips" {
  description = "Control plane IPs. With DNS, give the cluster name one A record per entry - kubectl then fails over on its own."
  value       = local.cp_ips
}

output "nodes" {
  description = "Discovered node inventory. The remaining shell scripts read this instead of keeping their own copy."
  value       = local.nodes
}

output "image_url" {
  description = "Talos image built by the Image Factory. netcup/03-install.sh writes this to disk."
  value       = local.image_url
}

output "installer_image" {
  description = "Factory installer carrying the same schematic, used by machine.install.image."
  value       = local.installer_image
}

output "installed_components" {
  description = "Which in-cluster workloads this configuration ships. verify.sh reads this to decide what to check."
  value = {
    cilium         = var.install_cilium
    longhorn       = var.install_longhorn
    metrics_server = var.install_metrics_server
    local_path     = var.install_local_path
    traefik        = var.install_traefik
    argocd         = var.install_argocd
  }
}

output "longhorn_replica_count" {
  description = "Configured replicas per Longhorn volume. verify.sh checks against this instead of a hardcoded 3."
  value       = var.longhorn_replica_count
}

output "available_servers" {
  description = "Every server in the account. Use the names to fill control_plane_servers and worker_servers."
  value = {
    for s in data.netcup_scp_servers.all.scp_servers : s.name => {
      id       = s.id
      nickname = s.nickname
      in_use   = contains(local.declared_names, s.name)
    }
  }
}

output "cluster_endpoint" {
  description = "The API endpoint the nodes were configured with - the first control plane IP unless one was given."
  value       = local.cluster_endpoint
}

output "cluster_domain" {
  description = "DNS name of the API endpoint, so scripts do not hardcode it."
  value       = var.cluster_domain
}
