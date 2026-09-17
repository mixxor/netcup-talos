# Membership is declared, never inferred - otherwise an unrelated server in the
# same account gets its disk overwritten, and two clusters cannot coexist.
#
# By name, not by id: the name is printed in the SCP list, the id only appears
# in the URL. Order decides naming - the first control plane becomes cp-1.

data "netcup_scp_servers" "all" {}

locals {
  servers_by_name = {
    for s in data.netcup_scp_servers.all.scp_servers : s.name => s
  }

  declared_names = concat(var.control_plane_servers, var.worker_servers)
  unknown_names  = [for n in local.declared_names : n if !contains(keys(local.servers_by_name), n)]
}

# Enforced as preconditions, not as check blocks: a check only warns, and an
# apply that continues past "this server does not exist" fails later with five
# opaque index errors instead of one sentence.
data "netcup_scp_server_interfaces" "node" {
  for_each = toset(local.declared_names)

  # try() so the precondition below is what you read, rather than a lookup
  # failure in this very expression.
  server_id = try(local.servers_by_name[each.key].id, 0)

  lifecycle {
    precondition {
      condition     = contains(keys(local.servers_by_name), each.key)
      error_message = "No server named ${each.key} in this account. Run 'tofu output available_servers' to see what is there."
    }

    precondition {
      condition = !(contains(var.control_plane_servers, each.key) &&
      contains(var.worker_servers, each.key))
      error_message = "Server ${each.key} is listed as both a control plane and a worker."
    }
  }
}

locals {
  node_attrs = {
    for name in local.declared_names : name => {
      id   = try(local.servers_by_name[name].id, 0)
      name = name
      # Exactly one interface per VPS; the netcup API models it as a set.
      ip  = one([for i in data.netcup_scp_server_interfaces.node[name].scp_server_interfaces : i.ipv4addresses[0].ip])
      mac = one([for i in data.netcup_scp_server_interfaces.node[name].scp_server_interfaces : i.mac])
    }
  }

  nodes = merge(
    {
      for idx, n in var.control_plane_servers :
      "cp-${idx + 1}" => merge(local.node_attrs[n], { role = "controlplane" })
    },
    {
      for idx, n in var.worker_servers :
      "worker-${idx + 1}" => merge(local.node_attrs[n], { role = "worker" })
    },
  )

  cp_nodes     = { for k, v in local.nodes : k => v if v.role == "controlplane" }
  worker_nodes = { for k, v in local.nodes : k => v if v.role == "worker" }
  cp_ips       = sort([for v in local.cp_nodes : v.ip])
  all_ips      = sort([for v in local.nodes : v.ip])
  first_cp_ip  = local.cp_ips[0]
  # compact() so an empty cluster_domain does not put "" into the SAN list.
  cert_sans = compact(concat(local.all_ips, [var.cluster_domain]))

  # No DNS required: every node IP is already in the SANs. An endpoint pinned
  # to one node dies with that node, so put a name in front when you have one.
  cluster_endpoint = var.cluster_endpoint != "" ? var.cluster_endpoint : "https://${local.first_cp_ip}:6443"
}

# Helper for filling in the variables above.

# A second cluster in the same account is fine - the policy, the nicknames and
# the key name all carry cluster_name. Claiming a server that already belongs to
# another one is not: both configurations would write an operating system onto
# the same disk, and the first anyone notices is a cluster that stopped
# existing.
#
# The nickname is the evidence. This module sets it to "<cluster_name>/<node>",
# so anything else non-empty means somebody else got there first.
#
# Enforced as a precondition on the install in install.tf, not as a check block:
# a check only warns, and a warning in front of "this overwrites your disks" is
# not worth having.
locals {
  foreign_servers = [
    for name in local.declared_names :
    "${name} (${local.servers_by_name[name].nickname})"
    if try(local.servers_by_name[name].nickname, "") != "" &&
    !startswith(local.servers_by_name[name].nickname, "${var.cluster_name}/")
  ]
}

