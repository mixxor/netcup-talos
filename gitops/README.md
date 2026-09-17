# GitOps content

Not a bootstrap repository - ArgoCD itself has to be installed before any of
this can be applied, and that is what `install_argocd` in the cluster module
does. What lives here is the **App-of-Apps** content: a directory of
ApplicationSets that a single root `Application` points at.

```
applicationsets/   one ApplicationSet per component
values/            Helm values, referenced by the sets through $values
```

The module creates the root Application when `argocd_apps_repo` is set. Without
it you get ArgoCD and nothing else, which is a reasonable starting point.

## Before it works

Point the ApplicationSets at your own fork - they carry the repository URL
twice, once per file:

```bash
sed -i '' 's#https://github.com/YOUR-ORG/netcup-talos.git#<your fork>#' \
  gitops/applicationsets/*.yaml
```

## Why the values differ from a generic essentials repository

**Traefik runs as a DaemonSet on hostPort, with no Service.** netcup has no load
balancer, so `service.type: LoadBalancer` would stay `pending` forever.

**Its namespace needs `pod-security.kubernetes.io/enforce: privileged`.** Talos
enforces Pod Security `baseline`, and baseline forbids host ports. This has to
come through `managedNamespaceMetadata` - `CreateNamespace=true` on its own
creates the namespace without the label, and every Traefik pod is then rejected.

**metrics-server needs `--kubelet-insecure-tls`.** Talos issues kubelet serving
certificates that metrics-server does not trust.

## Migrating a running cluster from inline to git

Inline manifests are applied once and never reconciled, which is usually the
annoying property and here the useful one: deleting the inline component sticks.

```bash
kubectl delete ns traefik                  # the inline one, gone for good
kubectl apply -f gitops/applicationsets/   # ArgoCD takes over
```

Measured: DaemonSet ready again after 35 seconds, and an ingress through it
answered from outside immediately afterwards.

## Structure borrowed from

<https://github.com/mixxor/argocd-cluster-essentials>, which carries the same
layout with a larger set of components.
