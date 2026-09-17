resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = local.all_ips
  endpoints            = local.cp_ips
}

locals {
  # Shared by every role. CNI and kube-proxy are disabled - Cilium provides both.
  # Without a vLAN all node-to-node traffic crosses the shared public /22, which
  # is why cilium.tf enables WireGuard encryption.
  common_patch = {
    machine = {
      install = {
        disk = "/dev/vda"
        # Factory installer carrying our schematic. The generic
        # ghcr.io/siderolabs/installer does not contain the extensions and would
        # silently drop them on the next "talosctl upgrade".
        image = local.installer_image
      }
      features = { kubePrism = { enabled = true, port = 7445 } }
      certSANs = local.cert_sans
    }
    cluster = {
      network = { cni = { name = "none" } }
      proxy   = { disabled = true }
    }
  }

  cp_extra_patch = {
    cluster = {
      # 4 GB of RAM per node: there is no room for workloads next to etcd.
      allowSchedulingOnControlPlanes = false
      apiServer                      = { certSANs = local.cert_sans }

      # Cilium, Longhorn and metrics-server, rendered locally in manifests.tf and
      # applied by Talos at bootstrap. This is what removes the need for the Helm
      # and Kubernetes providers - and with them the second apply.
      inlineManifests = local.inline_manifests
    }
  }

  worker_extra_patch = {
    machine = {
      # Only labelled nodes get a Longhorn default disk. Setting the label here
      # rather than through the Kubernetes provider keeps that provider out of
      # the picture entirely.
      nodeLabels = var.install_longhorn ? {
        "node.longhorn.io/create-default-disk" = "true"
      } : {}

      # Longhorn needs a bind-mounted, rshared data directory.
      kubelet = {
        extraMounts = [{
          destination = "/var/lib/longhorn"
          type        = "bind"
          source      = "/var/lib/longhorn"
          options     = ["bind", "rshared", "rw"]
        }]
      }
    }
  }
}

# One configuration per node, with a fixed hostname.
#
# Without it node names are not deterministic - Talos defaults to
# "auto: stable" and falls back to talos-xxx-yyy, which produces duplicate node
# objects and breaks Longhorn. auto = "off" is the only value that may be
# combined with a static hostname, and it must stay quoted: unquoted it is a
# YAML boolean. See siderolabs/talos#12573.
data "talos_machine_configuration" "controlplane" {
  for_each = local.cp_nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode(local.common_patch),
    yamlencode(local.cp_extra_patch),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = each.key
    }),
  ]
}

data "talos_machine_configuration" "worker" {
  for_each = local.worker_nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode(local.common_patch),
    yamlencode(local.worker_extra_patch),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = each.key
    }),
  ]
}

resource "talos_machine_configuration_apply" "controlplane" {
  for_each = local.cp_nodes

  # Without reset, "tofu destroy" is a no-op on the nodes - the cluster keeps
  # running while the firewall around it is torn down.
  #
  # graceful = false: a graceful reset leaves etcd first, which cannot work when
  # every member goes away at once.
  #
  # reboot = false halts instead of rebooting. A node in maintenance mode accepts
  # "apply-config --insecure", and destroy has already removed the firewall.
  #
  # Changes here only take effect once applied, before a later destroy.
  on_destroy = {
    reset    = true
    reboot   = false
    graceful = false
  }

  # Talos has to be on the disk and in maintenance mode first.
  #
  # terraform_data.teardown is listed so that destroy runs in the right order:
  # a dependency is destroyed after its dependents, so the node is reset first
  # and powered off or wiped afterwards.
  depends_on = [
    terraform_data.teardown,
  ]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
}

resource "talos_machine_configuration_apply" "worker" {
  for_each = local.worker_nodes

  # Without reset, "tofu destroy" is a no-op on the nodes - the cluster keeps
  # running while the firewall around it is torn down.
  #
  # graceful = false: a graceful reset leaves etcd first, which cannot work when
  # every member goes away at once.
  #
  # reboot = false halts instead of rebooting. A node in maintenance mode accepts
  # "apply-config --insecure", and destroy has already removed the firewall.
  #
  # Changes here only take effect once applied, before a later destroy.
  on_destroy = {
    reset    = true
    reboot   = false
    graceful = false
  }

  # Same reason as the control plane above: a dependency is destroyed after its
  # dependents, so the node is reset first and powered off or wiped afterwards.
  # Without this the two race, and a teardown that wins leaves the reset talking
  # to a machine that is already off:
  #
  #   Error: Error resetting machine
  #   rpc error: code = Unavailable ... dial tcp <worker>:50000: connect: connection refused
  depends_on = [
    terraform_data.teardown,
  ]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.controlplane]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_cp_ip
  endpoint             = local.first_cp_ip
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_cp_ip
  endpoint             = local.first_cp_ip
}
