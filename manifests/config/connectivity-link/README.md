# connectivity-link

[Red Hat Connectivity Link](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4)
— the productised [Kuadrant](https://kuadrant.io/) — and the `Kuadrant` instance
that makes it do something.

| | |
|---|---|
| package | `rhcl-operator` |
| catalog | `redhat-operators` |
| channel | `stable` (the only one) |
| CSV | `rhcl-operator.v1.4.3` |
| install mode | AllNamespaces → `spec: {}` |
| namespace | `kuadrant-system` |

## Why it is here

Red Hat OpenShift AI's Models-as-a-Service does not enforce anything itself. It
writes `kuadrant.io` policies and this operator's Authorino and Limitador carry
them out:

| MaaS wants | Kuadrant object | Enforced by |
|---|---|---|
| "is this API key valid, may this user call this model" | `AuthPolicy` | Authorino |
| "how many tokens may this subscription spend" | `TokenRateLimitPolicy` | Limitador |

Both attach to the MaaS `Gateway` in `openshift-ingress` and to per-model
`HTTPRoute`s. Without this operator none of those kinds exist, and the
DataScienceCluster says so: `Red Hat Connectivity Link not installed`.

Tracked as `homelab-2026-o8y.3`, part of the epic `homelab-2026-o8y`.

## Pieces

| What | Where | Why |
|---|---|---|
| `rhcl-operator` | `manifests/olm/connectivity-link` | Pulls in `authorino-operator`, `limitador-operator` and `dns-operator` with it |
| `Kuadrant/kuadrant` | `base/kuadrant.yaml` | Deploys Authorino and Limitador. No spec |

## The namespace, and where Red Hat's guides disagree

| Guide | Operator goes in | `Kuadrant` CR goes in |
|---|---|---|
| [Connectivity Link 1.4 — Install on OpenShift](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/install_connectivity_link/rhcl-install-on-ocp) | a namespace of your choice; `kuadrant-system` in every example | the same |
| [RHOAI 3.5 — MaaS prerequisites](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service#maas-prerequisites_maas-deploy) | `openshift-operators` | `kuadrant-system` |

They agree on what matters to MaaS: AllNamespaces install mode, and the
`Kuadrant` CR, Authorino and Limitador in `kuadrant-system`. They differ only on
which namespace holds the operator pod.

This repo uses `kuadrant-system` for both. Every operator here has its own
namespace and a named OperatorGroup, and nothing is installed into
`openshift-operators`.

**If RHOAI still reports Connectivity Link as missing once this is installed,
that choice is the first thing to revisit** — move the Subscription to
`openshift-operators` (which already has the `global-operators` OperatorGroup,
so it needs no OperatorGroup of its own) and leave the `Kuadrant` CR where it is.

## Prerequisite: the `openshift-default` GatewayClass

On OpenShift 4.19 and later the Ingress Operator is the Gateway API controller
and Connectivity Link expects a GatewayClass named `openshift-default` with
`controllerName: openshift.io/gateway-controller/v1`. Creating it is what makes
the Ingress Operator deploy `istiod` into `openshift-ingress`.

It is not declared here. It belongs with the Gateway that uses it — the MaaS
gateway, `homelab-2026-o8y.6`. Until that lands, the `Kuadrant` CR may report
that no gateway provider is available. That is expected and not a fault in this
component.

## Order of installation against RHOAI

Applications here converge by retry, not in a fixed order, so RHOAI may come up
before this does. Red Hat's llm-d guide has a step for exactly that case: if
OpenShift AI was installed before Connectivity Link, delete the
`odh-model-controller` and `kserve-controller-manager` pods so they notice it.

```bash
oc delete pod -n redhat-ods-applications -l app=odh-model-controller
```

```bash
oc delete pod -n redhat-ods-applications -l control-plane=kserve-controller-manager
```

Those label selectors are the conventional ones and have not been checked
against a running 3.5 install; confirm with `oc get pods --show-labels` first.

- [Configure authentication by using Red Hat Connectivity Link](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/configuring-authentication-for-llmd_distributed-inference)

## Verifying

ArgoCD reports Synced/Healthy whether or not the operator installed, so look at
the CSV:

```bash
oc get csv -n kuadrant-system
```

```bash
oc get deployments -n kuadrant-system
```

Expect `kuadrant-operator-controller-manager`, `authorino-operator`,
`limitador-operator-controller-manager`, `dns-operator-controller-manager` and
`kuadrant-console-plugin` from the operator, then `authorino` and
`limitador-limitador` once the `Kuadrant` CR is reconciled.

```bash
oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready=true --timeout=300s
```

## Not configured

**Authorino TLS.** MaaS needs TLS on Authorino's authorization listener and a CA
bundle on its outbound calls. That is `homelab-2026-o8y.8`, kept separate
because one of its steps edits a Deployment the Authorino operator owns.

**Observability.** `spec.observability.enable` on the `Kuadrant` CR creates the
PodMonitors MaaS usage metrics are built on. Not set. For the same reason
`kuadrant-system` does not carry `openshift.io/cluster-monitoring`, unlike most
operator namespaces here — see the comment in the Namespace manifest.

**Subscription tuning.** Upstream MaaS suggests `AUTH_SERVICE_TIMEOUT` and
`RATELIMIT_CHECK_SERVICE_FAILURE_MODE` / `RATELIMIT_REPORT_SERVICE_FAILURE_MODE`
on the operator Subscription. No Red Hat document mentions them. The second pair
decides whether rate limits fail open or closed when Limitador is down, which is
worth a deliberate decision before anything depends on those limits.

## References

- [Deploy Connectivity Link — gateway policies](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/deploy_red_hat_connectivity_link/rhcl-config-deploy-gateway-policies), including token-based rate limiting
- Kuadrant: [AuthPolicy](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/reference/authpolicy/), [TokenRateLimitPolicy](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/reference/tokenratelimitpolicy/)
- Upstream MaaS: [platform setup](https://opendatahub-io.github.io/models-as-a-service/v0.2.0/install/platform-setup/)
