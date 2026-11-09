# netobserv

Network Observability: an eBPF agent on every node captures flows,
`flowlogs-pipeline` enriches them, and the console gains **Observe → Network
Traffic**.

| | |
|---|---|
| package | `netobserv-operator` |
| catalog | `redhat-operators` |
| channel | `stable` (also available: `v1.0.x`, legacy) |
| CSV | `network-observability-operator.v2.0.0` |
| install mode | AllNamespaces → `spec: {}` |
| operator namespace | `openshift-netobserv-operator` |
| workload namespace | `netobserv` (created by the operator from `spec.namespace`) |
| API | `flows.netobserv.io/v1beta2` `FlowCollector`, named `cluster` |

## Two ways to run it

| | `base` (the hub) | `overlays/loki` (opt-in) |
|---|---|---|
| flow metrics in cluster monitoring | yes | yes |
| Overview and Topology in the console | yes, per namespace / owner | yes, down to pod and IP |
| raw flow table | **no** | yes |
| needs | nothing else | Loki Operator, ODF object + block storage |
| extra footprint | none | a `1x.pico` LokiStack and a bucket |

The hub runs `base` because of capacity. The Loki overlay is kept building in
CI (`scripts/validate.sh`) so it is ready when wanted.

### `spec.loki.enable` defaults to true

The one trap in `base`. In the v1beta2 CRD, leaving out the `loki` block does
not turn Loki off: `enable` defaults to `true` and `mode` to `Monolithic`, aimed
at `http://loki.netobserv.svc:3100`, which does not exist. `base` sets
`enable: false` explicitly. Checked against the CRD at the upstream tag the CSV
names, `2.0.1-community`.

## Enabling Loki on a cluster

Two edits in `clusters/<cluster>/`, in one change:

1. `operators.yaml` — add the Loki Operator:

   ```yaml
   - name: loki
     namespace: openshift-operators-redhat
     path: manifests/olm/loki/base
   ```

2. `config.yaml` — point the `netobserv` entry at the overlay:

   ```yaml
   path: manifests/config/netobserv/overlays/loki
   ```

Order does not matter: the LokiStack carries `SkipDryRunOnMissingResource` and
converges by retry once the Loki Operator's CSV lands.

What the overlay adds, in sync-wave order:

| wave | object | why |
|---|---|---|
| 0 | `Namespace netobserv` | the LokiStack must exist before the FlowCollector |
| 1 | `ObjectBucketClaim netobserv-loki` | bucket from ODF's Multicloud Object Gateway |
| 1–3 | SA, Role, `SecretStore`, `ExternalSecret loki-s3` | reshapes the OBC's `AWS_*` keys into the `bucketnames`/`endpoint`/`access_key_*` keys Loki reads |
| 4 | `LokiStack loki` | `1x.pico`, `openshift-network` tenancy |
| 10 | `FlowCollector` patch | `loki.mode: LokiStack` |

No credential is committed or kept in 1Password: ODF generates it and External
Secrets copies it, the same construction as
[maas-database](../maas-database).

### Turning it back off

Revert both edits. Two things stay behind on purpose: the `netobserv` namespace
(`Prune=false,Delete=false`, since the operator's workloads live there) and
`openshift-operators-redhat` (a shared Red Hat namespace name). Pruning the OBC
deletes the bucket and every stored flow.

## The Loki package name is ambiguous

`loki-operator` exists in **both** `redhat-operators` (channels `stable-6.x`)
and `community-operators` (`alpha`). `oc get packagemanifest loki-operator`
returns one of them silently; on the hub it returned the community one. Select
by catalog:

```bash
oc get packagemanifest -n openshift-marketplace -l catalog=redhat-operators \
  -o json | jq '.items[] | select(.metadata.name=="loki-operator") | .status.defaultChannel'
```

`scripts/verify-channels.sh` looks every package up within its Subscription's
`source` catalog for this reason.

## Verifying

The CSV first, since ArgoCD cannot see it:

```bash
oc get csv -n openshift-netobserv-operator
```

Then the collector and its workloads:

```bash
oc get flowcollector cluster
oc get pods -n netobserv
oc get pods -n netobserv-privileged   # the eBPF agent DaemonSet runs here
```

And the console plugin:

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
```

`netobserv-plugin` should be listed. The console redeploys when that list
changes, so expect a brief reload.

With Loki enabled, also:

```bash
oc get obc,lokistack,externalsecret -n netobserv
```

## Sizing

Set explicitly in `base`, where it differs from the CRD default:

| field | value | default | why |
|---|---|---|---|
| `processor.consumerReplicas` | 1 | 3 | Red Hat's 3 is for 10 nodes *with* Loki; without it the pipeline only derives metrics |
| `agent.ebpf.sampling` | 400 | 50 | matches OpenShift's planned install-time default (below); the main accuracy/cost knob |
| `agent.ebpf.features` | `[DNSTracking]` | none | same; unprivileged |
| `deploymentModel` | Service | Service | `Direct` would run a pipeline per node (ten on the hub) |

The eBPF agent runs on every node with an 800Mi memory limit and 50Mi request
(CRD defaults, not overridden).

### OpenShift will install this by default — later

Not on 4.22: as of 2026-11-09 the hub has no `networkObservability` field on
`networks.config.openshift.io` and no feature gate for it. In `openshift/api`
`release-5.0`, the `NetworkObservabilityInstall` gate exists but is enabled
only in the TechPreviewNoUpgrade and DevPreviewNoUpgrade feature sets
([enhancement #1908](https://github.com/openshift/enhancements/pull/1908)).

When it ships, every non-SNO cluster gets the operator plus a basic
FlowCollector: Service model, **no Loki, sampling 400, DNSTracking**. `base`
mirrors that, so the hub looks the way a default cluster will.

Two things to check when the hub reaches a release where it is on by default:

- The platform detects an existing OLM install and uses it. If it cannot tell
  how the operator was installed, it **stops** — confirm it adopts this one
  rather than fighting ArgoCD over the Subscription.
- The opt-out is `installationPolicy: NoAction` on the cluster Network config
  (the proposal said `DoNotInstall`; the merged API says `NoAction`).
