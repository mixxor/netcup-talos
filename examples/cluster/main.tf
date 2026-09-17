# A Talos cluster on netcup, with everything the module can do reachable from
# terraform.tfvars. One entry under "clusters" is one cluster; add a second and
# you get two, side by side in the same account.
#
#   bash ../../netcup/00-auth.sh     # browser device flow; writes ../../.env
#   source ../../netcup/env.sh       # exports the token and the user id
#   cp terraform.tfvars.example terraform.tfvars
#   $EDITOR terraform.tfvars         # the server names, and that is all
#   tofu init && tofu apply
#
# presets/ holds tfvars files for the usual shapes - a single small cluster,
# the full one with load balancers, GitOps, two clusters. They all work against
# this same configuration, which is the point.

module "cluster" {
  source   = "../../modules/talos-netcup-k8s-cluster"
  for_each = var.clusters

  cluster_name     = each.key
  cluster_endpoint = each.value.cluster_endpoint
  cluster_domain   = each.value.cluster_domain

  control_plane_servers = each.value.control_plane_servers
  worker_servers        = each.value.worker_servers

  netcup_user_id       = var.netcup_user_id
  netcup_refresh_token = var.netcup_refresh_token
  admin_cidr           = var.admin_cidr
  extra_firewall_rules = each.value.extra_firewall_rules

  # With load balancers in front, 80 and 443 accept only from them, so nobody
  # reaches a worker directly. The API is a separate decision: it opens to the
  # load balancers only if they actually serve it.
  public_ingress_ports        = each.value.public_ingress_ports
  public_ingress_sources      = local.ingress_sources[each.key]
  api_ingress_sources         = each.value.loadbalancer_serves_api ? local.lb_cidrs[each.key] : each.value.api_ingress_sources
  ingress_trusted_proxy_cidrs = length(each.value.loadbalancer_servers) > 0 ? local.lb_cidrs[each.key] : each.value.ingress_trusted_proxy_cidrs

  talos_version      = each.value.talos_version
  kubernetes_version = each.value.kubernetes_version

  install_longhorn       = each.value.install_longhorn
  install_local_path     = each.value.install_local_path
  install_metrics_server = each.value.install_metrics_server
  install_traefik        = each.value.install_traefik
  install_argocd         = each.value.install_argocd

  longhorn_replica_count        = each.value.longhorn_replica_count
  longhorn_backup_target        = each.value.longhorn_backup_target
  longhorn_backup_target_secret = each.value.longhorn_backup_target_secret

  argocd_apps_repo     = each.value.argocd_apps_repo
  argocd_apps_path     = each.value.argocd_apps_path
  argocd_apps_revision = each.value.argocd_apps_revision

  # So the module can drain a node before resetting it. The files are written
  # by credentials.tf in this directory.
  kubeconfig_path  = "${abspath(var.generated_dir)}/${each.key}/kubeconfig"
  talosconfig_path = "${abspath(var.generated_dir)}/${each.key}/talosconfig"

  teardown_wipe_disk = each.value.teardown_wipe_disk
}

# One module instance per load balancer, across all clusters.
#
# It resolves nothing itself: every value is looked up HERE and handed over.
# That is what lets it carry depends_on = [module.cluster] without every plan
# marking its resources for replacement - and reinstalling its operating system
# along with them.
#
# The dependency has to point this way round because both modules touch the
# same server when a worker is repurposed as a load balancer: the cluster
# resets it and wipes the disk, and the Debian install must not start first.
module "lb" {
  source   = "../../modules/ha_proxy-netcup-k8s"
  for_each = local.lb_instances

  server_id  = local.server_id[each.value.server]
  server_ip  = local.server_ip[each.value.server]
  server_mac = local.server_mac[each.value.server]
  name       = each.key
  hostname   = each.key

  netcup_user_id       = var.netcup_user_id
  netcup_refresh_token = var.netcup_refresh_token
  admin_cidr           = local.admin_cidr
  ssh_key_ids          = local.lb_ssh_key_ids[each.value.cluster]
  ssh_private_key_path = local.lb_key_path[each.value.cluster]

  teardown_wipe_disk = var.clusters[each.value.cluster].teardown_wipe_disk

  http_backends = {
    for idx, name in var.clusters[each.value.cluster].worker_servers :
    "worker-${idx + 1}" => local.server_ip[name]
  }

  api_backends = var.clusters[each.value.cluster].loadbalancer_serves_api ? {
    for idx, name in var.clusters[each.value.cluster].control_plane_servers :
    "cp-${idx + 1}" => local.server_ip[name]
  } : {}

  depends_on = [module.cluster]
}

data "netcup_scp_servers" "all" {}

# Only needed when there is a load balancer to point at something; the cluster
# module does its own lookups.
data "netcup_scp_server_interfaces" "server" {
  for_each = length(local.lb_instances) == 0 ? toset([]) : toset(local.all_servers)

  server_id = one([
    for s in data.netcup_scp_servers.all.scp_servers : s.id if s.name == each.value
  ])
}

data "http" "my_ip" {
  count = length(local.lb_instances) > 0 && var.admin_cidr == "" ? 1 : 0
  # IPv4 only, deliberately. ifconfig.me answers a dual-stack machine with its
  # IPv6 address, and "<v6>/32" is a syntactically valid CIDR covering an
  # ISP-sized block - so the rule either lets in far too much or does not match
  # the IPv4 connection that the install actually uses.
  url = "https://ipv4.icanhazip.com"
}

locals {
  lb_list = flatten([
    for cname, c in var.clusters : [
      for idx, srv in c.loadbalancer_servers : {
        key     = "${cname}-lb-${idx + 1}"
        cluster = cname
        server  = srv
      }
    ]
  ])
  lb_instances = { for o in local.lb_list : o.key => o }

  all_servers = distinct(flatten([
    for c in var.clusters : concat(c.control_plane_servers, c.worker_servers, c.loadbalancer_servers)
  ]))

  admin_cidr = var.admin_cidr != "" ? var.admin_cidr : "${chomp(one(data.http.my_ip[*].response_body))}/32"

  # scp_server_interfaces is a set, so one() rather than [0].
  server_id  = { for s in data.netcup_scp_servers.all.scp_servers : s.name => s.id }
  server_ip  = { for n, d in data.netcup_scp_server_interfaces.server : n => one([for i in d.scp_server_interfaces : i.ipv4addresses[0].ip]) }
  server_mac = { for n, d in data.netcup_scp_server_interfaces.server : n => one([for i in d.scp_server_interfaces : i.mac]) }

  lb_ips   = { for cname, c in var.clusters : cname => [for s in c.loadbalancer_servers : local.server_ip[s]] }
  lb_cidrs = { for cname, ips in local.lb_ips : cname => [for ip in ips : "${ip}/32"] }

  ingress_sources = {
    for cname, c in var.clusters : cname => length(c.loadbalancer_servers) == 0 ? c.public_ingress_sources : local.lb_cidrs[cname]
  }
}
