# An SSH key per cluster that has load balancers, generated on disk.
#
# ssh-keygen, not tls_private_key: that resource would put the private key into
# the state. This one lands in generated/<cluster>/ and stays there.
resource "terraform_data" "lb_ssh_key" {
  for_each = local.generated_key_clusters

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SH
      set -euo pipefail
      mkdir -p "$(dirname '${local.lb_key_path[each.key]}')"
      [ -f '${local.lb_key_path[each.key]}' ] || ssh-keygen -t ed25519 -N "" -C "${each.key}-lb" -f '${local.lb_key_path[each.key]}'
    SH
  }
}

data "local_file" "lb_ssh_pub" {
  for_each   = local.generated_key_clusters
  filename   = "${local.lb_key_path[each.key]}.pub"
  depends_on = [terraform_data.lb_ssh_key]
}

# Look before creating. SSH key names are unique per account, so a lost state
# file plus a plain create means "sshkey.nameinuse" and a failed apply - the key
# outlives the state that knew about it.
data "netcup_scp_user_ssh_keys" "all" {
  count   = length(local.generated_key_clusters) > 0 ? 1 : 0
  user_id = var.netcup_user_id
}

# Only the public half. netcup injects it during the image install.
resource "netcup_scp_user_ssh_key" "lb" {
  for_each = {
    for cname in keys(local.generated_key_clusters) : cname => cname
    if lookup(local.existing_key_id, cname, null) == null
  }

  user_id = var.netcup_user_id
  name    = "${each.key}-lb"
  key     = local.generated_public_key[each.key]
}

check "lb_ssh_key_matches" {
  assert {
    condition = alltrue([
      for cname in keys(local.generated_key_clusters) :
      local.existing_key_id[cname] == null || local.existing_key_material[cname] == local.generated_public_key[cname]
    ])
    error_message = "An SSH key named <cluster>-lb already exists at netcup with different material than the file in generated/<cluster>/. Delete one of them, or set loadbalancer_ssh_key_ids to reuse the existing one."
  }
}

locals {
  # Every cluster gets a path, whether it uses one or not: module.lb reads this
  # map by cluster name.
  lb_key_path = {
    for cname, c in var.clusters : cname => (
      c.loadbalancer_ssh_key_path != "" ? c.loadbalancer_ssh_key_path : abspath("${var.generated_dir}/${cname}/lb_ed25519")
    )
  }

  # Clusters with load balancers but no key supplied: generate one.
  generated_key_clusters = {
    for cname, c in var.clusters : cname => c
    if length(c.loadbalancer_servers) > 0 && length(c.loadbalancer_ssh_key_ids) == 0
  }

  _account_keys = length(local.generated_key_clusters) > 0 ? tolist(data.netcup_scp_user_ssh_keys.all[0].scp_user_ssh_keys) : []

  existing_key_id = {
    for cname in keys(local.generated_key_clusters) : cname => one([
      for k in local._account_keys : k.id if k.name == "${cname}-lb"
    ])
  }

  existing_key_material = {
    for cname in keys(local.generated_key_clusters) : cname => one([
      for k in local._account_keys : chomp(k.key) if k.name == "${cname}-lb"
    ])
  }

  generated_public_key = {
    for cname in keys(local.generated_key_clusters) : cname => chomp(data.local_file.lb_ssh_pub[cname].content)
  }

  lb_ssh_key_ids = {
    for cname, c in var.clusters : cname => (
      length(c.loadbalancer_ssh_key_ids) > 0 ? c.loadbalancer_ssh_key_ids :
      length(c.loadbalancer_servers) == 0 ? [] :
      [coalesce(lookup(local.existing_key_id, cname, null), one([for k, r in netcup_scp_user_ssh_key.lb : r.id if k == cname]))]
    )
  }
}
