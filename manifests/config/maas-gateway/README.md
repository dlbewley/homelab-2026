# maas-gateway

The Gateway that Red Hat OpenShift AI's Models-as-a-Service (MaaS) sends every
model, and its own API, through — and the Route that gives it a public name.

Config-only. There is no operator to install: the Gateway API CRDs ship with
OpenShift and the Ingress Operator is the controller.

## Why it is here

RHOAI does not create this Gateway. With MaaS enabled and no Gateway, the
DataScienceCluster sits at:

```
ModelsAsAServiceReady  False
  AITenant: gateway openshift-ingress/maas-default-gateway not found: the Gateway
  must be created by a network or cluster administrator before AITenant can be
  provisioned
```

Nothing else MaaS does starts until it exists. Tracked as `homelab-2026-o8y.6`,
part of the epic `homelab-2026-o8y`.

## Pieces

| What | Where | Why |
|---|---|---|
| `GatewayClass/openshift-default` | `base/gatewayclass.yaml` | Turns on OpenShift's Gateway API controller. **Shared** — see below |
| `ConfigMap/maas-gateway-options` | `base/gateway-options.yaml` | Makes the generated Service ClusterIP, with a service-ca certificate |
| `Gateway/maas-default-gateway` | `base/gateway.yaml` | Name and namespace are fixed by MaaS |
| `Route/maas-gateway-route` | `overlays/hub/route.yaml` | `maas.apps.hub.lab.bewley.net`, reencrypt |

## How traffic gets in

```
client ──HTTPS──▶ router (HostNetwork) ──reencrypt──▶ Service (ClusterIP :443)
        wildcard cert                    service-ca cert        │
        from homelab-ca                                         ▼
                                                      Envoy (the Gateway)
                                                                │ HTTPRoute
                                                                ▼
                                                    maas-api / a model
```

The hub's default IngressController is HostNetwork, so `*.apps.hub.lab.bewley.net`
and its certificate already cover `maas.apps.hub.lab.bewley.net`. This path
needs no new DNS record, no MetalLB address and no new certificate.

## How well supported is ClusterIP + Route?

Honestly mixed, and worth knowing before leaning on it.

