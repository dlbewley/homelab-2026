# odf

Deploys the `StorageCluster` that turns the local disks claimed by
[local-storage](../local-storage) into Ceph OSDs, and designates which of the
resulting StorageClasses are default.

## Storage layout on hub

`store-1`, `store-2` and `store-3` each contribute one 1TiB non-rotational disk.
The LocalVolumeSet publishes them under the `local-block` StorageClass, and the
StorageCluster consumes them as a single device set of 3 replicas
(`flexibleScaling`, so the failure domain is host).

ODF then creates several StorageClasses of its own:

| StorageClass | Use |
|---|---|
| `ocs-storagecluster-ceph-rbd` | RWO block/filesystem — **cluster default** |
| `ocs-storagecluster-ceph-rbd-virtualization` | VM disks — **virt default** |
| `ocs-storagecluster-cephfs` | RWX filesystem |
| `ocs-storagecluster-ceph-rgw`, `openshift-storage.noobaa.io` | object storage |

## Default StorageClasses

Two independent annotations, on two different classes:

| Annotation | Set on |
|---|---|
| `storageclass.kubernetes.io/is-default-class` | `ocs-storagecluster-ceph-rbd` |
| `storageclass.kubevirt.io/is-default-virt-class` | `ocs-storagecluster-ceph-rbd-virtualization` |

General workloads land on `ceph-rbd`; VM disks land on the `-virtualization`
class, which ODF tunes for RWX block and live migration.

See [Configuring default and virt default storage class][docs] for what
OpenShift Virtualization does with the virt annotation.

[docs]: https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/virtualization/storage#virt-configuring-default-and-virt-default-storage-class_virt-automatic-bootsource-updates

### How, and why not a Job

The StorageClasses are created and owned by ODF, not by this repo, so they
cannot simply be declared. `overlays/hub/storageclass-defaults.yaml` instead
declares **only the annotation**, and server-side apply merges it into the
operator's object:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ocs-storagecluster-ceph-rbd
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
```

No `provisioner` is needed even though the field is required — SSA validates the
merged result, and ODF has already supplied it. ODF's own annotations
(`description`, `reclaimspace.csiaddons.openshift.io/schedule`) are untouched,
because `ocs-client-operator` manages the object with `Update` while ArgoCD owns
just this one field.

A Job running `oc annotate` would also work, but it is imperative: it runs once,
does not correct drift, and needs a ServiceAccount plus RBAC to patch
StorageClasses. The declarative form is self-healing and needs none of that.

**`Prune=false,Delete=false` on these objects is load-bearing.** Without it
ArgoCD treats the StorageClasses as resources it owns, and deleting this file —
or an errant prune — would delete ODF's StorageClasses and orphan every PV bound
to them. Same reasoning as the Node objects in
[node-labels](../node-labels).

### Ordering

Sync wave 20 puts these after the StorageCluster (wave 0). Until ODF has
actually created the classes the apply fails with:

```
The StorageClass "ocs-storagecluster-ceph-rbd" is invalid: provisioner: Required value
```

Retry/backoff converges once they exist. This differs from the NNCP in
[nmstate](../nmstate): there the *kind* was missing and
`SkipDryRunOnMissingResource` was required. Here the kind exists and only the
*object* is absent, so that option would do nothing.

## Validation

```bash
oc get sc -o json | jq '.items[].metadata|select(.annotations."storageclass.kubernetes.io/is-default-class"=="true")|.name'
```

```bash
oc get sc -o json | jq '.items[].metadata|select(.annotations."storageclass.kubevirt.io/is-default-virt-class"=="true")|.name'
```

Each should return exactly one name. Two defaults for the same key is undefined
behaviour — if you move the default, explicitly set `"false"` on the old class
rather than deleting the annotation, so the change is visible in git.

`oc get sc` also marks the cluster default with `(default)` beside the name,
which is the quickest way to spot the annotation being stripped.

## Schema drift

Fields under `spec.managedResources` must exist in the CRD schema for the
installed ODF version. Server-side apply rejects unknown fields outright rather
than ignoring them (`field not declared in schema`), which is how
`cephConfig` — valid in older releases, gone in 4.22 — surfaced. Check before
adding one:

```bash
oc get crd storageclusters.ocs.openshift.io -o json | jq -r '.spec.versions[]|select(.name=="v1").schema.openAPIV3Schema.properties.spec.properties.managedResources.properties|keys[]'
```
