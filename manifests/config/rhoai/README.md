# rhoai

Red Hat OpenShift AI Self-Managed 3.5: the platform settings and the list of
components that run.

| | |
|---|---|
| package | `rhods-operator` |
| catalog | `redhat-operators` |
| channel | `stable-3.5` — **pinned**, not the default `stable-3.x` |
| CSV | `rhods-operator.3.5.1` |
| install mode | AllNamespaces → `spec: {}` |
| namespace | `redhat-ods-operator` (operator), `redhat-ods-applications` (components) |

The goal on the hub is **Models-as-a-Service with no GPU**: one governed endpoint
in front of models served somewhere else. That goal decides most of what follows.
Tracked as the epic `homelab-2026-o8y`.

## Pieces

| What | Where | Why |
|---|---|---|
| `rhods-operator` | `manifests/olm/rhoai` | The operator. Deploys nothing by itself |
| `DSCInitialization/default-dsci` | `base/dscinitialization.yaml` | Platform settings. Created by the operator; co-owned here |
| `DataScienceCluster/default-dsc` | `base/datasciencecluster.yaml` | Which components run |
| `OdhDashboardConfig/odh-dashboard-config` | `base/odhdashboardconfig.yaml` | The flags that make MaaS visible in the dashboard. Created by the operator; patched here |
| `MaasTenantConfig/default-tenant` | `base/maas-telemetry.yaml` | Usage metrics labelled per user. Created by the controller; patched here |
| DSCI `monitoring.metrics` | `overlays/hub/dsci-metrics-storage.yaml` | Storage for RHOAI's metrics stack, which is what turns it on |
| `Deployment/maas-controller` | `overlays/hub/maas-controller-memory.yaml` | Memory limit only. The shipped one is too small for the hub |

## Components

Every component is listed in the manifest, on or off. Several default to
Managed when omitted — `kserve.nim` is one — so leaving something out is not the
same as turning it off.

| Component | State | Why |
|---|---|---|
| `dashboard` | Managed | The UI, including the MaaS admin pages |
| `aigateway` + `modelsAsAService` | Managed | The goal. In 3.5 MaaS lives here, not under `kserve` |
| `aigateway.batchGateway` | Removed | Batch inference over locally served models; nothing to batch yet |
| `kserve` | Managed | Not needed for MaaS to front external models, but the only way to put a locally served model behind it later |
| `kserve.nim`, `.modelCache`, `.wva` | Removed | NIM needs NVIDIA GPUs and an NGC key |
| `workbenches` | Managed | Cheap; a notebook to call the MaaS endpoint from |
| `ogx` | Managed | The renamed Llama Stack; backs the gen AI playground. See the caveat below |
| `mlflowoperator` | Managed | Operator only. The MLflow instance is `homelab-2026-o8y.10` |
| `llamastackoperator` | Removed | Superseded by `ogx` |
| `trainer`, `trainingoperator`, `ray`, `kueue`, `sparkoperator` | Removed | Training and distributed compute, pointless without a GPU. `trainer` also requires the JobSet operator |
| `aipipelines`, `feastoperator`, `modelregistry`, `trustyai`, `mcplifecycleoperator` | Removed | Not needed to reach working MaaS |

Turning one on later is a one-line change. Check its prerequisites first:
Red Hat's [install guide](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install)
lists them per component, and several need another operator.

**OGX and no GPU.** Red Hat's guide lists Service Mesh 3.x, Node Feature
Discovery, the NVIDIA GPU Operator, GPU nodes and S3 storage as OGX
requirements, and names CPU-only support only for IBM Power. The operator itself
ran here without any of them. Whether an OGX server that only calls
MaaS-served remote models is useful on this hub is **untested**.

**`kserve.modelsAsService` is never set.** It is the deprecated 3.4 location for
MaaS. The API defaults it to `Removed`. Setting it to `Managed` is a one-way
door: the field cannot be changed back.

## Models-as-a-Service needs four other components

Enabling `aigateway.modelsAsAService` is necessary and nowhere near sufficient.
`ModelsAsAServiceReady` stays `False` until all of these exist:

