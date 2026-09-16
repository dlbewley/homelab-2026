# network-operator

Routing and policy features on the cluster Network operator CR
(`network.operator.openshift.io/cluster`): FRR, BGP route advertisements, the
gateway settings that BGP EVPN with primary CUDNs requires, and
MultiNetworkPolicy for secondary networks.

## What this replaces

Four hand-run patches, now declared in `overlays/hub/network.yaml`:

```bash
# Enable FRR
oc patch network.operator cluster --type merge --patch \
  '{"spec":{"additionalRoutingCapabilities":{"providers":["FRR"]}}}'

# Enable BGP
oc patch network.operator cluster --type merge --patch \
  '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'

# Enable BGP EVPN with primary CUDNs (local gateway mode)
oc patch network.operator cluster --type merge --patch \
  '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'

# Enable global IP forwarding
oc patch network.operator cluster --type merge --patch \
  '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding":"Global"}}}}}'
```

## Why each setting

| field | value | why |
|---|---|---|
| `additionalRoutingCapabilities.providers` | `[FRR]` | Deploys the FRR-K8s daemon — the prerequisite for any route advertisement |
| `defaultNetwork.ovnKubernetesConfig.routeAdvertisements` | `Enabled` | Turns on BGP advertisement of pod networks; makes `RouteAdvertisements` CRs functional |
| `…gatewayConfig.routingViaHost` | `true` | Local gateway mode: egress traffic uses the host routing table, where FRR's learned routes live. Required for EVPN with primary CUDNs |
| `…gatewayConfig.ipForwarding` | `Global` | Forwarding on all host interfaces, not only OVN-managed ones |
| `useMultiNetworkPolicy` | `true` | Enables the `MultiNetworkPolicy` CRD and controller, so NetworkPolicy-style rules can govern secondary (Multus) network attachments. Defaults to `false`. See [Configuring multi-network policy](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/multiple_networks/index#configuring-multi-network-policy) |

**Future test** for `ipForwarding`: return to the default `Restricted` and
enable forwarding only on VTEPs and selective interfaces (via sysctl / NNCP)
instead of globally.

## Per-cluster conditionality

Which clusters get which routing features is exactly the repo's overlay
convention: the hub declares all of the above in `overlays/hub`; a cluster
without an overlay entry in its ApplicationSet gets no patch at all, and a
future overlay can declare a subset. `base` is intentionally empty.

## Server-side apply — expected to work, verify on first sync

This is the opposite call from [image-registry](../image-registry), and the
difference is worth stating.

`network/cluster` is installer-created and operator-managed, so ownership
caution applies. But SSA conflicts only occur when **changing** a field owned
by another manager — applying a value **identical** to the live one takes
shared ownership silently. Since these values were first applied by hand, the
first ArgoCD sync should co-own them without conflict, and from then on git is
an owner of record.

Verify before trusting it (credentials required):

```bash
oc get network.operator cluster -o json --show-managed-fields \
  | jq '[.metadata.managedFields[] | {manager, operation}]'
```

```bash
oc apply --server-side --dry-run=server \
  -f manifests/config/network-operator/overlays/hub/network.yaml
```

> `oc get -o json` **hides** `managedFields` without `--show-managed-fields`;
> an empty result means the flag is missing, not that nothing owns the fields.

If the sync does report `conflicts with "cluster-network-operator"`, fall back
to the image-registry precedent: add `ServerSideApply=false` to the
`argocd.argoproj.io/sync-options` annotation on the Network CR, which merges
only the declared fields client-side.

`Prune=false,Delete=false` is on the CR unconditionally: it is cluster-scoped,
pre-existing, and required for the cluster to function. ArgoCD merges fields
into it; it must never delete it.

Unlike the four routing fields, `useMultiNetworkPolicy` was never applied by
hand — but an unset field has no owner, so server-side apply sets it without
conflict either way.

## Verifying

The MultiNetworkPolicy CRD appears once enabled:

```bash
oc get crd multi-networkpolicies.k8s.cni.cncf.io
```

FRR pods appear once the provider is enabled:

```bash
oc get pods -n openshift-frr-k8s
```

The gateway mode change rolls the ovnkube-node daemonset; watch it settle:

```bash
oc rollout status -n openshift-ovn-kubernetes daemonset/ovnkube-node
```

Confirm the live spec matches git:

```bash
oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig}' | jq
```
