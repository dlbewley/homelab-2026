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

## MaaS has to be told its own public name

Behind a Route, the Gateway object says nothing about where it is reachable:
its listener has no hostname and its status address is the in-cluster Service.
That is fine for traffic and wrong for one consumer. The dashboard's MaaS pages
and Gen AI studio ask `maas-api` for the gateway's external URL
(`GET /v1/tenants`), and `maas-api` works it out from the Gateway alone — the
hostname of the first ready HTTPS listener, else `status.addresses`. It will not
hand out a `.svc.cluster.local` name, and it cannot see the Route. On the hub
this was failing every 30 seconds:

```
maas-api GET /v1/tenants returned 500:
  Unable to determine external hostname from Gateway status
```

with the result that no MaaS models appeared in Gen AI studio. Requests to the
gateway itself were unaffected, which is why the earlier end-to-end checks
passed.

The hub overlay fixes it by adding a second listener, `https-external`, first in
the list and carrying `maas.apps.hub.lab.bewley.net`. The original listener
stays, with no hostname, as the catch-all:

| Listener | Hostname | Purpose |
|---|---|---|
| `https-external` | `maas.apps.hub.lab.bewley.net` | Gives `maas-api` the public name. Also serves connections that name that host |
| `https` | none | Serves everything else, as before |

Putting the hostname on the single listener instead would be simpler and is
what `maas-api`'s own log message recommends, but a listener with a hostname
accepts only TLS connections that name it, and upstream warns that this causes
SNI trouble behind a router. With both, traffic cannot get worse. Both use the
same certificate, and MaaS's HTTPRoutes name no listener, so they attach to
both.

Check it:

```bash
oc logs -n redhat-ods-applications deploy/maas-ui --since=2m | grep -c 'MaaS API discovery failed'
```

should print `0`, and both listeners should be programmed with routes attached:

```bash
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.attachedRoutes}{"\n"}{end}'
```

## Three details that are easy to get wrong

**The catch-all listener has no hostname.** Upstream warns that hostname
filters on the Gateway cause TLS and SNI trouble behind the router. The Route
decides the hostname; the `https` listener accepts whatever arrives. The
`https-external` listener beside it exists for a different reason, above.

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
Envoy is the healthy answer (seen on the hub 2026-10-11). Once MaaS is enabled
the healthy answer becomes `401`, because the gateway now requires
authentication on every path. A `503`
from the router instead means it has no usable backend: check that the Secret
`maas-gw-service-tls` exists and the gateway pods are Ready.

## If every request returns 503

Seen on the hub the first time MaaS attached its policies to this Gateway. Every
path returned an empty `503`, including ones with no route, and the gateway's
access log tagged each request `wasm_fail_stream`:

```bash
oc logs -n openshift-ingress deploy/maas-default-gateway-openshift-default | grep -iE 'wasm|Retry limit'
```

```
Retry limit exceeded for fetching data from remote data source.
Plugin kuadrant-wasm-shim failed to load
Plugin configured to fail closed failed to load
```

Connectivity Link enforces its policies in Envoy with a WebAssembly filter, which
Envoy downloads from the Kuadrant operator
(`http://kuadrant-operator-wasm.kuadrant-system.svc.cluster.local:8082/plugin.wasm`).
The download is attempted once, at the moment the policies are first attached.
On the hub that one attempt failed within 80 milliseconds — the upstream it uses
is added by the same configuration push — and the filter fails closed and does
not try again. The URL answered normally from inside the same pods minutes
later.

It is a first-attach race, not a configuration error. Replace the gateway pods
one at a time, so the Route keeps a backend throughout; a pod that starts with
the configuration already in place loads the filter cleanly:

```bash
oc get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
```

```bash
oc delete pod -n openshift-ingress <one-pod-name>
```

```bash
oc rollout status -n openshift-ingress deploy/maas-default-gateway-openshift-default
```

Then the other. Healthy afterwards is `401` without credentials, not `503`:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://maas.apps.hub.lab.bewley.net/v1/models
```

Expect this again on a cluster rebuild.

## Authorino TLS

The Gateway carries
`security.opendatahub.io/authorino-tls-bootstrap: "true"`, which makes the
maas-controller have the gateway speak TLS to Authorino. The matching Authorino
configuration is in [connectivity-link](../connectivity-link/README.md#authorino-tls).

## References

- OpenShift 4.22: [route timeouts](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/routes#nw-configuring-route-timeouts_configuring-routes), [IngressController parameters](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/networking_operators/configuring-ingress#nw-ingress-controller-configuration-parameters_configuring-ingress), [service serving certificates](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/configuring-certificates#add-service-serving)
- Upstream MaaS: [install — create gateway](https://opendatahub-io.github.io/models-as-a-service/v0.2.0/install/maas-setup/)
