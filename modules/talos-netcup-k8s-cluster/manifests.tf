# In-cluster workloads, rendered locally and applied by Talos at bootstrap.
#
# data "helm_template" never talks to a cluster, which is what makes a single
# apply possible. The trade-off: inline manifests are applied once, not
# reconciled - removing one here does not remove it from the cluster.

data "helm_template" "cilium" {
  count = var.install_cilium ? 1 : 0

  name         = "cilium"
  repository   = "https://helm.cilium.io/"
  chart        = "cilium"
  version      = var.cilium_version
  namespace    = "kube-system"
  kube_version = var.kubernetes_version

  # Hooks must not be rendered - Talos applies the manifests raw and a Helm
  # pre-delete Job would run immediately. CRDs have to come along explicitly.
  disable_webhooks = true
  include_crds     = true

  values = [yamlencode({
    # Talos disables kube-proxy, Cilium takes over.
    kubeProxyReplacement = true

    # KubePrism: reachable before any CNI runs.
    k8sServiceHost = "localhost"
    k8sServicePort = 7445

    # No private network: node-to-node traffic crosses the shared public /22,
    # so encryption is mandatory rather than optional.
    encryption = {
      enabled = true
      type    = "wireguard"
    }

    ipam = { mode = "kubernetes" }

    # Hubble off: the chart generates a fresh CA on every render, which means
    # perpetual drift. Enabling it needs an explicit CA via hubble.tls.ca.
    hubble = { enabled = false }

    # Talos mounts the cgroup already.
    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }

    securityContext = {
      capabilities = {
        ciliumAgent = [
          "CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN",
          "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID",
        ]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }
  })]
}

data "helm_template" "longhorn" {
  count = var.install_longhorn ? 1 : 0

  # Longhorn cannot place more replicas than it has eligible nodes, and a
  # cluster whose volumes never reach healthy is broken rather than warned about.
  lifecycle {
    precondition {
      condition     = var.longhorn_replica_count <= length(var.worker_servers)
      error_message = "longhorn_replica_count is ${var.longhorn_replica_count} but there are ${length(var.worker_servers)} workers; every volume would stay degraded forever."
    }
  }

  name         = "longhorn"
  repository   = "https://charts.longhorn.io"
  chart        = "longhorn"
  version      = var.longhorn_version
  namespace    = "longhorn-system"
  kube_version = var.kubernetes_version

  # Hooks must not be rendered - Talos applies the manifests raw and a Helm
  # pre-delete Job would run immediately. CRDs have to come along explicitly.
  disable_webhooks = true
  include_crds     = true

  values = [yamlencode({
    defaultSettings = merge({
      # Talos is read-only except for /var.
      defaultDataPath     = "/var/lib/longhorn"
      defaultReplicaCount = var.longhorn_replica_count

      # Only labelled nodes get a disk; the label is set in talos.tf.
      createDefaultDiskLabeledNodes = true

      # Longhorn refuses to uninstall itself without this.
      deletingConfirmationFlag = true
      },
      # Empty by default: a target that does not resolve logs errors forever.
      var.longhorn_backup_target == "" ? {} : {
        backupTarget                 = var.longhorn_backup_target
        backupTargetCredentialSecret = var.longhorn_backup_target_secret
    })
    persistence = {
      defaultClass             = true
      defaultClassReplicaCount = var.longhorn_replica_count
    }
  })]
}

data "helm_template" "metrics_server" {
  count = var.install_metrics_server ? 1 : 0

  name         = "metrics-server"
  repository   = "https://kubernetes-sigs.github.io/metrics-server/"
  chart        = "metrics-server"
  version      = var.metrics_server_version
  namespace    = "kube-system"
  kube_version = var.kubernetes_version

  # Hooks must not be rendered - Talos applies the manifests raw and a Helm
  # pre-delete Job would run immediately. CRDs have to come along explicitly.
  disable_webhooks = true
  include_crds     = true

  values = [yamlencode({
    args = [
      # Talos does not rotate kubelet serving certificates, so there is no
      # cluster-CA-signed certificate for metrics-server to validate against.
      #
      # A deliberate trade-off, not an oversight: the netcup firewall restricts
      # port 10250 to the node IPs and that traffic runs through Cilium's
      # WireGuard, so an attacker would already have to be inside the cluster
      # network. Hardening would mean rotate-server-certificates plus a CSR
      # approver, both of which add moving parts.
      "--kubelet-insecure-tls",
      "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname",
    ]
    replicas = 1
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  })]
}

