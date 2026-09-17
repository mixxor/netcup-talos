# Talos Kubernetes on netcup

[![CI](https://github.com/mixxor/netcup-talos/actions/workflows/ci.yml/badge.svg)](https://github.com/mixxor/netcup-talos/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Talos](https://img.shields.io/badge/Talos-v1.14.0-orange)](https://www.talos.dev/)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-%E2%89%A5%201.12-yellow)](https://opentofu.org/)

A Kubernetes cluster on ordinary netcup VPS, from an empty disk to a verified
cluster in a single `tofu apply`. Talos Linux, Cilium, Longhorn, Traefik, plus an
optional haproxy load balancer because netcup does not offer one.

Put in your server names, apply, done. **You do not need a domain.**

Full write-up, including what it costs and what the HA actually buys:
[What HA Actually Costs: Kubernetes on netcup for €63/month with Talos and
OpenTofu](https://www.eucloudcost.com/blog/netcup-cluster/).

The netcup API can neither create nor delete servers, so there is no `apply` that
brings hardware into existence. The lifecycle is *order once in the panel, then
reinstall as often as you like* - and everything in between is automated here:
firewall, OS onto the disk, snapshot, Talos config, bootstrap, CNI, storage,
ingress.

> **Careful:** an apply overwrites `/dev/vda` on every server you list.

## Quick start

Requirements: `tofu` >= 1.12, `talosctl`, `kubectl`, `jq`, `curl`, and at least
two netcup VPS. The number of control planes must be odd - etcd requires it.

```bash
bash netcup/00-auth.sh          # browser device flow; writes .env
source netcup/env.sh            # exports the token and the user id for tofu

cd examples/cluster
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # the server names, and that is all
tofu init && tofu apply
```

### Where the user id comes from

`00-auth.sh` opens a browser, you confirm once, and it writes `.env` with a
refresh token and your SCP user id. It prints the id too, because
`env.sh` exports it:

```
Signed in as Some Name
  SCP user id:     100200   <- this is what the API wants   
  customer number: 300400   <- not this one, that is your login
```

**Those two numbers are easy to confuse.** netcup shows you the customer number
everywhere - it is what you log in with. The API wants the other one, and no
page in the panel calls it a "user id". It comes from the OIDC userinfo
response, where it is `id` while the customer number is `preferred_username`,
which is why this script reads it for you rather than sending you looking.

`00-auth.sh --print` shows both and touches no file. The refresh token is long
lived but not eternal: it expires after 30 days without use.

The id is deliberately **not** in `terraform.tfvars`. It lives in `.env`, and
`env.sh` exports it as `TF_VAR_netcup_user_id` alongside the token - one place
for each, rather than two that can drift apart. Put it in `terraform.tfvars`
instead if you prefer; it is an ordinary variable.

About five minutes later:

```bash
export KUBECONFIG=$PWD/../../generated/talos/kubeconfig
kubectl get nodes
cd ../.. && bash verify.sh      # health checks, each printing real output
```

The server names (`v2202...`) are in the netcup server list and in the order
confirmation.

### Without DNS

Leave `cluster_endpoint` and `cluster_domain` empty and the API endpoint becomes
the first control plane's IP, which is already in the certificate SANs.

With a domain, give `cluster_domain` one A record **per** control plane IP.
`kubectl` and `client-go` walk the address list, so a dead control plane costs a
retry rather than the cluster. That is worth having, but it is a property of
those two clients and not of DNS - see "What DNS failover is actually worth"
below, where the same trick is measured for browsers and comes out badly.

## The examples

There is one configuration, `examples/cluster`, and the shapes it can take are
tfvars files. A cluster is one entry under `clusters`; two entries are two
clusters, side by side in the same account. The key names the cluster and
decides its firewall policy, its nicknames in SCP and its credential directory,
so nothing collides.

```bash
cd examples/cluster
tofu apply -var-file=presets/complete.tfvars
```

**`terraform.tfvars.example`** - one control plane, one worker, Cilium and
nothing else. For trying the modules on two servers, and as the honest baseline
for what this costs. A single control plane means etcd has no redundancy at all.

**`presets/complete.tfvars`** - three control planes, workers, everything on:
Cilium, Longhorn, local-path, metrics-server, Traefik behind an haproxy load
balancer. This is the one you want.

**`presets/gitops.tfvars`** - the same cluster, but only what must be inline is:
Cilium, Longhorn and ArgoCD. Everything else arrives through ArgoCD from
`gitops/applicationsets`. Inline manifests are applied once and never
reconciled, so anything you expect to change belongs in git rather than in the
machine config.

**`presets/two-clusters.tfvars`** - prod and staging in one netcup account,
with separate firewall policies, nicknames and credential directories. Tested:
both were built, verified and destroyed.

Credentials land in `generated/<cluster name>/`. The scripts in `netcup/` and
`verify.sh` find that directory on their own while there is exactly one; with
more, name it:

```bash
CLUSTER=staging bash verify.sh
```

Two Talos specifics decide whether that works at all, and both are measured:

```
# without pod-security.kubernetes.io/enforce: privileged on the namespace
pods "traefik-s82hf" is forbidden: violates PodSecurity "baseline:latest":
hostPort (container "traefik" uses hostPorts 443, 80)
```

The label has to arrive through `managedNamespaceMetadata` in the sync policy -
`CreateNamespace=true` on its own creates the namespace without it. And ArgoCD's
own redis secret comes from a Helm hook, which inline manifests do not render,
so the module creates it instead. Without that every ArgoCD pod fails with
`secret "argocd-redis" not found`.

All three are structured identically, so a diff between their `main.tf` files
shows only what actually differs. What each demonstrates is written at the module call
rather than hidden behind variables.

Membership is declared, never guessed - without explicit names the module would
adopt every server in the account:

```hcl
control_plane_servers = ["v2202...1", "v2202...2", "v2202...3"]
worker_servers        = ["v2202...4", "v2202...5"]
```

`tofu output available_servers` lists every server in the account and whether
this cluster claims it.

## Using the modules from your own configuration

Two modules, meant to stand alone: `modules/talos-netcup-k8s-cluster` and
`modules/ha_proxy-netcup-k8s`.

They deliberately configure **no** providers. A module with its own `provider`
blocks cannot be used with `count` or `for_each` and cannot be handed an aliased
provider, which rules out two clusters from one configuration.

```hcl
provider "netcup" {
  scp_refresh_token = var.netcup_refresh_token
}

provider "helm" {}   # renders locally only, never talks to a cluster

module "cluster" {
  source = "github.com/mixxor/netcup-talos//modules/talos-netcup-k8s-cluster"

  control_plane_servers = ["v2202...1", "v2202...2", "v2202...3"]
  worker_servers        = ["v2202...4", "v2202...5"]
  netcup_user_id        = 123456
  netcup_refresh_token  = var.netcup_refresh_token
}
```

Writing kubeconfig and talosconfig stays in the calling root: inside the module
`path.module` points into `.terraform/modules/…` once consumed remotely, and the
files would land where the next `tofu init` throws them away.

So does the state, and it matters - unencrypted it holds the cluster CA's private
keys plus kubeconfig and talosconfig in plain text.

## Why one apply is enough

`data "helm_template"` renders the charts **locally**, so no provider needs a
cluster connection at plan time. Talos applies the result at bootstrap through
`cluster.inlineManifests`.

The trade-off: inline manifests are applied, not reconciled. Removing one does
not remove it from the cluster, and a chart upgrade rewrites the machine config.

## Day two

```bash
bash verify.sh                       # health checks against the cluster
bash netcup/backup-etcd.sh           # etcd snapshot, retention, integrity check
bash netcup/upgrade-talos.sh v1.15.0 # rolling Talos upgrade
bash netcup/rejoin-node.sh worker-2   # repair: Longhorn kept its node object
tofu destroy                         # reset, power off, wipe
```

**Kubernetes upgrades are a config change** - every image is pinned in the
machine config, so `tofu apply -var kubernetes_version=v1.38.0` is the whole
thing. Measured across six nodes: the apply took four seconds, and for about one
of them the API endpoint did not answer.

But `kubectl get nodes` shows the **kubelet**, not the control plane. Eight
seconds after that apply every node reported the new version while
`kube-apiserver` on two of three control planes was still old:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-apiserver \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

**Talos upgrades do not go through `tofu apply`** - the provider has no upgrade
resource. Keep the schematic id and swap only the version tag, or you lose
`iscsi-tools` and with it Longhorn:

```bash
IMAGE=$(tofu output -raw installer_image); IMAGE="${IMAGE%:*}:v1.15.0"
talosctl upgrade --nodes <ip> --image "$IMAGE" --wait
```

**Removing a node happens before the apply**, otherwise the workloads die hard
and a `NotReady` object stays forever.

`longhorn_replica_count` must not exceed the number of workers - a precondition
refuses that, because every volume would stay degraded forever. Keeping it
strictly *below* is a separate matter: with a replica on every worker there is
nowhere to move one, so a drain has nothing to evacuate to. Three replicas on
three workers is a healthy cluster you cannot take a node out of.

**Three replicas are not a backup.** They protect against losing a node, not
against a deleted PVC. `tests/backup-restore.sh` runs the full cycle against a
throwaway S3 - write, back up, destroy the volume and its replicas, restore,
compare.

## Load balancing

netcup has none, so a `Service` of type `LoadBalancer` stays `pending` forever.

By default Traefik runs as a DaemonSet on hostPort 80/443, so on every worker -
give the application name one A record per worker. That costs nothing but cannot
take a dead node out of rotation; DNS has no health checks.

`modules/ha_proxy-netcup-k8s` closes that gap on servers of their own:

```hcl
loadbalancer_servers = ["v2202...6", "v2202...7"]
```

Two of them, with one A record each. Whether that actually survives a dead box
depends on the client - measured below.

An SSH key is generated into `generated/` and registered with netcup. It is made
with `ssh-keygen`, not with the `tls` provider, because `tls_private_key` keeps
the private key in the state file - and the state is not where a key that opens
your load balancers belongs. Only the public half passes through Terraform. Name
an existing key with `loadbalancer_ssh_key_ids` to opt out.

The cluster ports then close - 80 and 443 accept only from the load balancer.
Measured, with Traefik removed from one worker and ten requests during the
outage:

```
Server ingress_https/worker-1 is DOWN, reason: Layer4 timeout, check duration: 3001ms
ok=10  failed=0
```

Behind a proxy like Cloudflare the firewall should *close*, not open, or anyone
bypasses it through a node IP: set `public_ingress_sources` to the proxy's ranges
and `ingress_trusted_proxy_cidrs` alongside it.

**The API stays off the load balancer** (`loadbalancer_serves_api = false`): it
does not need one, and coupling it to the ingress entry point means a dead box
takes away the ability to fix the cluster.

## What DNS failover is actually worth

Short answer: on netcup, much less than the usual advice suggests. Measured
against this cluster with two load balancers and one A record each.

**Every failure looks the same from outside, and it looks like nothing.** A port
with no listener does not answer "connection refused" - it swallows the packets:

| from outside, against a load balancer | |
|---|---|
| port 80, haproxy running | 1.7 ms |
| port 80, haproxy stopped | timed out |
| port 9999, not in the firewall at all | timed out |

So there is no fast failure to react to. A client that picked the dead address
waits out its TCP connect timeout - six SYN retries on Linux:

```
  dead candidate first, live one second:   134 s
```

That is the same 134 seconds whether the service was stopped or the packets were
dropped, because from the client's side there is no difference.

**And the client may never get the second address at all.** `dig` queries the
nameserver directly; `getaddrinfo`, which is what programs actually use, is free
to hand over a subset:

| resolver | addresses seen |
|---|---|
| Linux, glibc | both |
| inside the cluster, CoreDNS | both |
| macOS | **one of two** |

With one address and no fallback, twenty of twenty requests failed outright.

**What follows:**

- Two A records are worth something on Linux and inside the cluster, and there
  they cost up to ~130 s per failover for a CLI client. Browsers open a parallel
  attempt after a few hundred milliseconds (Happy Eyeballs) and should do far
  better - not measured here.
- `curl`, `kubectl` and anything else built on Go's dialer go strictly in order
  and pay the full timeout.
- On macOS it may buy nothing at all - which is exactly where `kubectl` runs. So
  "one A record per control plane" is a convenience, not a guarantee.

**If the entry point has to survive a dead box**, the client's resolver must not
be part of the decision. Two ways:

- **A proxy in front** - Cloudflare or similar. The client only ever sees the
  proxy's anycast addresses, which are always up, so the whole question
  disappears. You get TLS and DDoS absorption with it, and you pay with a hard
  dependency on a third party that also terminates your TLS. Origin health
  checks are a paid feature there; whether the free tier retries a second origin
  was not measured.
- **A netcup failover IP** moved between the two load balancers. One address
  that does not depend on any resolver, plus something that triggers the move.
  Costs extra, and this account has none - the endpoint returns `[]`.

## Two clusters in one account

Add a second entry; `presets/two-clusters.tfvars` shows the shape:

```hcl
clusters = {
  prod    = { control_plane_servers = [...], worker_servers = [...] }
  staging = { control_plane_servers = [...], worker_servers = [...] }
}
```

That `for_each` over the module is what carrying no provider blocks buys - a
module that configures its own providers cannot be used with `for_each`, and
there would have to be one configuration per cluster. It is also why there is
one example rather than four: the difference between a small cluster and a full
one is a tfvars file, not a directory.

Everything that could collide carries the cluster name: the firewall policy, the
server nicknames (`<cluster_name>/cp-1`), the credential directory, the load
balancer's SSH key name.

Listing the same server in two clusters is refused twice over. The example
validates it before anything runs:

```
Error: Invalid value for variable

A server is listed in more than one cluster. Both would write an operating
system onto the same disk.
```

And the module refuses it even from a separate configuration, which the
validation cannot see.

**Claiming a server that already belongs to another cluster is refused.** Both
configurations would write an operating system onto the same disk, and you would
find out by losing a cluster. The nickname is the evidence, and the install step
has a precondition on it:

```
Error: Resource precondition failed

Server v2202... carries the nickname 'prod/cp-1', so it belongs to
another cluster. This step would write an operating system onto its disk.
Rename it in the SCP, or pick a different server.
```

Plan and apply both exit non-zero.

Two clusters side by side is tested: `prod` and `staging`, one control plane and
one worker each, separate firewall policies, separate nicknames, separate
credential directories under `generated/<name>/`.

**Building both at once is slower than building one.** Four servers install in
parallel over the same account and network, and the machine configuration apply
went from about a minute to four. That matters because of the next paragraph.

### When the bootstrap says "already exists"

```
Error: Error bootstrapping node
rpc error: code = AlreadyExists desc = etcd data directory is not empty
```

`talos_machine_bootstrap` is not idempotent, and the provider retries the call.
Under load the first attempt succeeded, the retry found etcd already running,
and the resource never made it into the state - so the apply failed on a cluster
that was in fact up, and every further apply would fail the same way.

The cluster is fine; the state is not. Put the resource back and carry on:

```bash
tofu import 'module.cluster["prod"].talos_machine_bootstrap.this' machine_bootstrap
tofu apply
```

Check before you do: an apiserver that answers `Unauthorized` on
`https://<control plane>:6443/readyz` is running, and that is the evidence that
the bootstrap really did happen.

**Firewall policy names are not unique at netcup.** Two clusters sharing a
`cluster_name` produce two policies with that name rather than an error, and only
one of them is attached to anything. A check reports it at plan time with the
ids.

## Losing the state

The state is local and netcup has nowhere to put a remote one, so this is a
question of when rather than if. An apply without it **rebuilds rather than
adopts**: `terraform_data.install` is gone, so rescue plus `dd` runs again on
every server and the cluster is replaced.

What survives at netcup, and what that means:

| | |
|---|---|
| SSH key | The name is unique per account. The configuration looks it up and reuses it, so no `sshkey.nameinuse` and no second key. |
| firewall policies | Names are not unique, so a second one appears with the same name and the old one ends up attached to nothing. The check names the ids; delete the stale ones. |
| servers | Recognised by nickname and rebuilt from scratch. |

## Limitations, stated honestly

- **The state is local.** netcup has no object storage, so there is nowhere for
  remote state. No locking, no team workflow.
- **A destroy opens the firewall for a few seconds.** netcup locks a server
  while it powers off and answers a concurrent firewall delete with HTTP 409, so
  the policy has to go first - and removing it drops netcup back to ACCEPT_ALL.
  Measured at about seven seconds on a load balancer. What is reachable in that
  window is key-only SSH and the mTLS Talos API, on a machine that is wiped
  immediately afterwards.
- **No server create, no delete, no CSI.**
- **The netcup control panel is a hard dependency for changes.** During a
  maintenance window of that panel nothing runs - every `plan` starts with
  `GET /api/v1/servers`. The cluster does not notice; `talosctl` and `kubectl`
  talk to the nodes directly.
- **Longhorn over WireGuard costs you.** Roughly 1,300 IOPS against roughly
  21,000 on the bare NVMe of the same server. Need speed and not replication? Use
  the `local-path` StorageClass, and know the data dies with the node.

## License

MIT, see [LICENSE](LICENSE).