| Source | Position |
|---|---|
| RHOAI itself | Does exactly this for its own dashboard gateway (`GatewayConfig` with `ingressMode: OcpRoute`): ClusterIP Service through `infrastructure.parametersRef`, reencrypt Route. Seen on this hub |
| [Upstream MaaS — gateway patterns](https://opendatahub-io.github.io/models-as-a-service/v0.2.0/configuration-and-management/gateway-patterns/) | Documents it as the pattern for on-prem and bare metal, with [sample manifests](https://github.com/opendatahub-io/models-as-a-service/tree/v0.2.0/docs/samples/gateway-patterns/clusterip-route-reencrypt) this is based on |
| [RHOAI 3.5 — MaaS gateway requirements](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service#maas-gateway-requirements_maas-deploy) | States the Gateway's name, namespace, class and two annotations. Gives no manifest and says nothing about the Service type |
| [OpenShift 4.22 — Configuring Gateway API](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/configuring-gateway-api) | Describes **only** a LoadBalancer Service. Says on-premise clusters need a load-balancer controller, with MetalLB the tested one. Never mentions `parametersRef` or ClusterIP |

So it works, the product does it to itself, and OpenShift's own Gateway API
documentation does not describe it.

### The fallback OpenShift does document

Let the Gateway take a LoadBalancer address from MetalLB instead:

1. Delete `infrastructure.parametersRef` from the Gateway and drop
   `gateway-options.yaml`. The generated Service becomes `LoadBalancer` and takes
   an address from `lab-pool`.
2. Replace the service-ca certificate with one from `homelab-ca` for the public
   hostname (a `Certificate` in `openshift-ingress`).
3. Drop the Route and add a DNS record for the hostname pointing at the MetalLB
   address. It cannot stay under `*.apps`, which resolves to the router.

More moving parts, which is why it is the fallback and not the default.

## `openshift-default` is shared

Creating a GatewayClass with `controllerName: openshift.io/gateway-controller/v1`
is what makes the Ingress Operator deploy `istiod-openshift-gateway` into
`openshift-ingress`. Deleting it removes that again, along with every Gateway of
the class.

This component creates it because the MaaS Gateway is the first thing here to
need it, but Connectivity Link expects it too and any later Gateway will use it.
It carries `Prune=false,Delete=false` so that removing MaaS — deleting this
Application — does not take the cluster's Gateway API controller with it. To
remove it deliberately:

```bash
oc delete gatewayclass openshift-default
```

RHOAI creates a second class of its own, `data-science-gateway-class`, for the
dashboard. Same controller, unrelated to this one.

## Three details that are easy to get wrong

**No hostname on the listener.** Upstream warns that hostname filters on the
Gateway cause TLS and SNI trouble behind the router. The Route decides the
hostname; the listener accepts whatever arrives.

**No `destinationCACertificate` on the Route.** Upstream's sample pastes the
service CA bundle in. That is a cluster-specific value that rotates. It is not
needed: per the [Route API reference](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/network_apis/route-route-openshift-io-v1),
a reencrypt Route without one has the router validate the backend against its
own destination CA and the Service hostname, which a service-ca certificate
satisfies. RHOAI's own dashboard Route on this hub carried none either.

**The Route timeout.** The router waits 30 seconds for a backend to start
responding (the IngressController's `serverTimeout` default). A long
non-streamed completion can take longer and the client would get a 504 from the
router. The Route sets `haproxy.router.openshift.io/timeout: 5m`, the same 300
seconds the MaaS payload processor allows itself. That is a starting value to be
checked against real generations, not a measured one.

## Order

Within the Application, by sync wave:

```
0  GatewayClass/openshift-default   Ingress Operator deploys istiod
1  ConfigMap/maas-gateway-options
2  Gateway/maas-default-gateway     controller creates the Service; service-ca
                                    writes maas-gw-service-tls; listener programs
5  Route/maas-gateway-route         needs the Service the controller creates
```

Across Applications there is no ordering. RHOAI and Connectivity Link may land
before or after this; MaaS retries its gateway check until it passes.

## Verifying

```bash
oc get gatewayclass openshift-default
```

`ACCEPTED` should be `True`.

```bash
oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=180s
```

The Gateway will also report `LoadBalancerReady=False`, reason
`LoadBalancerPending`. That is expected and harmless here: the Ingress Operator
sets it because it assumes a LoadBalancer Service, and there deliberately is
none. RHOAI's own `data-science-gateway` shows the same condition. ArgoCD still
reports the Gateway Healthy.

```bash
oc get svc -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
```

The Service should be `ClusterIP` and named
`maas-default-gateway-openshift-default`. If the name differs, the Route's
`spec.to.name` must be changed to match.

```bash
oc get route maas-gateway-route -n openshift-ingress
```

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://maas.apps.hub.lab.bewley.net/
```

Before MaaS attaches any HTTPRoute there is nothing to route to, so a `404` from
Envoy is the healthy answer (seen on the hub 2026-10-11). A `503`
from the router instead means it has no usable backend: check that the Secret
`maas-gw-service-tls` exists and the gateway pods are Ready.

## Authorino TLS

The Gateway carries
`security.opendatahub.io/authorino-tls-bootstrap: "true"`, which makes the
maas-controller have the gateway speak TLS to Authorino. The matching Authorino
configuration is in [connectivity-link](../connectivity-link/README.md#authorino-tls).

## References

- OpenShift 4.22: [route timeouts](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/routes#nw-configuring-route-timeouts_configuring-routes), [IngressController parameters](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/networking_operators/configuring-ingress#nw-ingress-controller-configuration-parameters_configuring-ingress), [service serving certificates](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/configuring-certificates#add-service-serving)
- Upstream MaaS: [install — create gateway](https://opendatahub-io.github.io/models-as-a-service/v0.2.0/install/maas-setup/)
