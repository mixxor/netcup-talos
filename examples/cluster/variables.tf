# Account-wide, the same for every cluster in this configuration.

variable "netcup_refresh_token" {
  description = "Offline refresh token produced by netcup/00-auth.sh. Pass it via TF_VAR_netcup_refresh_token, never in a tfvars file."
  type        = string
  sensitive   = true
}

variable "netcup_user_id" {
  description = "SCP user id, NOT the customer number. netcup/00-auth.sh writes it to .env and netcup/env.sh exports it as TF_VAR_netcup_user_id."
  type        = number
}

variable "admin_cidr" {
  description = "Source allowed to reach SSH, 6443 and 50000. Empty means: look the address up at apply time."
  type        = string
  default     = ""
}

variable "generated_dir" {
  description = "Where credentials are written: one directory per cluster, generated/<cluster name>/."
  type        = string
  default     = "../../generated"
}

# One entry is one cluster. Two entries are two clusters, side by side in the
# same account - the key decides the firewall policy name, the nickname prefix
# in SCP and the credential directory, so nothing collides.
#
# Everything except the two server lists has a working default, which is why
# the smallest useful tfvars is four lines long.
variable "clusters" {
  description = "Clusters to create, keyed by name."

  type = map(object({
    # Careful: an apply overwrites /dev/vda on every server listed here.
    control_plane_servers = list(string)
    worker_servers        = list(string)

    # Both empty means no DNS: the endpoint becomes the first control plane IP,
    # which is already in the certificate SANs.
    cluster_endpoint = optional(string, "")
    cluster_domain   = optional(string, "")

    # The node firewall is default-deny. An ingress controller is the usual
    # reason to open anything, and whatever listens must run on every node.
    public_ingress_ports        = optional(list(string), [])
    public_ingress_sources      = optional(list(string), ["0.0.0.0/0"])
    api_ingress_sources         = optional(list(string), [])
    ingress_trusted_proxy_cidrs = optional(list(string), [])

    # Appended after everything the cluster needs and before the egress rules,
    # so an INGRESS ACCEPT and an EGRESS DROP both work.
    extra_firewall_rules = optional(list(object({
      description       = optional(string, "")
      direction         = string
      protocol          = string
      action            = optional(string, "ACCEPT")
      sources           = optional(list(string), [])
      destinations      = optional(list(string), [])
      source_ports      = optional(string)
      destination_ports = optional(string)
    })), [])

    talos_version      = optional(string, "v1.14.0")
    kubernetes_version = optional(string, "v1.37.0")

    # Cilium is not optional here: without a CNI nothing becomes Ready, and
    # then nothing could install a CNI either.
    install_longhorn       = optional(bool, true)
    install_local_path     = optional(bool, true)
    install_metrics_server = optional(bool, true)
    install_traefik        = optional(bool, false)
    install_argocd         = optional(bool, false)

    longhorn_replica_count        = optional(number, 3)
    longhorn_backup_target        = optional(string, "")
    longhorn_backup_target_secret = optional(string, "")

    # The App-of-Apps root. Empty installs ArgoCD managing nothing, which is a
    # reasonable place to start.
    argocd_apps_repo     = optional(string, "")
    argocd_apps_path     = optional(string, "gitops/applicationsets")
    argocd_apps_revision = optional(string, "main")

    # netcup has no load balancer, so ordinary servers become one. They are not
    # cluster members: they run Debian and haproxy, not Talos. Two entries mean
    # two A records for the same name.
    loadbalancer_servers      = optional(list(string), [])
    loadbalancer_serves_api   = optional(bool, false)
    loadbalancer_ssh_key_ids  = optional(list(number), [])
    loadbalancer_ssh_key_path = optional(string, "")

    teardown_wipe_disk = optional(bool, true)
  }))

  validation {
    condition = length(flatten([
      for c in var.clusters : concat(c.control_plane_servers, c.worker_servers, c.loadbalancer_servers)
      ])) == length(distinct(flatten([
        for c in var.clusters : concat(c.control_plane_servers, c.worker_servers, c.loadbalancer_servers)
    ])))
    error_message = "A server is listed more than once. Both uses would write an operating system onto the same disk."
  }

  validation {
    condition     = alltrue([for c in var.clusters : length(c.control_plane_servers) % 2 == 1])
    error_message = "etcd needs an odd number of control plane nodes (1, 3, 5)."
  }

  validation {
    condition     = alltrue([for c in var.clusters : c.longhorn_replica_count <= length(c.worker_servers)])
    error_message = "longhorn_replica_count must not exceed the number of workers, or every volume stays degraded forever."
  }
}
