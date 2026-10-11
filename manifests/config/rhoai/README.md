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

## Not configured: dashboard feature flags

The MaaS pages in the dashboard are switched on in `OdhDashboardConfig`
(`odh-dashboard-config` in `redhat-ods-applications`), under
`spec.dashboardConfig`:

| Flag | Effect |
|---|---|
| `modelAsService` | The Models-as-a-Service UI |
| `genAiStudio` | Gen AI studio and playground; needs `ogx` Managed |
| `externalModels` | The external models page (Technology Preview) |

They are **deliberately not declared yet.** The operator creates that object,
with its defaults, when it deploys the dashboard, and upstream says it does not
overwrite one that already exists. If ArgoCD applied a partial object first, the
dashboard could be left with only the fields git declares. So the flags follow
once the object exists, as a server-side-apply patch like the others here.

Do **not** set `maasAuthPolicies`. Red Hat's guide still lists it; the CRD marks
it deprecated and its validation rejects setting it on a new install.

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

- [Govern LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service)
- [Working with OGX](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_ogx/overview-of-ogx_rag)
- [Working with MLflow](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_mlflow/installing-mlflow_mlflow)
- [gitops-catalog `openshift-ai`](https://github.com/redhat-cop/gitops-catalog/tree/main/openshift-ai) — the operator half is current; its instance half still uses the v1 DataScienceCluster API and should not be copied
