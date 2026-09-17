# Provider configuration lives here, not in the module. That is what lets the
# module be used more than once - with count, for_each, or with two aliased
# netcup providers for two accounts.

provider "netcup" {
  scp_refresh_token = var.netcup_refresh_token
}

provider "helm" {
  # No kubernetes block on purpose: the module only renders charts locally
  # (data "helm_template") and never talks to a cluster. That is precisely
  # what makes a single apply work - see modules/talos-netcup-k8s-cluster/manifests.tf.
}
