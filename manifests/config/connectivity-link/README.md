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

**It works.** With the operator in `kuadrant-system`, the DataScienceCluster
reports `KserveLLMInferenceServiceDependencies=True` and Models-as-a-Service
reaches Ready (hub, 2026-10-11). `openshift-operators` is not required.

## Prerequisite: the `openshift-default` GatewayClass

On OpenShift 4.19 and later the Ingress Operator is the Gateway API controller
and Connectivity Link expects a GatewayClass named `openshift-default` with
`controllerName: openshift.io/gateway-controller/v1`. Creating it is what makes
the Ingress Operator deploy `istiod` into `openshift-ingress`.

It is not declared here. It belongs with the Gateway that uses it — the MaaS
gateway, `homelab-2026-o8y.6`. Until that lands, the `Kuadrant` CR may report
that no gateway provider is available. That is expected and not a fault in this
component.

## Authorino TLS

Models-as-a-Service needs TLS on both sides of Authorino. `base/authorino-tls.yaml`
sets it up, following
[Red Hat's procedure](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service#configure-tls-for-maas_maas-deploy)
with one correction.

```
gateway ──gRPC/TLS :50051──▶ Authorino ──HTTPS──▶ maas-api
```

| Step | Object | Field |
|---|---|---|
| 1 | `Service/authorino-authorino-authorization` | annotation `service.beta.openshift.io/serving-cert-secret-name: authorino-server-cert` |
| 2 | `Authorino/authorino` | `spec.listener.tls.enabled: true`, `certSecretRef.name: authorino-server-cert` |
| 3 | `Deployment/authorino` | env `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` |
| 4 | `Gateway/maas-default-gateway` | annotation `security.opendatahub.io/authorino-tls-bootstrap: "true"` — in [maas-gateway](../maas-gateway) |

### None of these objects belongs to this repo

The Kuadrant operator creates the `Authorino` CR; the Authorino operator
creates the Service and Deployment from it. The manifests here are deliberately
**partial** — only the fields in the table — and server-side apply merges them
into the operator's objects. Each carries `Prune=false,Delete=false`, so removing
the file stops managing those fields and never deletes Authorino. The same
technique as [network-operator](../network-operator).

Two consequences:

- **Step 2 takes a field from the Kuadrant operator.** It creates the CR with
  `listener.tls.enabled: false` and owns that field; a plain server-side apply
  reports the conflict, and ArgoCD forces it. Red Hat's guide makes the same
  change with `oc patch` and expects it to hold. If the operator ever re-asserts
  it, `hub-cfg-connectivity-link` will flap and Authorino will restart in a loop.
- **Step 3 edits a generated Deployment** because the `Authorino` CR has no field
  for environment variables. There is no better-supported mechanism: Red Hat's
  guide does the same with `oc set env`, and the Connectivity Link 1.4
  documentation says nothing about Authorino TLS at all.

### The CA path is not the one in Red Hat's guide

The RHOAI 3.5 guide sets both variables to
`/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt`.

**That file does not exist in the Authorino pod.** Checked on the hub
2026-10-11: nothing mounts it, and the Authorino operator reverts volumes added
to its Deployment. Worse, it fails silently — Go ignores an `SSL_CERT_FILE` it
cannot read and falls back to the system trust store, so there is no error in
the logs and the service CA is simply never trusted.

This repo uses `/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt`,
the service CA bundle OpenShift projects into every pod. Upstream MaaS
[made the same switch](https://opendatahub-io.github.io/models-as-a-service/latest/configuration-and-management/tls-configuration/)
for the same reason. Check the file, do not infer it from quiet logs:

```bash
oc exec -n kuadrant-system deploy/authorino -- ls -l /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
```

### Verifying

```bash
oc get secret authorino-server-cert -n kuadrant-system
```

```bash
oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls}{"\n"}'
```

```bash
oc set env deployment/authorino -n kuadrant-system --list
```

Run the last two again a few minutes later. Unchanged output is the evidence
that neither operator is reverting the fields.

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

**Rate-limit failure mode.** Upstream MaaS suggests
`RATELIMIT_CHECK_SERVICE_FAILURE_MODE` / `RATELIMIT_REPORT_SERVICE_FAILURE_MODE`
on the operator Subscription. They decide whether token limits fail open or
closed when Limitador is down, which is worth a deliberate decision before
anything depends on those limits. No Red Hat document mentions them.

## Observability is on

`spec.observability.enable: true` on the `Kuadrant` CR makes the operator create
PodMonitors for Limitador, Authorino and its own controllers. It is one of five
settings behind the Models-as-a-Service usage report; the other four and the
whole picture are in the [rhoai README](../rhoai/README.md#token-usage-per-user).

`kuadrant-system` does not carry `openshift.io/cluster-monitoring`, unlike most
operator namespaces here, so these are scraped by user workload monitoring and
show up in the console under Observe → Metrics:

```bash
oc get podmonitors.monitoring.coreos.com -n kuadrant-system
```

## The auth timeout is raised to 2 seconds

The Subscription sets `AUTH_SERVICE_TIMEOUT: "2s"`. The default is 200ms: how
long the gateway's policy filter waits for Authorino before failing the request
with a `500`.

For Models-as-a-Service that is too tight. Validating an API key means Authorino
calling `maas-api`, which may first have to open a database connection. On the
hub, in the minutes after the models were re-registered, 5 of about 40 requests
made with an API key returned `500`, while `maas-api` logged its database
lookups being cancelled by a caller that had given up:

```
API key validation failed: database lookup failed: ... operation was canceled
```

Authorino itself was healthy throughout: 134 of 146 checks finished in under
100ms and all in under 250ms. The failures were the slow first calls. Sixty
requests a few minutes later all succeeded.

[Upstream MaaS](https://opendatahub-io.github.io/models-as-a-service/latest/install/platform-setup/)
documents this symptom and this fix. No Red Hat document mentions the variable,
but the operator in `rhcl-operator.v1.4.3` does read it.

After the change the gateway's generated filter configuration shows the auth
service at `timeout: 2s`, `failureMode: deny`.

**The rate-limit services are a different story, and worth knowing about.**
The same configuration shows them at `timeout: 100ms`, `failureMode: allow`:
if Limitador is slow or down, requests are let through uncounted. The token
budgets on the paid models are therefore a soft cap, not a hard one. Setting
`RATELIMIT_CHECK_SERVICE_FAILURE_MODE` and `RATELIMIT_REPORT_SERVICE_FAILURE_MODE`
to `deny` would make them fail closed, at the price of failed requests whenever
Limitador does not answer within its timeout. Not changed; tracked as
`homelab-2026-o8y.15`.

To see whether auth timeouts are still happening:

```bash
oc logs -n redhat-ai-gateway-infra deploy/maas-api --since=1h | grep -c 'API key validation failed'
```

## References

- [Deploy Connectivity Link — gateway policies](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/deploy_red_hat_connectivity_link/rhcl-config-deploy-gateway-policies), including token-based rate limiting
- Kuadrant: [AuthPolicy](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/reference/authpolicy/), [TokenRateLimitPolicy](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/reference/tokenratelimitpolicy/)
- Upstream MaaS: [platform setup](https://opendatahub-io.github.io/models-as-a-service/v0.2.0/install/platform-setup/)
