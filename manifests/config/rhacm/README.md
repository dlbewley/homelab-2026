# rhacm

Red Hat Advanced Cluster Management. This component installs the operator and
brings up `MultiClusterHub` — nothing more. Observability and cluster-lifecycle
credentials are deliberately separate.

## Scope, and what is not here

| | Issue |
|---|---|
| operator + `MultiClusterHub` | this component |
| observability (`MultiClusterObservability`) | `homelab-2026-4pq.24` |
| cloud provider / pull secret / SSH / OCM credentials | `homelab-2026-4pq.25` |

Splitting them means ACM is usable sooner, and the two expensive decisions —
storage for observability, and which credentials to trust the hub with — are
made on their own merits rather than bundled into "install ACM".

## The install mode is the thing to get right

```
installModes: OwnNamespace
```

Not SingleNamespace, not AllNamespaces. **This is the most restrictive operator
in the repo**, so the OperatorGroup must set `targetNamespaces`. An empty
`spec: {}` would request AllNamespaces and fail resolution exactly the way
metallb did — with a message naming the mode but not the fix.

```bash
scripts/verify-channels.sh
```

checks that against the pinned channel, along with the channel itself.

Unlike cert-manager or external-secrets there is no operator/operand namespace
split: the operator and `MultiClusterHub` both live in
`open-cluster-management`, which is the name the package itself suggests.

## `spec: {}` is deliberate

Both the CSV's own `alm-examples` and the
[redhat-cop gitops-catalog](https://github.com/redhat-cop/gitops-catalog/tree/main/advanced-cluster-management)
manifest ship an empty spec, and this follows them.

`MultiClusterHub` does expose levers worth knowing about — `availabilityConfig:
Basic` reduces replica counts, which suits a lab, and `overrides.components` can
disable individual pieces. None were verified against 2.17 here, and the CSV
ships no spec descriptors to check against, so defaults come first. Tune once it
is running and the cost is visible rather than guessing up front.

## Search database persistence

The Search service keeps its index in a PostgreSQL database. By default that
runs on ephemeral storage, so the index is lost on every pod restart and has to
be rebuilt from every managed cluster.

`search.yaml` gives it a 10Gi volume:

```yaml
spec:
  dbStorage:
    size: 10Gi
```

### Why only `dbStorage` is declared

The `Search` CR named `search-v2-operator` is created by ACM itself — it is not
ours to own. So this declares the one field we care about and lets server-side
apply merge it, the same partial-apply pattern as the
[StorageClass defaults](../odf), the `IngressController`, and `proxy/cluster`.

That also makes it correct either way: if ACM has already created the CR, SSA
merges `dbStorage` into it; if it has not, SSA creates it with just that field,
which the CRD permits since `spec.dbStorage` has no required properties.

`Prune=false,Delete=false` because deleting this file must never remove ACM's
`Search` CR and take the search service down with it.

### The storage class is omitted on purpose

That is permitted — from the CRD schema:

| Field | Type | Required | Default |
|---|---|---|---|
| `spec.dbStorage.size` | quantity | no | **`10Gi`** |
| `spec.dbStorage.storageClassName` | string | no | none |

With no class named, the PVC is created without one and Kubernetes uses the
**cluster default** — which [manifests/config/odf](../odf) sets to
`ocs-storagecluster-ceph-rbd`.

Naming the class here would hard-code an ODF-specific value into a base that is
otherwise cluster-agnostic, and would silently disagree with any cluster whose
default differs. The one thing to be aware of: a cluster with **no** default
StorageClass leaves the PVC `Pending` forever, and the search pod waits with it.

`size` is set explicitly even though `10Gi` is already the CRD default, so the
intent lives in git rather than being inherited from a schema that could change
between releases.

### Verifying

```bash
oc get pvc -n open-cluster-management
```

Look for the search database PVC `Bound` on `ocs-storagecluster-ceph-rbd`. A
`Pending` PVC means no default StorageClass, not an ACM problem.

## Expect it to be slow, and judge it by the right thing

One CR deploys a large number of components. `hub-cfg-rhacm` will also fail its
first attempts with `no matches for kind "MultiClusterHub"` until the CSV
registers the CRD — the operator is a separate Application, so ordering is by
retry rather than sync wave. That is the automated form of the old runbook's
"apply again until no errors".

Judge progress by the CR, not by ArgoCD:

```bash
oc get multiclusterhub -n open-cluster-management
```

```bash
oc get csv -n open-cluster-management
```

ArgoCD reporting `hub-olm-rhacm` Synced/Healthy only means the Subscription
exists — the CSV is created by OLM and is not part of the Application.

## Not adopted from the catalog

The catalog's `instance/base/subscription-admin.yaml` binds the
`open-cluster-management:subscription-admin` ClusterRole to `kube:admin` and
`system:admin`. It is not included here for two reasons:

1. It is only needed for ACM's Application/Subscription feature, not for
   standing up the hub.
2. Those subjects do not match this cluster's identity model. Admins log in
   through Keycloak or GitHub as `dlbewley`, so binding `kube:admin` would grant
   it to an account nobody uses day to day.

If that feature is adopted later, bind the `cluster-admins` **Group** instead —
consistent with [bootstrap/rbac.yaml](../../../bootstrap/rbac.yaml), and it
follows whoever is in the group rather than naming users.

## ACM has little to do until there is a spoke

Until `homelab-2026-4pq.9` adds a second cluster, the hub manages only itself
(`local-cluster`). Worth landing anyway — standing up the second cluster is
easier with ACM already present than retrofitting it afterwards.
