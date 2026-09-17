# Taking a node out of Kubernetes before it is reset.
#
# Removing a name from worker_servers and applying is the whole procedure: this
# runs first, drains the node, evacuates its Longhorn replicas and deletes the
# node object. Without it, "tofu apply" would reset a node that is still running
# workloads and leave a NotReady object behind for ever.
#
# It has to be a provisioner rather than a Kubernetes resource. A Kubernetes
# provider needs its connection at plan time, and a cluster created in the same
# run cannot supply one - that is the whole reason this module gets away with a
# single apply.
#
# Ordering: depends_on makes this created after the machine configuration, and
# destroyed before it. That is exactly the order a drain needs.
#
# A full destroy skips it ("no readable kubeconfig"): the caller's credential
# files go first, and there is nowhere left to drain to anyway. This exists for
# removing one name from worker_servers, where the rest of the cluster stays up.
resource "terraform_data" "drain" {
  for_each = var.drain_on_destroy && var.kubeconfig_path != "" ? local.nodes : {}

  # Destroy-time provisioners may only read self, so everything goes in here.
  input = {
    node        = each.key
    ip          = each.value.ip
    role        = each.value.role
    kubeconfig  = var.kubeconfig_path
    talosconfig = var.talosconfig_path
    script      = "${path.module}/scripts/drain-node.sh"
  }

  depends_on = [
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker,
  ]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    environment = {
      NODE             = self.input.node
      NODE_IP          = self.input.ip
      NODE_ROLE        = self.input.role
      KUBECONFIG_PATH  = self.input.kubeconfig
      TALOSCONFIG_PATH = self.input.talosconfig
    }
    command = "'${self.input.script}'"
  }
}
