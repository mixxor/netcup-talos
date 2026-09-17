# Provider requirements only - no provider blocks, for the same reason as in
# modules/talos-netcup-k8s-cluster: a module that configures its own providers cannot be
# used with count or for_each.
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    netcup = { source = "rixlhq/netcup", version = "1.2.1" }
  }
}
