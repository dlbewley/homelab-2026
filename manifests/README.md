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
| `operatorgroup.yaml` | 1 | Install mode — see below |
| `subscription.yaml` | 2 | Channel pinned, `installPlanApproval: Automatic` |

`bewley-catalog` is the exception: it registers a `CatalogSource` and has none
of the three.

### OperatorGroup shape

`targetNamespaces` requests OwnNamespace (or SingleNamespace, if it targets a
namespace other than its own); an empty `spec: {}` requests AllNamespaces. Ask
for a mode the operator does not support and resolution fails with a message
that names the mode but not the fix.

AllNamespaces appears here for **two different reasons**, worth keeping
straight:

| Component | Shape | Why |
|---|---|---|
| `metallb`, `external-secrets` | `spec: {}` | AllNamespaces is the **only** mode the operator supports |
| `cloudnative-pg` | `spec: {}` | **chosen** — must manage the Postgres `Cluster` in the `keycloak` namespace |
| `ovn-recon` | `spec: {}` | **chosen** — the collector probes `openshift-ovn-kubernetes` and `openshift-frr-k8s` |
| everything else | `targetNamespaces` | own namespace is sufficient |

The chosen ones would resolve perfectly well as OwnNamespace and then quietly
fail to do their job, which is the harder failure to diagnose.

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
| node-labels | — | ✅ | Config-only, and `overlays/hub` only — mapping labels onto named machines cannot be cluster-agnostic. Manages pre-existing Nodes, so every one carries `Prune=false,Delete=false` |
| nmstate | ✅ | ✅ | `br-vmdata` OVS bridge on `ens224`, with an OVN localnet mapping for `physnet-vmdata` |
| metallb | ✅ | ✅ | Address pool written but commented out — IP range unverified |
| local-storage | ✅ | ✅ | Bounded to the 1TiB `sdb` on each store node |
| odf | ✅ | ✅ | 3 × 1TiB OSDs, `flexibleScaling`; sets the cluster and virt default StorageClasses — see [its README](config/odf/README.md) |
| virtualization | ✅ | ✅ | Workloads pinned to `node-role.kubernetes.io/virtualization` |
| external-secrets | ✅ | ✅ | `onepasswordSDK` provider against the `eso` vault. The service-account token secret is a deliberate manual step — see [its README](config/external-secrets/README.md) |
| cert-manager | ✅ | ✅ | Private CA `homelab-ca`; wildcard cert on the router; trust-manager (**Technology Preview**) distributes the CA to `openshift-config` and the cluster trust bundle — see [its README](config/cert-manager/README.md) |
| cloudnative-pg | ✅ | ✅ | Postgres operator, AllNamespaces so it can manage the Cluster in `keycloak`. Config is only the `cnpg-pull-secret` its own Deployment references — the Postgres `Cluster` belongs to keycloak |
| keycloak | ✅ | ✅ | RHBK + CloudNativePG database, passthrough TLS from `homelab-ca`, and the `homelab` realm with the `ocp-hub` OIDC client — see [its README](config/keycloak/README.md) |
| oauth | — | ✅ | Keycloak (`claim`) and GitHub (`add`, org `dwnwrd`) identity providers; group membership stays static in `bootstrap/rbac.yaml` — see [its README](config/oauth/README.md) |
| bewley-catalog | ✅ | — | `CatalogSource` for self-published operators. Not an operator install — no namespace, OperatorGroup or Subscription |
| ovn-recon | ✅ | ✅ | OVN topology Console plugin, from `bewley-catalog`. Collector disabled in base, enabled on hub — see [its README](config/ovn-recon/README.md) |
| rhacm | ✅ | ✅ | Operator + `MultiClusterHub`, plus 10Gi persistent storage for the Search database. **OwnNamespace-only**. Credentials are a separate issue — see [its README](config/rhacm/README.md) |
| rhacm-observability | — | ✅ | Config-only. `MultiClusterObservability` on a Thanos bucket provisioned by an ObjectBucketClaim on ODF's RGW; `thanos.yaml` composed by an ExternalSecret rather than the catalog's setup Job. Every storage size set explicitly — the CRD defaults total 212Gi — see [its README](config/rhacm-observability/README.md) |
| mtv | ✅ | ✅ | Migration Toolkit for Virtualization + `ForkliftController`. **OwnNamespace-only**, like rhacm. Source providers are a separate issue — see [its README](config/mtv/README.md) |
