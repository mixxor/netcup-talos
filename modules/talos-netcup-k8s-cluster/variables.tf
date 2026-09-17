# Declared, never inferred - see nodes.tf.
variable "control_plane_servers" {
  description = "netcup server names (v2202...) that become control plane nodes. Order decides the names: the first becomes cp-1."
  type        = list(string)

  validation {
    condition     = length(var.control_plane_servers) % 2 == 1
    error_message = "etcd needs an odd number of control plane nodes (1, 3, 5)."
  }

  validation {
    condition     = length(distinct(var.control_plane_servers)) == length(var.control_plane_servers)
    error_message = "control_plane_servers contains duplicates."
  }
}

variable "worker_servers" {
  description = "netcup server names (v2202...) that become worker nodes. Order decides the names: the first becomes worker-1."
  type        = list(string)

  validation {
    condition     = length(distinct(var.worker_servers)) == length(var.worker_servers)
    error_message = "worker_servers contains duplicates."
  }
}

variable "talos_extensions" {
  description = "Talos system extensions baked into the image. iscsi-tools and util-linux-tools are required by Longhorn."
  type        = list(string)
  default = [
    "siderolabs/iscsi-tools",
    "siderolabs/util-linux-tools",
    "siderolabs/qemu-guest-agent",
  ]
}

variable "netcup_user_id" {
  description = "SCP user id, NOT the customer number. netcup/00-auth.sh writes it to .env and netcup/env.sh exports it as TF_VAR_netcup_user_id."
  type        = number
}

variable "netcup_refresh_token" {
  description = "Offline refresh token produced by netcup/00-auth.sh. Pass it via TF_VAR_netcup_refresh_token."
  type        = string
  sensitive   = true
}

# The firewall is default-deny; an ingress controller is the usual reason to
# open anything. Whatever listens here must run on every node.
variable "public_ingress_ports" {
  description = "TCP ports opened on every node, e.g. [\"80\", \"443\"] for an ingress controller."
  type        = list(string)
  default     = []
}

# Behind a proxy or load balancer, put its addresses here - then nobody can
# bypass it through a node IP. One firewall rule per port and source.
variable "public_ingress_sources" {
  description = "CIDRs allowed to reach public_ingress_ports."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.public_ingress_sources) > 0
    error_message = "public_ingress_sources must not be empty; use [\"0.0.0.0/0\"] for the whole internet."
  }
}

# On top of admin_cidr, for a load balancer or bastion in front of the API.
variable "api_ingress_sources" {
  description = "Additional CIDRs allowed to reach the Kubernetes API port."
  type        = list(string)
  default     = []
}

# Your own rules, added to the ones this module needs.
#
# Position matters, because netcup evaluates top to bottom. They are inserted
# after everything the cluster itself requires and before the outbound mail
# block and the general egress accept - so an INGRESS ACCEPT works, and so does
# an EGRESS DROP. What you cannot do from here is override a rule the cluster
# needs; those come first on purpose.
#
# A rule with several sources is expanded into one rule per source, because the
# provider models "sources" as a list while the API treats it as a set, and
# anything else drifts on every plan.
variable "extra_firewall_rules" {
  description = "Additional firewall rules, appended to the ones the cluster needs."
  type = list(object({
    description       = optional(string, "")
    direction         = string
    protocol          = string
    action            = optional(string, "ACCEPT")
    sources           = optional(list(string), [])
    destinations      = optional(list(string), [])
    source_ports      = optional(string)
    destination_ports = optional(string)
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.extra_firewall_rules : contains(["INGRESS", "EGRESS"], r.direction)])
    error_message = "direction must be INGRESS or EGRESS."
  }

  validation {
    condition     = alltrue([for r in var.extra_firewall_rules : contains(["ACCEPT", "DROP"], r.action)])
    error_message = "action must be ACCEPT or DROP."
  }
}

variable "admin_cidr" {
  description = "Source allowed to reach SSH, 6443 and 50000. Empty means: look the address up at apply time."
  type        = string
  default     = ""
}

# Servers cannot be deleted through the API, so an empty disk on a powered-off
# machine is as close to as-delivered as this platform gets.
#
# Must be APPLIED before it affects a later destroy: destroy-time provisioners
# replay what was in state, so "tofu destroy -var teardown_wipe_disk=true"
# silently does nothing. Same for on_destroy in talos.tf.
# Draining before a reset needs to reach the cluster, and the credentials are
# written by the calling configuration - so it has to say where they are. Empty
# disables the drain, which is what examples without them get.
variable "kubeconfig_path" {
  description = "Path to the kubeconfig, used to drain a node before it is reset. Empty disables draining."
  type        = string
  default     = ""
}

variable "talosconfig_path" {
  description = "Path to the talosconfig, used for etcd leave when a control plane node is removed."
  type        = string
  default     = ""
}

variable "drain_on_destroy" {
  description = "Drain a node and evacuate its Longhorn replicas before OpenTofu resets it."
  type        = bool
  default     = true
}

variable "teardown_wipe_disk" {
  description = "Format /dev/vda on destroy. Must be applied BEFORE the destroy - see the comment above."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "Cluster name. Also used as the netcup firewall policy name and as the nickname prefix in SCP."
  type        = string
  default     = "netcup-talos"
}

