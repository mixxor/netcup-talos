# The same teardown the cluster module has, for the same reason.
#
# Destroy-time provisioners may only read self, so everything they need is in
# input - including the path to the script, which is why it is stored rather
# than taken from path.module.
resource "terraform_data" "teardown" {
  input = {
    server_id = tostring(var.server_id)
    node      = var.name
    wipe      = tostring(var.teardown_wipe_disk)
    script    = "${path.module}/scripts/teardown-node.sh"
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
