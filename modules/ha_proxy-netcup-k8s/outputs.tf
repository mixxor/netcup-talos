output "ip" {
  description = "Public IPv4 of the load balancer. Point your DNS records here."
  value       = local.ip
}

output "server_id" {
  description = "netcup server id, for scripts that talk to the SCP API."
  value       = local.server_id
}

output "cidr" {
  description = "The load balancer as a /32, ready for the cluster's public_ingress_sources."
  value       = "${local.ip}/32"
}

output "config" {
  description = "The rendered haproxy configuration, for inspection without SSH."
  value       = local.haproxy_config_file
}
