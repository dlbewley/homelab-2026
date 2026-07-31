# manifests

Reusable building blocks. Nothing here decides *which* cluster gets *what* —
that lives in [clusters/](../clusters/).

Everything here is a plain `kind: Kustomization` forming base/overlay chains, so
each directory can be built standalone — which is what an ArgoCD Application
requires. These are "components" only in the ordinary sense of the word; none is
a Kustomize `kind: Component`. That feature is reserved for
[`components/`](../components/), which explains when to reach for it.

## olm/

Installs an operator. Each `base/` is the same three objects:

| File | Wave | Why |
|---|---|---|
| `namespace.yaml` | 0 | Declared here rather than via `CreateNamespace=true` so it can carry `openshift.io/cluster-monitoring` |
| `operatorgroup.yaml` | 1 | Own-namespace install mode |
| `subscription.yaml` | 2 | Channel pinned, `installPlanApproval: Automatic` |

The OperatorGroup shape must match what the operator supports. `targetNamespaces`
requests OwnNamespace/SingleNamespace; an empty `spec: {}` requests AllNamespaces.
`metallb` and `external-secrets` are AllNamespaces-only; the rest use
`targetNamespaces`.

`scripts/verify-channels.sh` checks both the pinned channel and the
OperatorGroup shape against the catalog. Run it after an OpenShift upgrade, and
after adding any component:

```bash
scripts/verify-channels.sh
```

> **ArgoCD will not catch a failed operator install.** It manages the Namespace,
> OperatorGroup and Subscription; the CSV is created by OLM and is not part of
> the Application, so the app reports Synced/Healthy while the operator sits in
> `Failed`. Confirm an operator actually installed by looking at the CSV, not at
> ArgoCD:
>
> ```bash
> oc get csv -A | grep -v Succeeded
> ```

## config/

The CRs that make an installed operator do something.

- `base/` — cluster-agnostic. Selects nodes by **label**, never by hostname.
- `overlays/<cluster>/` — the values that differ per cluster: disk sizes, IP
  ranges, resource requests.

`node-labels/` is the deliberate exception: it has no base, only
`overlays/hub/`, because mapping labels onto named machines cannot be made
cluster-agnostic. It is also the only component that manages objects ArgoCD did
not create, so every Node in it carries
`argocd.argoproj.io/sync-options: Prune=false,Delete=false`.

## Using upstream content

Point at it as a remote base rather than aiming an Application at another repo:

```yaml
# manifests/olm/something/base/kustomization.yaml
resources:
  - https://github.com/redhat-cop/gitops-catalog/something/operator/overlays/stable?ref=main
```

This keeps every Application sourced from this repo, so the upstream reference
is versioned and reviewable here instead of hidden in an Application spec.

## Adding a component

1. `manifests/olm/<name>/base/` — namespace, operatorgroup, subscription.
2. `manifests/config/<name>/base/` — the CRs.
3. `manifests/config/<name>/overlays/<cluster>/` — only if values differ.
4. Add an element to the relevant ApplicationSet in `clusters/<cluster>/`.
5. `oc kustomize <dir>` to confirm it builds before committing.

## Current state

| Component | OLM | Config | Notes |
|---|---|---|---|
| nmstate | ✅ | ✅ | `br-vmdata` OVS bridge on `ens224`, with an OVN localnet mapping for `physnet-vmdata` |
| metallb | ✅ | ✅ | Address pool written but commented out — IP range unverified |
| local-storage | ✅ | ✅ | Bounded to the 1TiB `sdb` on each store node |
| odf | ✅ | ✅ | 3 × 1TiB OSDs, `flexibleScaling`; sets the cluster and virt default StorageClasses — see [its README](config/odf/README.md) |
| virtualization | ✅ | ✅ | Workloads pinned to `node-role.kubernetes.io/virtualization` |
| external-secrets | ✅ | ✅ | `onepasswordSDK` provider against the `eso` vault. The service-account token secret is a deliberate manual step — see [its README](config/external-secrets/README.md) |
| cert-manager | ✅ | ✅ | Private CA `homelab-ca` ClusterIssuer; wildcard cert wired into the default router — see [its README](config/cert-manager/README.md) |
| cloudnative-pg | ✅ | — | Postgres operator, AllNamespaces so it can manage the Cluster in `keycloak` |
| keycloak | ✅ | ✅ | RHBK + CloudNativePG database, passthrough TLS from `homelab-ca` — see [its README](config/keycloak/README.md) |
