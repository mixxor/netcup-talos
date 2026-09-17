# Credentials on disk - what you point kubectl, talosctl and k9s at.
#
# This lives in the calling configuration on purpose. Inside the module,
# path.module would point into .terraform/modules/... once the module is
# consumed remotely, and the files would land in a directory that the next
# "tofu init" throws away.
#
# One directory per cluster, so nothing overwrites anything.
resource "local_sensitive_file" "kubeconfig" {
  for_each = module.cluster

  filename        = "${var.generated_dir}/${each.key}/kubeconfig"
  content         = each.value.kubeconfig
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  for_each = module.cluster

  filename        = "${var.generated_dir}/${each.key}/talosconfig"
  content         = each.value.talosconfig
  file_permission = "0600"
}
