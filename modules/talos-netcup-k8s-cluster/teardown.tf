# What "tofu destroy" leaves behind: the Talos reset in talos.tf shuts the node
# down but leaves the installation on disk, so this formats /dev/vda as well.
#
# "input" rather than "triggers_replace": a changed trigger forces replacement,
# and replacing runs the destroy provisioner - which powers off a healthy
# cluster. input is readable as self.input during destroy and updates in place.
#
# Destroy-time provisioners may only reference self, so everything they need is
# stored in the resource and the token comes from the environment.
resource "terraform_data" "teardown" {
  for_each = local.nodes

  input = {
    server_id = tostring(each.value.id)
    node      = each.key
    wipe      = tostring(var.teardown_wipe_disk)

    # Stored here because a destroy provisioner cannot read path.module.
    script = "${path.module}/scripts/teardown-node.sh"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SERVER_ID = self.input.server_id
      NODE      = self.input.node
      WIPE      = self.input.wipe
    }
    command = "REFRESH_TOKEN=\"$TF_VAR_netcup_refresh_token\" '${self.input.script}'"
  }
}
