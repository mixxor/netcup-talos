# A load balancer on a plain netcup VPS, because netcup offers none.
#
# The OS comes from netcup's own installer (POST /servers/{id}/image), which
# takes an image flavour, hostname, SSH keys and a post-install script. That
# path only accepts netcup images - hence rescue plus dd for the Talos nodes.

locals {
  server_id = var.server_id
  ip        = var.server_ip
  mac       = var.server_mac
}

locals {
  # One rule per source, for the reason given at the variable.
  extra_firewall_rules_expanded = flatten([
    for r in var.extra_firewall_rules :
    length(r.sources) <= 1 ? [r] : [
      for src in r.sources : merge(r, {
        description = "${r.description} from ${src}"
        sources     = [src]
      })
    ]
  ])

  # Same shape and the same reasons as the cluster policy in netcup.tf.
  firewall_rules = concat(
    [
      { description = "ssh (admin)", direction = "INGRESS", protocol = "TCP", action = "ACCEPT", sources = [var.admin_cidr], destination_ports = "22" },
      { description = "http", direction = "INGRESS", protocol = "TCP", action = "ACCEPT", destination_ports = "80" },
      { description = "https", direction = "INGRESS", protocol = "TCP", action = "ACCEPT", destination_ports = "443" },
    ],
    length(var.api_backends) == 0 ? [] : [
      { description = "kube-apiserver (admin)", direction = "INGRESS", protocol = "TCP", action = "ACCEPT", sources = [var.admin_cidr], destination_ports = tostring(var.api_port) },
    ],
    local.extra_firewall_rules_expanded,

    [
      { description = "icmp in", direction = "INGRESS", protocol = "ICMP", action = "ACCEPT" },
      { description = "icmpv6 in", direction = "INGRESS", protocol = "ICMPv6", action = "ACCEPT" },
      { description = "icmp out", direction = "EGRESS", protocol = "ICMP", action = "ACCEPT" },
      { description = "icmpv6 out", direction = "EGRESS", protocol = "ICMPv6", action = "ACCEPT" },

      # Without this the DHCP lease is never renewed.
      { description = "dhcp client", direction = "INGRESS", protocol = "UDP", action = "ACCEPT", destination_ports = "68" },

      # The firewall is stateful for TCP but not for UDP. destination_ports
      # matters: without it these accept any UDP port from anyone who sets the
      # right source port, which is the whole of UDP on a public machine.
      { description = "ntp replies", direction = "INGRESS", protocol = "UDP", action = "ACCEPT", source_ports = "123", destination_ports = "32768-60999" },
      { description = "ntp replies symmetric", direction = "INGRESS", protocol = "UDP", action = "ACCEPT", source_ports = "123", destination_ports = "123" },
      { description = "dns replies", direction = "INGRESS", protocol = "UDP", action = "ACCEPT", source_ports = "53", destination_ports = "32768-60999" },

      # netcup's own mail block, reproduced because attaching a user policy
      # drops their copied policies. Must precede the general egress accept.
      { description = "no outbound smtp", direction = "EGRESS", protocol = "TCP", action = "DROP", destination_ports = "25" },
      { description = "no outbound smtps", direction = "EGRESS", protocol = "TCP", action = "DROP", destination_ports = "465" },
      { description = "no outbound submission", direction = "EGRESS", protocol = "TCP", action = "DROP", destination_ports = "587" },

      { description = "egress tcp", direction = "EGRESS", protocol = "TCP", action = "ACCEPT" },
      { description = "egress udp", direction = "EGRESS", protocol = "UDP", action = "ACCEPT" },
    ],
  )
}

# Same as in the cluster module: names are not unique, so a lost state leaves
# duplicates rather than an error.
data "netcup_scp_user_firewall_policies" "all" {
  user_id = var.netcup_user_id
}

locals {
  same_name_policies = [
    for p in data.netcup_scp_user_firewall_policies.all.scp_user_firewall_policies :
    p.id if p.name == var.name
  ]
}

check "no_duplicate_firewall_policy" {
  assert {
    condition     = length(local.same_name_policies) <= 1
    error_message = "netcup has ${length(local.same_name_policies)} firewall policies named ${var.name}. Delete the ones no interface uses - see README, 'Losing the state'."
  }
}

resource "netcup_scp_user_firewall_policy" "lb" {
  user_id     = var.netcup_user_id
  name        = var.name
  description = "haproxy load balancer, managed by OpenTofu"
  rules       = local.firewall_rules
}

resource "netcup_scp_server_interface_firewall" "lb" {
  server_id       = local.server_id
  mac             = local.mac
  active          = true
  user_policy_ids = [netcup_scp_user_firewall_policy.lb.id]

  # Before the teardown powers the machine off: netcup locks it during a power
  # task and rejects a concurrent firewall delete with HTTP 409, unretried.
  # Measured cost: about seven seconds of ACCEPT_ALL on 22, 80 and 443 before
  # the power-off. SSH there is key-only and the disk is wiped right after.
  depends_on = [terraform_data.teardown]
}

# For the ownership guard below only. Everything else is a plain input, which
# is what lets this module carry depends_on without churning on every plan.
data "netcup_scp_servers" "all" {}

locals {
  this_server = one([
    for s in data.netcup_scp_servers.all.scp_servers : s if s.id == local.server_id
  ])
}

resource "netcup_scp_server" "lb" {
  server_id = local.server_id
  nickname  = var.name

  depends_on = [terraform_data.teardown]

  # Here rather than on the install step: this resource claims the server and
  # would overwrite a foreign nickname before the guard could read it.
  lifecycle {
    precondition {
      condition = anytrue([
        try(local.this_server.nickname, "") == "",
        try(local.this_server.nickname, "") == var.name,
      ])
      error_message = "Server ${var.hostname} carries the nickname '${try(local.this_server.nickname, "")}', so something else already claims it. This step would install Debian over whatever is on its disk. Clear the nickname in the SCP, or pick a different server."
    }
  }
}

# netcup installs the OS, boots it and injects the SSH keys.
resource "netcup_scp_server_action" "install" {
  server_id = local.server_id
  action    = "image_setup"

  body = jsonencode({
    imageFlavourId            = var.image_flavour_id
    diskName                  = "vda"
    rootPartitionFullDiskSize = true
    hostname                  = var.hostname
    locale                    = "en_US.UTF-8"
    timezone                  = "Europe/Berlin"
    sshKeyIds                 = var.ssh_key_ids
    sshPasswordAuthentication = false
    emailToExecutingUser      = false

    # Package only; the configuration is pushed separately, see haproxy.tf.
    customScript = <<-SH
      #!/bin/bash
      set -eux
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y haproxy unattended-upgrades

      # These are public machines on ports 22, 80 and 443, and nothing else
      # here ever patches them.
      printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' \
        'APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades
      systemctl enable unattended-upgrades

      systemctl enable haproxy
    SH
  })

  # SSH has to be allowed before anything connects.
  depends_on = [netcup_scp_server_interface_firewall.lb]
}
