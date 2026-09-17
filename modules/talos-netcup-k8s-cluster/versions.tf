# Requirements only, no provider blocks: a module that configures its own
# providers cannot be used with count, for_each or an aliased provider.
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    talos = { source = "siderolabs/talos", version = "0.11.0" }

    # Third-party and pinned exactly: it receives the refresh token, which
    # grants full control over the servers. Review the diff before bumping.
    netcup = { source = "rixlhq/netcup", version = "1.2.1" }

    http   = { source = "hashicorp/http", version = "~> 3.5" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
    random = { source = "hashicorp/random", version = "~> 3.6" }

    # Renders charts locally only, never talks to a cluster.
    helm = { source = "hashicorp/helm", version = "~> 3.3" }
  }
}
