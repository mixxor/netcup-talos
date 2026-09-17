# The declarative netcup side: firewall and server attributes.

# Source allowed to reach SSH, 6443 and 50000. Left empty it is resolved at apply
# time, so a changed home IP does not lock you out permanently.
data "http" "my_ip" {
  count = var.admin_cidr == "" ? 1 : 0
  # IPv4 only: a v6 answer would become "<v6>/32", a valid CIDR covering an
  # ISP-sized block.
  url = "https://ipv4.icanhazip.com"
}

locals {
  admin_cidr = var.admin_cidr != "" ? var.admin_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"

  node_cidrs = [for v in local.nodes : "${v.ip}/32"]
  cp_cidrs   = [for v in local.cp_nodes : "${v.ip}/32"]

  # One rule per source throughout. The API treats "sources" as a set and
  # reorders it, the provider models it as a list, and any rule with more than
  # one source then drifts forever ("Provider produced inconsistent result").
  node_rules = [
    { description = "kube-apiserver", protocol = "TCP", ports = "6443", srcs = local.node_cidrs },
    { description = "talos api", protocol = "TCP", ports = "50000", srcs = local.node_cidrs },

    # trustd: workers fetch their apid certificate here. Without it apid never
    # starts on them and talosctl cannot reach the workers at all.
    { description = "trustd", protocol = "TCP", ports = "50001", srcs = local.node_cidrs },

    { description = "etcd", protocol = "TCP", ports = "2379-2380", srcs = local.cp_cidrs },
    { description = "kubelet", protocol = "TCP", ports = "10250", srcs = local.node_cidrs },
    { description = "cilium health", protocol = "TCP", ports = "4240", srcs = local.node_cidrs },
    { description = "cilium wireguard", protocol = "UDP", ports = "51871", srcs = local.node_cidrs },
    { description = "cilium vxlan", protocol = "UDP", ports = "8472", srcs = local.node_cidrs },
  ]

  # 0.0.0.0/0 is spelled out rather than implied by an empty list.
  public_ingress_rules = flatten([
    for port in var.public_ingress_ports : [
      for src in var.public_ingress_sources : {
        description       = "public ingress ${port} from ${src}"
        direction         = "INGRESS"
        protocol          = "TCP"
        action            = "ACCEPT"
        sources           = [src]
        destination_ports = port
      }
    ]
  ])

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

  node_rules_expanded = flatten([
    for r in local.node_rules : [
      for src in r.srcs : {
        description       = "${r.description} from ${src}"
        direction         = "INGRESS"
        protocol          = r.protocol
        action            = "ACCEPT"
        sources           = [src]
        destination_ports = r.ports
      }
    ]
  ])

  # Order matters: rules are evaluated top to bottom, so the SMTP block has to
  # come before the general egress allow.
  firewall_rules = concat(
    # ------------------------------------------------------------ from outside
    # Talos runs no sshd; this is for the rescue system during installation,
    # which is why the firewall is applied BEFORE the install.
    [
      { description = "ssh rescue system (admin)", direction = "INGRESS", protocol = "TCP", action = "ACCEPT", sources = [local.admin_cidr], destination_ports = "22" },
      { description = "kube-apiserver (admin)", direction = "INGRESS", protocol = "TCP", action = "ACCEPT", sources = [local.admin_cidr], destination_ports = "6443" },
      { description = "talos api (admin)", direction = "INGRESS", protocol = "TCP", action = "ACCEPT", sources = [local.admin_cidr], destination_ports = "50000" },
    ],

    # -------------------------------------------------------- between the nodes
    # Public ingress.
    local.public_ingress_rules,

    # A load balancer or bastion in front of the API.
    [for src in var.api_ingress_sources : {
      description       = "kube-apiserver from ${src}"
      direction         = "INGRESS"
      protocol          = "TCP"
      action            = "ACCEPT"
      sources           = [src]
      destination_ports = "6443"
    }],

    local.node_rules_expanded,

    # --------------------------------------------------- close the tunnel again
    # The UDP reply rules below accept from any address - a stateless firewall
    # cannot match a reply to a request - so source port 53 or 123 would reach
    # the two ports above, which VXLAN leaves unauthenticated. After the node
    # rules, so node to node still matches the ACCEPT first. Narrowing the
    # replies alone is not enough: 51871 lies inside the ephemeral range.
    [
      { description = "no vxlan from outside", direction = "INGRESS", protocol = "UDP", action = "DROP", destination_ports = "8472" },
      { description = "no wireguard from outside", direction = "INGRESS", protocol = "UDP", action = "DROP", destination_ports = "51871" },
    ],

    # ------------------------------------------------------------- yours, added
    local.extra_firewall_rules_expanded,

    # -------------------------------------------------------------------- ICMP
    # netcup's "Ping allow" is dropped as soon as you attach your own policy.
    [
      { description = "icmp in", direction = "INGRESS", protocol = "ICMP", action = "ACCEPT" },
      { description = "icmpv6 in", direction = "INGRESS", protocol = "ICMPv6", action = "ACCEPT" },
      { description = "icmp out", direction = "EGRESS", protocol = "ICMP", action = "ACCEPT" },
      { description = "icmpv6 out", direction = "EGRESS", protocol = "ICMPv6", action = "ACCEPT" },
    ],

    # -------------------------------------------------------------------- DHCP
    # Without this the node never gets or renews its IPv4 address.
    [
      { description = "dhcp client", direction = "INGRESS", protocol = "UDP", action = "ACCEPT", destination_ports = "68" },
    ],

    # ------------------------------------------------------------ UDP replies
    # Stateful for TCP but not for UDP: without these, NTP and DNS replies never
    # return and the node hangs in STAGE "Booting" with no useful log.
    #
    # destination_ports narrows them to where a reply can land: the client's
    # ephemeral port, 32768-60999 on Linux.
    [
      { description = "ntp replies", direction = "INGRESS", protocol = "UDP", action = "ACCEPT", source_ports = "123", destination_ports = "32768-60999" },
      # An NTP client that keeps 123 as its source port answers there instead.
      { description = "ntp replies symmetric", direction = "INGRESS", protocol = "UDP", action = "ACCEPT", source_ports = "123", destination_ports = "123" },
      { description = "dns replies", direction = "INGRESS", protocol = "UDP", action = "ACCEPT", source_ports = "53", destination_ports = "32768-60999" },
    ],

    # ------------------------------------------------------------------ egress
    # netcup's "Mail block", reproduced. Must precede the general allow.
    [
      { description = "no outbound smtp", direction = "EGRESS", protocol = "TCP", action = "DROP", destination_ports = "25" },
      { description = "no outbound smtps", direction = "EGRESS", protocol = "TCP", action = "DROP", destination_ports = "465" },
      { description = "no outbound submission", direction = "EGRESS", protocol = "TCP", action = "DROP", destination_ports = "587" },
    ],

    # A user policy flips BOTH implicit rules to DROP_ALL, egress included.
    [
      { description = "egress tcp", direction = "EGRESS", protocol = "TCP", action = "ACCEPT" },
      { description = "egress udp", direction = "EGRESS", protocol = "UDP", action = "ACCEPT" },
    ],
  )
}