locals {
  # Longhorn needs privileged pods, and Talos enforces Pod Security "baseline",
  # which forbids both those and host ports.
  # The chart creates this through a Helm hook job, and hooks are not rendered
  # here - so the secret would never exist and every ArgoCD pod would fail with
  # "secret argocd-redis not found". Only the "auth" key is mandatory.
  argocd_redis_secret = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "argocd-redis"
      namespace = "argocd"
      labels = {
        "app.kubernetes.io/name"    = "argocd-redis"
        "app.kubernetes.io/part-of" = "argocd"
      }
    }
    stringData = { auth = one(random_password.argocd_redis[*].result) }
  })

  argocd_namespace = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = "argocd" }
  })

  # The App-of-Apps root. Talos applies inline manifests repeatedly until they
  # stick, which is what lets this land in the same batch as the CRDs it needs.
  argocd_root_application = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_apps_repo
        targetRevision = var.argocd_apps_revision
        path           = var.argocd_apps_path
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["ServerSideApply=true"]
      }
    }
  })

  traefik_namespace = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "traefik"
      labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
        "pod-security.kubernetes.io/audit"   = "privileged"
        "pod-security.kubernetes.io/warn"    = "privileged"
      }
    }
  })

  longhorn_namespace = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "longhorn-system"
      labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
        "pod-security.kubernetes.io/audit"   = "privileged"
        "pod-security.kubernetes.io/warn"    = "privileged"
      }
    }
  })

  # Order matters: Talos applies these top to bottom, and the namespace has to
  # exist before anything lands in it.
  inline_manifests = concat(
    var.install_cilium ? [
      { name = "cilium", contents = data.helm_template.cilium[0].manifest },
    ] : [],
    var.install_longhorn ? [
      { name = "longhorn-namespace", contents = local.longhorn_namespace },
      { name = "longhorn", contents = data.helm_template.longhorn[0].manifest },
    ] : [],
    var.install_metrics_server ? [
      { name = "metrics-server", contents = data.helm_template.metrics_server[0].manifest },
    ] : [],
    var.install_local_path ? [
      { name = "local-path-provisioner", contents = local.local_path_manifest },
    ] : [],
    var.install_argocd ? concat(
      [
        { name = "argocd-namespace", contents = local.argocd_namespace },
        { name = "argocd-redis-secret", contents = local.argocd_redis_secret },
        { name = "argocd", contents = data.helm_template.argocd[0].manifest },
      ],
      var.argocd_apps_repo == "" ? [] : [
        { name = "argocd-root-app", contents = local.argocd_root_application },
      ],
    ) : [],
    var.install_traefik ? [
      { name = "traefik-namespace", contents = local.traefik_namespace },
      { name = "traefik", contents = data.helm_template.traefik[0].manifest },
    ] : [],
  )
}

# local-path-provisioner: node-local storage without replication.
#
# The benchmark makes the case: Longhorn does 1708 IOPS, the bare NVMe 22700 -
# a factor of 13 for three-way replication. Anything that does not need HA
# (build caches, scratch space, a database that replicates itself) pays that
# factor for nothing.
#
# Longhorn stays the default StorageClass on purpose. A PVC without an explicit
# storageClassName lands on replicated storage - slower, but it survives a node
# failure. Speed has to be asked for by name.
#
# Taken from the upstream manifest rather than a third-party chart: Rancher
# publishes no chart of its own, and this is 4.5 KB of auditable YAML.
data "http" "local_path_provisioner" {
  count = var.install_local_path ? 1 : 0

  url = "https://raw.githubusercontent.com/rancher/local-path-provisioner/${var.local_path_version}/deploy/local-path-storage.yaml"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "local-path-provisioner manifest ${var.local_path_version} returned HTTP ${self.status_code}"
    }
  }
}

