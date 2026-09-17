# Writing Talos to disk.
#
# Power state goes through the provider; the rescue system does not. Those
# endpoints take no request body, and the provider then omits Content-Type,
# which netcup rejects with HTTP 400 - so those two calls use scp-api.sh.

locals {
  scp_api = "https://www.servercontrolpanel.de/scp-core/api/v1"
  scp_idp = "https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect"

  # A real script rather than a heredoc: no HCL escaping, and shellcheck sees it.
  scp_api_sh = "${path.module}/scripts/scp-api.sh"
}

# Rescue can only be toggled while the server is SHUTOFF; on a running server the
# API answers HTTP 400 server.rescuesystem.invalidstate.
resource "netcup_scp_server_action" "power_off_for_rescue" {
  for_each = local.nodes

  server_id = each.value.id
  action    = "stop"
  arguments = { state_option = "POWEROFF" }
  triggers  = { node = each.key }

  # Firewall first: it applies inside the rescue system too, so root SSH with
  # password auth is never exposed to the internet.
  depends_on = [
    netcup_scp_user_firewall_policy.talos,
    netcup_scp_server_interface_firewall.node,
    terraform_data.firewall_reapply,
  ]
}

resource "terraform_data" "rescue_activate" {
  for_each = local.nodes

  triggers_replace = { node = each.key, server = each.value.id }
  depends_on       = [netcup_scp_server_action.power_off_for_rescue]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REFRESH_TOKEN = var.netcup_refresh_token
    }
    command = "'${local.scp_api_sh}' POST '/servers/${each.value.id}/rescuesystem'"
  }
}

resource "netcup_scp_server_action" "power_on_rescue" {
  for_each = local.nodes

  server_id  = each.value.id
  action     = "start"
  triggers   = { node = each.key }
  depends_on = [terraform_data.rescue_activate]
}

# Read at apply time, not at plan time: the password only exists once the rescue
# system is active.
data "netcup_scp_server_rescuesystem" "node" {
  for_each = local.nodes

  server_id  = each.value.id
  depends_on = [netcup_scp_server_action.power_on_rescue]
}

resource "terraform_data" "install" {
  for_each = local.nodes

  lifecycle {
    precondition {
      condition = anytrue([
        try(local.servers_by_name[each.value.name].nickname, "") == "",
        startswith(try(local.servers_by_name[each.value.name].nickname, ""), "${var.cluster_name}/"),
      ])
      error_message = "Server ${each.value.name} carries the nickname '${try(local.servers_by_name[each.value.name].nickname, "")}', so it belongs to another cluster. This step would write an operating system onto its disk. Rename it in the SCP, or pick a different server."
    }
  }

  # NOT keyed on the image: a bumped version must not dd every node in
  # parallel. Talos upgrades in place, see netcup/upgrade-talos.sh. To force a
  # reinstall: tofu apply -replace='terraform_data.install["worker-1"]'
  triggers_replace = {
    node = each.key
    ip   = each.value.ip
  }

  connection {
    type = "ssh"
    host = each.value.ip
    user = "root"
    # The rescue system gets no keys from the netcup key store, so password
    # auth only - and agent = false, or MaxAuthTries is spent on local keys.
    password = data.netcup_scp_server_rescuesystem.node[each.key].password
    agent    = false
    # sshd starts before the root password is set, so early attempts fail.
    timeout = "15m"
  }

  provisioner "remote-exec" {
    inline = [
      "grep -q grml /proc/mounts || { echo 'not in the rescue system' >&2; exit 1; }",
      "set -euo pipefail; curl -sfL '${local.image_url}' | zstd -d | dd of=/dev/vda bs=4M conv=fsync status=none; sync",
    ]
  }
}

resource "netcup_scp_server_action" "power_off_after_install" {
  for_each = local.nodes

  server_id  = each.value.id
  action     = "stop"
  arguments  = { state_option = "POWEROFF" }
  triggers   = { node = each.key }
  depends_on = [terraform_data.install]
}

resource "terraform_data" "rescue_deactivate" {
  for_each = local.nodes

  triggers_replace = { node = each.key, server = each.value.id }
  depends_on       = [netcup_scp_server_action.power_off_after_install]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REFRESH_TOKEN = var.netcup_refresh_token
    }
    command = "'${local.scp_api_sh}' DELETE '/servers/${each.value.id}/rescuesystem'"
  }
}

resource "netcup_scp_server_action" "boot_talos" {
  for_each = local.nodes

  server_id  = each.value.id
  action     = "start"
  triggers   = { node = each.key }
  depends_on = [terraform_data.rescue_deactivate]
}