# Policy names are NOT unique at netcup, so a lost state file plus an apply
# silently creates a second policy with the same name and leaves the first one
# attached to nothing. Nobody notices until the list is full of them.
data "netcup_scp_user_firewall_policies" "all" {
  user_id = var.netcup_user_id
}

locals {
  same_name_policies = [
    for p in data.netcup_scp_user_firewall_policies.all.scp_user_firewall_policies :
    p.id if p.name == var.cluster_name
  ]
}

check "no_duplicate_firewall_policy" {
  assert {
    condition     = length(local.same_name_policies) <= 1
    error_message = "netcup has ${length(local.same_name_policies)} firewall policies named ${var.cluster_name} (ids ${join(", ", [for i in local.same_name_policies : tostring(i)])}). Policy names are not unique, so this is what a lost state file leaves behind. Delete the ones no interface uses - see README, 'Losing the state'."
  }
}

# Blocking: a wrong admin_cidr either locks you out mid-install, or opens 22,
# 6443 and 50000 to far more than one address.
resource "terraform_data" "admin_cidr_is_ipv4" {
  input = local.admin_cidr

  lifecycle {
    precondition {
      condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", local.admin_cidr))
      error_message = "admin_cidr is '${local.admin_cidr}', which is not an IPv4 CIDR. Set admin_cidr explicitly, or check what https://ipv4.icanhazip.com returns for you."
    }
  }
}

resource "netcup_scp_user_firewall_policy" "talos" {
  user_id     = var.netcup_user_id
  name        = var.cluster_name
  description = "Talos cluster nodes, managed by OpenTofu"
  rules       = local.firewall_rules
}

# Assigning a user policy removes netcup's copied policies, which is why their
# rules are reproduced above.
resource "netcup_scp_server_interface_firewall" "node" {
  for_each = local.nodes

  server_id       = each.value.id
  mac             = each.value.mac
  active          = true
  user_policy_ids = [netcup_scp_user_firewall_policy.talos.id]

  # Before the teardown powers the server off: netcup locks it during a power
  # task and answers a concurrent firewall delete with HTTP 409, which the
  # provider does not retry. The cost is a few seconds of ACCEPT_ALL on a node
  # that is about to be reset - what is open in it is the mTLS Talos API.
  depends_on = [terraform_data.teardown]
}

# Cosmetic: otherwise the SCP lists indistinguishable v2202... strings.
resource "netcup_scp_server" "node" {
  for_each = local.nodes

  server_id = each.value.id
  nickname  = "${var.cluster_name}/${each.key}"

  # See above.
  depends_on = [terraform_data.teardown]
}

# netcup does not pick up changed rules on a running interface by itself.
# Triggering on a hash of the rules makes that automatic.
#
# Not the provider's firewall_reapply action: it sends no body, and without one
# the provider omits Content-Type, which netcup rejects with HTTP 400.
resource "terraform_data" "firewall_reapply" {
  for_each = local.nodes

  triggers_replace = {
    rules = sha256(jsonencode(local.firewall_rules))
  }

  depends_on = [netcup_scp_server_interface_firewall.node]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REFRESH_TOKEN = var.netcup_refresh_token
    }
    command = "'${local.scp_api_sh}' POST '/servers/${each.value.id}/interfaces/${each.value.mac}/firewall:reapply'"
  }
}