locals {
  # Two patches: /opt is read-only on Talos, and the namespace has to opt out
  # of Pod Security "baseline" for its hostPath mounts.
  local_path_manifest = var.install_local_path ? replace(
    replace(
      data.http.local_path_provisioner[0].response_body,
      "\"paths\":[\"/opt/local-path-provisioner\"]",
      "\"paths\":[\"/var/local-path-provisioner\"]"
    ),
    "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: local-path-storage",
    join("\n", [
      "apiVersion: v1",
      "kind: Namespace",
      "metadata:",
      "  name: local-path-storage",
      "  labels:",
      "    pod-security.kubernetes.io/enforce: privileged",
      "    pod-security.kubernetes.io/audit: privileged",
      "    pod-security.kubernetes.io/warn: privileged",
    ])
  ) : ""
}

# Traefik as a DaemonSet on hostPort 80/443, because a Service of type
# LoadBalancer would stay pending forever on netcup. It binds 8000/8443 inside
# the container, so it needs no NET_BIND_SERVICE.
data "helm_template" "traefik" {
  count = var.install_traefik ? 1 : 0

  name         = "traefik"
  repository   = "https://traefik.github.io/charts"
  chart        = "traefik"
  version      = var.traefik_version
  namespace    = "traefik"
  kube_version = var.kubernetes_version

  disable_webhooks = true

  # 25 objects, ~440 KB, into every node's machine config.
  include_crds = var.traefik_install_crds

  values = [yamlencode(merge({
    deployment = { kind = "DaemonSet" }
    service    = { enabled = false }

    ports = {
      web = merge(
        { port = 8000, hostPort = 80 },
        length(var.ingress_trusted_proxy_cidrs) == 0 ? {} : {
          forwardedHeaders = { trustedIPs = var.ingress_trusted_proxy_cidrs }
        },
      )
      websecure = merge(
        { port = 8443, hostPort = 443 },
        length(var.ingress_trusted_proxy_cidrs) == 0 ? {} : {
          forwardedHeaders = { trustedIPs = var.ingress_trusted_proxy_cidrs }
        },
      )
    }

    ingressClass = {
      enabled        = true
      isDefaultClass = true
    }

    providers = {
      # No Service, so nothing to publish.
      kubernetesIngress = { publishedService = { enabled = false } }

      # Without the CRDs this provider only logs errors.
      kubernetesCRD = { enabled = var.traefik_install_crds }
    }
    }, {}
  ))]
}

# ArgoCD itself. Everything else it installs comes from git; this one cannot,
# because nothing exists yet to install it.
resource "random_password" "argocd_redis" {
  count = var.install_argocd ? 1 : 0

  length  = 32
  special = false
}

data "helm_template" "argocd" {
  count = var.install_argocd ? 1 : 0

  name         = "argocd"
  repository   = "https://argoproj.github.io/argo-helm"
  chart        = "argo-cd"
  version      = var.argocd_version
  namespace    = "argocd"
  kube_version = var.kubernetes_version

  disable_webhooks = true
  include_crds     = true

  values = [yamlencode({
    # No ingress and no TLS in front of it yet, so serve plain HTTP and reach it
    # with "kubectl -n argocd port-forward svc/argocd-server 8080:80".
    configs = {
      params = { "server.insecure" = true }
    }

    # Both off to save memory: 4 GB per node, and neither is needed to sync.
    dex           = { enabled = false }
    notifications = { enabled = false }

    # The secret is an inline manifest instead, see argocd_redis_secret.
    redisSecretInit = { enabled = false }

    controller     = { resources = { requests = { cpu = "100m", memory = "256Mi" } } }
    repoServer     = { resources = { requests = { cpu = "50m", memory = "128Mi" } } }
    server         = { resources = { requests = { cpu = "50m", memory = "128Mi" } } }
    applicationSet = { resources = { requests = { cpu = "50m", memory = "128Mi" } } }
    redis          = { resources = { requests = { cpu = "50m", memory = "64Mi" } } }
  })]
}

# Not an error: a replica on every worker is a healthy cluster. It just cannot
# be drained, because Longhorn has nowhere to move the replica that lives on the
# node going away - and "removing a node happens before the apply" then has
# nothing to evacuate to.
check "longhorn_replicas_leave_room_to_drain" {
  assert {
    condition     = !var.install_longhorn || var.longhorn_replica_count < length(var.worker_servers)
    error_message = "longhorn_replica_count is ${var.longhorn_replica_count} with ${length(var.worker_servers)} workers, so every worker holds a replica of every volume. The cluster is healthy, but no node can be drained. Use ${length(var.worker_servers) - 1} or fewer to keep that possible."
  }
}