| MaaS needs | Component | What happens without it |
|---|---|---|
| A Gateway named `maas-default-gateway` in `openshift-ingress` | [maas-gateway](../maas-gateway) | `gateway … not found`. RHOAI does not create it |
| Red Hat Connectivity Link, with a `Kuadrant` instance | [connectivity-link](../connectivity-link) | `Red Hat Connectivity Link not installed`; no policy kinds exist |
| TLS on Authorino | [connectivity-link](../connectivity-link/README.md#authorino-tls) | Authentication calls fail |
| A PostgreSQL database and its Secret | [maas-database](../maas-database) | `maas-api` crash-loops |

The DataScienceCluster only reports the first thing in its way, so these surface
one at a time. None of them is ordered against this Application; everything
converges by retry.

Also required, and already true on the hub: User Workload Monitoring enabled
(otherwise MaaS reports Degraded), and the cert-manager Operator for `kserve`.

## The DSCInitialization is the operator's

The operator creates `default-dsci` the moment it is installed, with the same
values this repo declares. Declaring them makes them a reviewed decision and
makes drift visible; it changes nothing that is running. It carries
`Prune=false,Delete=false` because deleting it tears the platform down.

It also makes the operator create the **dashboard's own gateway** — Gateway
`data-science-gateway` in `openshift-ingress`, on a GatewayClass of its own,
with a Route. That is separate from the MaaS gateway and not managed here.

## Dashboard feature flags

Enabling MaaS in the DataScienceCluster makes it work. These make it visible.
They live in `OdhDashboardConfig` (`odh-dashboard-config` in
`redhat-ods-applications`), under `spec.dashboardConfig`, and all default to off:

| Flag | Effect |
|---|---|
| `modelAsService` | The Models-as-a-Service pages |
| `genAiStudio` | Gen AI studio and playground; needs `ogx` Managed |
| `externalModels` | The external models page (Technology Preview) |
| `observabilityDashboard` | Observe & monitor → Dashboard, including the MaaS Usage tab (Technology Preview) |

The operator creates that object when it deploys the dashboard. The manifest
here is partial: server-side apply merges these flags in and leaves the rest
of the object to the operator.

**On a fresh cluster this can race.** If ArgoCD applies the manifest before the
operator has created the object, ArgoCD creates it with only these flags,
and upstream says the operator does not overwrite one that already exists. The
dashboard could then be missing its defaults. On the hub the object existed
first. If it ever happens, delete the object, let the operator recreate it, and
ArgoCD will merge the flags back in:

```bash
oc delete odhdashboardconfig odh-dashboard-config -n redhat-ods-applications
```

Do **not** set `maasAuthPolicies`. Red Hat's guide still lists it; the CRD marks
it deprecated and its validation rejects setting it on a new install.

The CRD has other flags that may matter for agent work later — `toolCalling`,
`genAiTracing`, `aiAssetCustomEndpoints` — none of which are set.

## Token usage per user

RHOAI 3.5 can report token consumption by user, subscription and model: the
**Usage** tab under **Observe & monitor → Dashboard**, with a "Token Consumption
by User" table that exports to CSV. It is a Technology Preview, visible to
cluster admins only, and Red Hat describes it as showback, not billing-grade
metering. None of it is on by default. Five things switch it on:

| # | Setting | Where | What it does |
|---|---|---|---|
| 1 | Red Hat build of OpenTelemetry | `manifests/olm/opentelemetry` | Runs the collector the metrics stack deploys |
| 2 | DSCI `monitoring.metrics.storage` | `overlays/hub/dsci-metrics-storage.yaml` | Deploys RHOAI's own Prometheus, Thanos querier and Perses in `redhat-ods-monitoring` |
| 3 | Kuadrant `observability.enable` | `manifests/config/connectivity-link` | PodMonitors for Limitador and Authorino |
| 4 | `MaasTenantConfig` `telemetry` | `base/maas-telemetry.yaml` | Labels the token counters with user, subscription and model |
| 5 | `observabilityDashboard` | `base/odhdashboardconfig.yaml` | Shows the page |

The Cluster Observability Operator is also required and was already installed
(`manifests/olm/cluster-observability`).

**What is counted.** Limitador's `authorized_hits` is tokens, `authorized_calls`
is requests allowed, `limited_calls` is requests refused by a token limit. Only
`authorized_hits` carries the `model` label.

**Limits worth knowing before trusting a number:**

- Tokens are a single total. Input and output are not separated, so cost
  cannot be computed exactly for a provider that prices them differently —
  which is every provider registered in `maas-models`.
- A request made with a MaaS API key is attributed to the user who created the
  key.
- Tokens are counted from the usage block in the model's response. A streamed
  response that carries none increments the request count and not the token
  count. Streamed requests to `claude-haiku-4-5` do carry one and are counted
  (checked 2026-10-12: a plain and a streamed request of 21 tokens each gave 42).
- The `model` label is whatever the provider's response calls the model, not
  the MaaS name: `claude-haiku-4-5` is reported as `claude-haiku-4-5-20251001`.
  The MaaS name is in `limitador_namespace` (`maas-models/claude-haiku-4-5`).
- Counters live in Limitador's memory. Prometheus keeps the history, but only
  from the moment it started scraping.

**`captureUser` is off by default** and on here; the reasoning is in
`base/maas-telemetry.yaml`. It is the only one of the five that is a judgement
rather than a prerequisite.

**Red Hat's guide patches the wrong object.** Its "Enable telemetry" step edits
`Tenant/default-tenant`. `Tenant` is deprecated, and a cluster installed at 3.5
has none; the settings live on `MaasTenantConfig/default-tenant` in
`models-as-a-service`.

Checking it, in the order the data flows:

```bash
# the gateway is labelling: a TelemetryPolicy exists
oc get telemetrypolicies.extensions.kuadrant.io -A

# Limitador has per-user series (after at least one request)
oc exec -n kuadrant-system deploy/limitador-limitador -- \
  curl -s localhost:8080/metrics | grep '^authorized_hits'

# the metrics stack is up
oc get dscinitialization default-dsci -o json | jq -r \
  '.status.conditions[] | select(.type|test("MonitoringStack|Perses|Collector")) | "\(.type) \(.status)"'
oc get pods -n redhat-ods-monitoring

# RHOAI's Prometheus has them. It serves TLS, and the counters are named
# *_total here: they arrive through the OpenTelemetry collector, which adds it.
oc exec -n redhat-ods-monitoring prometheus-data-science-monitoringstack-0 -c prometheus -- \
  curl -sk https://localhost:9090/api/v1/query \
  --data-urlencode 'query=sum by (user, model, subscription) (authorized_hits_total{user!=""})'
```

The same counters are also in cluster monitoring, under their plain names
(`authorized_hits`), through Kuadrant's PodMonitor and user workload monitoring.
So Observe → Metrics in the OpenShift console can answer the question too.

**Verified on the hub, 2026-10-12.** All of the above, end to end, with
`dlbewley` appearing as the `user`. Three things seen along the way:

- For a few minutes after the collectors start, both replicas report the same
  Limitador series and every total reads double. It clears once the target
  allocator has settled and the stale copy expires. Expect it again briefly
  whenever a collector pod is replaced.
- The stack is bigger than `metrics` suggests: two Alertmanagers and two
  collectors are deployed even with `alerting` unset and one Prometheus
  replica. About 600Mi of memory in total, idle.
- `Monitoring/default-monitoring` kept reporting `DeploymentsAvailable=False`
  ("2/3 deployments ready") after every pod was running. `Ready` is True and the
  DSCI is healthy; it looks stale rather than wrong, and is not chased here.

**Not enabled: the log-based pipeline.** 3.5 adds a second route to the same
report, `usageLogging: true` on the MaaS `Config`, built on gateway access logs
in Loki rather than on metrics. It is more accurate, keeps 30 days on object
storage, and gives each non-admin user a dashboard of their own usage. It needs
the Loki operator and a `LokiStack` named `usage`.

## The maas-controller needs more memory than it ships with

`overlays/hub/maas-controller-memory.yaml` raises one number: the memory limit
on RHOAI's `maas-controller`, from 512Mi to 1Gi.

With the shipped limit the controller could not stay up on the hub. It reached
400–510Mi within 90 seconds of starting and was OOM-killed, five times in ten
minutes, into `CrashLoopBackOff`. Given room it settles at 550–615Mi. It is not
a leak or a reconcile loop — it dies filling its caches, and the hub has about
1,600 Secrets and 1,400 ConfigMaps in 125 namespaces because it is also the ACM
hub.

**It is easy to miss.** The controller's first reconcile completed before its
first kill, so `maas-api` and the gateway policies existed and
`ModelsAsAServiceReady` said `True`. Requests are served without it. But a new
model, subscription or auth policy is not reconciled by a controller that is
dead most of the time. Look at the pod, not the condition:

```bash
oc get pods -n redhat-ods-applications -l control-plane=maas-controller
```

```bash
oc get pod -n redhat-ods-applications -l control-plane=maas-controller -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount} restarts, last: {.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
```

There is no supported setting for this. Neither the `AIGateway` CR nor the maas
`Config` CR has a resources field, so the manifest is a partial `Deployment`
merged in by server-side apply, `Prune=false,Delete=false`. The
ai-gateway-operator was seen to re-apply the Deployment seconds after the limit
was changed and leave the new value alone.

It is in `overlays/hub` because the right number depends on the size of the
cluster. Revisit it after an RHOAI upgrade: upstream has since restricted this
controller's Secret cache to a single namespace, which should bring the need
down and may make the override unnecessary. Tracked as `homelab-2026-o8y.11`.

## Verifying

ArgoCD cannot judge this. A DataScienceCluster has no health check ArgoCD
knows, so the Application reports Healthy while components are still coming up.

```bash
oc get datasciencecluster default-dsc
```

```bash
oc get datasciencecluster default-dsc -o json | jq -r '.status.conditions[] | "\(.type)\t\(.status)\t\(.message // "")"'
```

Expect `Ready=True`, with every Managed component Ready and every Removed one
reporting `Removed`. `ModelsAsAServiceReady` is the one that depends on the four
components above.

```bash
oc get pods -n redhat-ods-applications
```

```bash
oc get aitenant -n ai-tenants; oc get maastenantconfig -n models-as-a-service
```

```bash
oc get deployment maas-api -n redhat-ai-gateway-infra
```

If Connectivity Link was installed after the KServe controllers started, they
may not notice it; see
[connectivity-link](../connectivity-link/README.md#order-of-installation-against-rhoai).

## Upgrading

The Subscription is pinned to `stable-3.5`, so 3.6 arrives only when someone
changes it. Before doing so:

- Every 3.x minor so far has moved things in this object. 3.5 moved MaaS from
  `kserve` to `aigateway`.
- Upstream MaaS has
  [per-release upgrade notes](https://opendatahub-io.github.io/models-as-a-service/latest/migration/upgrade-to-3.5/).
- Red Hat's [supported configurations](https://access.redhat.com/articles/rhoai-supported-configs-3.x)
  list which OpenShift versions each release supports. For 3.5 that includes
  4.22, although the 3.5 install guide's own requirements section still says
  4.19 to 4.20.

## Removing

Deleting this Application deletes the DataScienceCluster and every component
with it, but not the DSCInitialization. Uninstalling the product properly is a
documented procedure, and it did not go cleanly the one time it was done on this
hub: namespaces hung on finalizers whose controllers had already been removed,
and a leftover `Auth` resource had to be deleted by hand. `bd show
homelab-2026-o8y.2` has the full record.

- [Uninstalling OpenShift AI Self-Managed](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/installing_and_uninstalling_openshift_ai_self-managed/uninstalling-openshift-ai-self-managed_uninstalling-openshift-ai-self-managed)

## References

- [Govern LLM access with Models-as-a-Service 3.5, §1.18: Monitor usage by using the observability dashboard](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html-single/govern_llm_access_with_models-as-a-service/index)
- [Managing OpenShift AI 3.5: Manage observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_openshift_ai/managing-observability_managing-rhoai)

- [Govern LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service)
- [Working with OGX](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_ogx/overview-of-ogx_rag)
- [Working with MLflow](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_mlflow/installing-mlflow_mlflow)
- [gitops-catalog `openshift-ai`](https://github.com/redhat-cop/gitops-catalog/tree/main/openshift-ai) — the operator half is current; its instance half still uses the v1 DataScienceCluster API and should not be copied
