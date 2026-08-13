# rhacm-observability

Thanos-backed metrics across managed clusters, via `MultiClusterObservability`.

Split out of [rhacm](../rhacm) so the hub is usable without paying for
observability storage, and so the two expensive decisions — how much disk, and
which object store — are made on their own merits rather than bundled into
"install ACM".

## Why this is a separate Application

It owns a different namespace, its CRD only appears after `MultiClusterHub`
reports Running, and it is the optional half of ACM. Separate also means its
retry loop cannot hold up `MultiClusterHub`'s.

## Sizes are set explicitly, and that is the point

The CRD carries defaults:

| Field | CRD default |
|---|---|
| `compactStorageSize` | 100Gi |
| `receiveStorageSize` | 100Gi |
| `storeStorageSize` | 10Gi |
| `ruleStorageSize` | 1Gi |
| `alertmanagerStorageSize` | 1Gi |
| | **212Gi** |

So omitting `storageConfig` does not get you small PVCs — it gets you 212Gi. And
those are **per-replica**, so the real figure is higher. Measured on hub
2026-08-13, Ceph offers roughly 1024GiB usable, so the defaults would claim a
fifth of the cluster to observe a hub that currently observes only itself.

This is the same trap as [Search's `dbStorage`](../rhacm#search-database-persistence):
a field left unset does not mean "no opinion", it means "the CRD's opinion".

What is set here instead, sized for a hub watching one or two clusters:

| Field | Here | Why |
|---|---|---|
| `compactStorageSize` | 50Gi | scales with retention, not cluster count |
| `receiveStorageSize` | 20Gi | scales with ingest, not cluster count |
| `storeStorageSize` | 10Gi | already small at its default |
| `ruleStorageSize` | 1Gi | already small |
| `alertmanagerStorageSize` | 1Gi | already small |
| `instanceSize: minimal` | | cuts replica counts, compounding with the above |
| `storageClass` | named | a silently changing default relocates data |

Revisit when `homelab-2026-4pq.9` adds a spoke and real consumption is visible.
That is a better moment to size than guessing now.

## The setup Job is deliberately not adopted

The [redhat-cop catalog](https://github.com/redhat-cop/gitops-catalog/tree/main/advanced-cluster-management)
ships `instance/observability/02-install-observability.yaml`: a `batch/v1` Job
running `ose-cli:latest`, which polls in a bash `while` loop for the OBC-generated
Secret and pipes interpolated YAML into `oc create -f -`.

Objections, in order:

1. **Not declarative.** It runs once. If the OBC is recreated and credentials
   rotate, nothing re-runs and the drift is invisible. Everything else in this
   repo reconciles continuously.
2. Jobs are immutable, so re-running needs deletion or ArgoCD hook plumbing.
3. It creates Secrets imperatively, so ArgoCD never manages or diffs them.
4. **RBAC far too broad** — a ClusterRole granting secrets `get/list/create/patch`
   at *cluster* scope to a helper ServiceAccount is effectively read-any-secret.
5. `ose-cli:latest` is a floating tag.

The replacement uses machinery already working here: an `ObjectBucketClaim`
provisions the bucket, and an `ExternalSecret` composes `thanos.yaml` from the
credentials the OBC generates. Continuous, ArgoCD-visible, no Job, and the RBAC
is a namespaced Role limited by `resourceNames` to one Secret.

## Why `bucketName` is pinned

The OBC publishes its bucket name in the generated **ConfigMap**, never in the
generated Secret. ESO's kubernetes provider reads Secrets only — its provider
schema is `auth`/`authRef`/`remoteNamespace`/`server`, with no resource selector.
A generated name would therefore be unreadable by the ExternalSecret that builds
`thanos.yaml`.

Pinning it makes the name a constant that both git and the ExternalSecret rely
on. Verified with a throwaway OBC on 2026-08-13: a pinned `bucketName` on this
StorageClass reaches `Bound` and reports `BUCKET_NAME` unchanged.

## RGW rather than NooBaa

Both StorageClasses exist on this cluster. The OBC API is identical either way —
the StorageClass only decides which provisioner services the claim — so this is
purely about what sits in the data path. RGW keeps the NooBaa core and endpoint
pods out of it.

> The bucket sits on the **same Ceph cluster** as the PVCs holding the metrics it
> backs. One failure domain, not two. Worth stating rather than implying
> resilience that is not there.

## `insecure` does not mean what it looks like

The single most miscopyable field here. In Thanos:

- `insecure: true` → **speak plain HTTP instead of HTTPS**
- `http_config.tls_config.insecure_skip_verify: true` → skip certificate checks

They are different settings. The catalog sets `insecure: true`, so the catalog
talks **plaintext** to its S3 endpoint.

This cluster does better. Checked from inside the cluster on 2026-08-13, the RGW
service does serve TLS on `:443`:

```
subject=CN=rook-ceph-rgw-ocs-storagecluster-cephobjectstore.openshift-storage.svc
issuer=CN=openshift-service-serving-signer@1785106755
```

So `insecure: false` here and traffic is encrypted. Verification is skipped only
because that issuer is the service-serving CA, published as a ConfigMap, and ESO
cannot read ConfigMaps to turn it into the Secret a `ca_file` would need.

**To verify properly later:** put the service CA in a Secret, point
`storageConfig.metricObjectStorage.tlsSecretName` / `tlsSecretMountPath` at it,
set `http_config.tls_config.ca_file` to the mounted path, and drop
`insecure_skip_verify`.

## No pull secret

The catalog's Job also copies the cluster pull secret into
`multiclusterhub-operator-pull-secret`. Not needed here: `MultiClusterHub` on
this cluster runs with `imagePullSecret` unset, there is no pull secret in
`open-cluster-management`, and all 23 components deployed. The cluster-wide pull
secret already covers image pulls.

## Verifying

Check the chain in order — each link explains the next one's failure:

```bash
oc get obc -n open-cluster-management-observability
```

```bash
oc get secretstore,externalsecret -n open-cluster-management-observability
```

A `SecretStore` stuck not-Ready is usually RBAC: ESO validates a
kubernetes-provider store with a `SelfSubjectRulesReview`, and the failure
message does not mention RBAC.

```bash
oc get secret thanos-object-storage -n open-cluster-management-observability \
  -o jsonpath='{.data.thanos\.yaml}' | base64 -d
```

```bash
oc get mco observability
```

Then confirm the PVCs match the sizes above rather than the CRD defaults:

```bash
oc get pvc -n open-cluster-management-observability
```