# Both optional: without them the endpoint is the first control plane's IP.
variable "cluster_endpoint" {
  description = "Kubernetes API endpoint. Empty uses the first control plane IP, which needs no DNS at all."
  type        = string
  default     = ""

  validation {
    condition     = var.cluster_endpoint == "" || can(regex("^https://.+:[0-9]+$", var.cluster_endpoint))
    error_message = "cluster_endpoint must be an https:// URL including the port, or empty."
  }
}

variable "cluster_domain" {
  description = "Optional DNS name for the API, added to the certificate SANs. Empty means no DNS: reach the API by control plane IP."
  type        = string
  default     = ""
}

variable "talos_version" {
  type    = string
  default = "v1.14.0"
}

# Pinned explicitly: the provider ships an older version table and would
# quietly settle on something else.
variable "kubernetes_version" {
  type    = string
  default = "v1.37.0"
}

# Cilium is not an add-on like the others: without a CNI the nodes stay
# NotReady. The switch is for people bringing their own.
variable "install_cilium" {
  description = "Install Cilium as the CNI. Turning this off leaves the nodes NotReady until some other CNI is applied."
  type        = bool
  default     = true
}

variable "install_longhorn" {
  description = "Install Longhorn for replicated block storage. Needs the iscsi-tools and util-linux-tools extensions in talos_extensions."
  type        = bool
  default     = true
}

# Empty by default: a target that does not resolve logs errors forever, and
# netcup has no object storage. Put it somewhere the cluster's failure cannot
# reach - replicas are not a backup.
variable "longhorn_backup_target" {
  description = "Longhorn backup target URL, e.g. s3://bucket@region/prefix or nfs://host/export. Empty disables backups."
  type        = string
  default     = ""
}

variable "longhorn_backup_target_secret" {
  description = "Name of the Secret in longhorn-system holding the backup credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, optionally AWS_ENDPOINTS). Create it outside this module - it is not put into the machine config."
  type        = string
  default     = ""

  validation {
    condition     = var.longhorn_backup_target == "" || !startswith(var.longhorn_backup_target, "s3://") || var.longhorn_backup_target_secret != ""
    error_message = "An s3:// backup target needs longhorn_backup_target_secret."
  }
}

# A DaemonSet on hostPort, because a Service of type LoadBalancer would stay
# pending forever. Traefik rather than ingress-nginx, which is retired.
variable "install_traefik" {
  description = "Install Traefik as a DaemonSet on hostPort 80/443. Needs public_ingress_ports to open the firewall."
  type        = bool
  default     = false
}

variable "traefik_version" {
  type    = string
  default = "41.6.0"
}

# ~440 KB into every node's machine config, which is otherwise ~310 KB. Off
# means plain Ingress resources only.
variable "traefik_install_crds" {
  description = "Install Traefik's CRDs and enable its CRD provider. Adds ~440 KB to every node's machine config."
  type        = bool
  default     = true
}

# Otherwise every request appears to come from the proxy.
variable "ingress_trusted_proxy_cidrs" {
  description = "CIDRs whose X-Forwarded-For Traefik should trust, e.g. Cloudflare's ranges. Empty disables forwarded headers."
  type        = list(string)
  default     = []
}

# ArgoCD, so the cluster can manage its own workloads afterwards.
#
# This is the only part of GitOps that cannot itself be GitOps: something has to
# install ArgoCD before ArgoCD can install anything. Everything after that comes
# from argocd_apps_repo.
variable "install_argocd" {
  description = "Install ArgoCD as an inline manifest, so the cluster can bootstrap its own workloads."
  type        = bool
  default     = false
}

variable "argocd_version" {
  type    = string
  default = "9.3.4"
}

# The App-of-Apps root: one Application pointing at a directory of
# ApplicationSets. Empty means ArgoCD is installed but manages nothing yet.
variable "argocd_apps_repo" {
  description = "Git repository holding the ApplicationSets, e.g. your fork of this one. Empty installs ArgoCD without any applications."
  type        = string
  default     = ""
}

variable "argocd_apps_path" {
  description = "Path inside argocd_apps_repo that holds the ApplicationSets."
  type        = string
  default     = "gitops/applicationsets"
}

variable "argocd_apps_revision" {
  type    = string
  default = "main"
}

variable "install_local_path" {
  description = "Install local-path-provisioner: node-local storage, 13x faster than Longhorn but gone with the node. Not the default StorageClass."
  type        = bool
  default     = true
}

variable "local_path_version" {
  type    = string
  default = "v0.0.37"
}

variable "install_metrics_server" {
  description = "Install metrics-server, which is what makes 'kubectl top' and the resource view in k9s work."
  type        = bool
  default     = true
}

variable "cilium_version" {
  type    = string
  default = "1.20.1"
}

# More replicas than workers means every volume stays degraded forever.
variable "longhorn_replica_count" {
  description = "Longhorn replicas per volume. Must not exceed the number of worker nodes."
  type        = number
  default     = 3
}

variable "longhorn_version" {
  type    = string
  default = "1.12.1"
}

variable "metrics_server_version" {
  type    = string
  default = "3.14.0"
}
