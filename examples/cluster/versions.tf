terraform {
  required_version = ">= 1.12.0"

  required_providers {
    talos  = { source = "siderolabs/talos", version = "0.11.0" }
    netcup = { source = "rixlhq/netcup", version = "1.2.1" }
    http   = { source = "hashicorp/http", version = "~> 3.5" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
    helm   = { source = "hashicorp/helm", version = "~> 3.3" }
  }
}
