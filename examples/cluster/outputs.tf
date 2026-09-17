# What you need right after an apply, keyed by cluster name.
output "usage" {
  description = "Copy-paste per cluster."
  value = {
    for name, c in module.cluster : name => <<-TXT
      export KUBECONFIG=${abspath(var.generated_dir)}/${name}/kubeconfig
      export TALOSCONFIG=${abspath(var.generated_dir)}/${name}/talosconfig

      kubectl get nodes
      talosctl -n ${c.cp_ips[0]} health

      API:     ${c.cluster_endpoint}
      Ingress: ${length(local.lb_ips[name]) == 0 ? "directly on the workers, ports 80/443" : "one A record per load balancer -> ${join(", ", local.lb_ips[name])}"}

      CLUSTER=${name} bash ../../verify.sh
    TXT
  }
}

output "cluster_endpoints" {
  description = "The API endpoint each cluster was configured with."
  value       = { for name, c in module.cluster : name => c.cluster_endpoint }
}

output "cp_ips" {
  description = "Control plane IPs per cluster. With DNS, one A record each - kubectl fails over on its own."
  value       = { for name, c in module.cluster : name => c.cp_ips }
}

output "loadbalancer_ips" {
  description = "Public IPv4 of every haproxy load balancer, per cluster. Give the application name one A record per entry."
  value       = local.lb_ips
}

output "loadbalancer_ssh_keys" {
  description = "Private keys for reaching the load balancers. Generated, never stored in the state."
  value       = { for name, c in var.clusters : name => local.lb_key_path[name] if length(c.loadbalancer_servers) > 0 }
}

output "kubeconfigs" {
  description = "Admin kubeconfig per cluster. Also written to generated_dir."
  value       = { for name, c in module.cluster : name => c.kubeconfig }
  sensitive   = true
}

output "talosconfigs" {
  description = "talosctl client configuration per cluster. Also written to generated_dir."
  value       = { for name, c in module.cluster : name => c.talosconfig }
  sensitive   = true
}

# --- Read by the scripts in netcup/ and by verify.sh, not meant for humans ---

output "nodes" {
  description = "Node inventory per cluster: name, id, ip, mac, role."
  value       = { for name, c in module.cluster : name => c.nodes }
}

output "available_servers" {
  description = "Every server in the account, with id and whether a cluster claims it. Use it to fill terraform.tfvars."
  value       = length(module.cluster) == 0 ? null : values(module.cluster)[0].available_servers
}

output "installed_components" {
  description = "Which in-cluster workloads each cluster ships."
  value       = { for name, c in module.cluster : name => c.installed_components }
}

output "installer_image" {
  description = "Factory installer with each cluster's schematic. Swap the version tag for a Talos upgrade."
  value       = { for name, c in module.cluster : name => c.installer_image }
}

output "haproxy_configs" {
  description = "The rendered haproxy configuration, for inspection without SSH."
  value       = { for k, m in module.lb : k => m.config }
}

output "longhorn_replica_counts" {
  description = "Configured replicas per Longhorn volume, per cluster."
  value       = { for name, c in module.cluster : name => c.longhorn_replica_count }
}

output "cluster_domains" {
  description = "DNS name of each API, empty where no DNS is used."
  value       = { for name, c in module.cluster : name => c.cluster_domain }
}

output "loadbalancer_serves_api" {
  description = "Whether the API goes through the load balancer, per cluster."
  value       = { for name, c in var.clusters : name => c.loadbalancer_serves_api }
}
