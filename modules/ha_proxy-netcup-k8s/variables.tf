# Resolved values, not names. Looking them up inside this module would put data
# sources here, and a depends_on pointing at the cluster module then makes them
# unknown at plan time - which marks every resource for replacement and
# reinstalls the operating system on every cluster change. Learned the hard way.
variable "server_id" {
  description = "netcup server id that becomes the load balancer. Careful: an apply reinstalls its operating system."
  type        = number
}

variable "server_ip" {
  description = "Public IPv4 of that server."
  type        = string
}

variable "server_mac" {
  description = "MAC of that server's public interface, for the firewall assignment."
  type        = string
}

variable "name" {
  description = "Name for the firewall policy and the SCP nickname."
  type        = string
  default     = "haproxy-lb"
}

variable "hostname" {
  description = "Hostname written during the image install."
  type        = string
  default     = "haproxy"
}

variable "netcup_user_id" {
  description = "SCP user id, NOT the customer number. netcup/00-auth.sh writes it to .env and netcup/env.sh exports it as TF_VAR_netcup_user_id."
  type        = number
}

variable "netcup_refresh_token" {
  description = "Offline refresh token. Used by the local-exec that reapplies the firewall."
  type        = string
  sensitive   = true
}

variable "ssh_key_ids" {
  description = "netcup SSH key ids injected during the image install. GET /api/v1/users/{id}/ssh-keys lists them. Without at least one there is no way in - password auth is off."
  type        = list(number)

  validation {
    condition     = length(var.ssh_key_ids) > 0
    error_message = "At least one SSH key id is required; password authentication is disabled."
  }
}

# Debian 13.7.0 BIOS amd64, "minimal system with ssh preinstalled".
# GET /api/v1/servers/{id}/imageflavours lists what a given server can install.
# BIOS rather than UEFI to match how netcup delivers these VPS.
variable "image_flavour_id" {
  description = "netcup image flavour id to install."
  type        = number
  default     = 119
}

# Resolved by the caller rather than looked up here, for the same reason as the
# addresses above: no data sources in this module.
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

# Without this a destroy leaves the load balancer running - and deleting its
# firewall policy drops netcup back to ACCEPT_ALL, so the machine ends up on the
# internet with every port open and nothing in front of it. Measured, after a
# destroy that had no teardown: ingress=ACCEPT_ALL, ports 22, 80 and 443 open.
variable "teardown_wipe_disk" {
  description = "Power the load balancer off on destroy, and format its disk. Must be applied BEFORE the destroy."
  type        = bool
  default     = true
}

variable "admin_cidr" {
  description = "Source allowed to reach SSH on the load balancer."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be a CIDR, e.g. 203.0.113.7/32."
  }
}

# The cluster behind this load balancer.
#
# The cluster behind this load balancer, as addresses.
variable "http_backends" {
  description = "Map of label => IP for the HTTP/HTTPS backends, normally the workers running the ingress controller."
  type        = map(string)
  default     = {}
}

variable "api_backends" {
  description = "Map of label => IP for the Kubernetes API backends, normally the control plane. Empty disables the API frontend."
  type        = map(string)
  default     = {}
}

variable "api_port" {
  type    = number
  default = 6443
}

# How to authenticate when pushing the haproxy configuration.
#
# The default is the SSH agent, because a normal key has a passphrase and
# OpenTofu cannot ask for one - it fails with "this private key is passphrase
# protected". Add the key once with "ssh-add ~/.ssh/id_ed25519" and this works.
#
# Setting a path instead only helps for a key WITHOUT a passphrase, which is
# the wrong trade for a key that opens the load balancer.
variable "ssh_private_key_path" {
  description = "Path to an unencrypted private key. Empty (the default) uses the SSH agent instead."
  type        = string
  default     = ""
}
