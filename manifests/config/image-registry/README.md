# image-registry

The internal OpenShift registry, enabled and backed by CephFS.

## It is off by default, and that does not look like a problem

Bare-metal installs ship `managementState: Removed`. The operator then reports:

```
Available=True   "The registry is removed"
Degraded=False   "The registry is removed"
```

So nothing appears wrong — there simply is no registry. `managementState:
Managed` is the switch that creates the deployment.

## CephFS, not the default StorageClass

The registry runs more than one replica and every replica mounts the same
volume, so it needs **ReadWriteMany**.

| | access modes |
|---|---|
| `ocs-storagecluster-ceph-rbd` (cluster default) | ReadWriteOnce |
| `ocs-storagecluster-cephfs` | **ReadWriteMany** |

Relying on the default would give an RWO volume, the first replica would take it,
and the second would sit `Pending` forever. Naming the class explicitly is the
same lesson as [Search's `dbStorage`](../rhacm#search-database-persistence): an
unset field means the cluster's opinion, not no opinion.

Two settings depend on that RWX volume and would be wrong without it:

- `replicas: 2`
- `rolloutStrategy: RollingUpdate` — both the old and new pod mount the volume
  during a rollout. On RWO this must be `Recreate`.

CephFS allows expansion in place (`allowVolumeExpansion: true`), so 100Gi is a
starting point rather than a commitment. It does not shrink.

## `storage.managementState: Unmanaged` protects the volume

From the CRD's own description of the field:

> managementState indicates if the operator manages the underlying storage unit.
> If Managed the operator will remove the storage when this operator gets
> Removed.

So with the default `Managed`, setting the registry back to `Removed` — the state
it shipped in — would take the PVC and every image with it. `Unmanaged` means the
operator uses the volume but does not own its lifecycle. Git owns the PVC
instead, which is where it belongs.

## Server-side apply is disabled for the Config

`cluster-image-registry-operator` owns essentially the whole spec —
`managementState`, `replicas`, `rolloutStrategy`, `storage` — through `Update`
operations that wrote the install-time defaults. A server-side apply fails:

```
conflicts with "cluster-image-registry-operator":
  .spec.managementState
  .spec.replicas
```

ArgoCD's `Force=true` is **not** the server-side `--force-conflicts` flag, so it
does not resolve this. The fix is client-side apply, which merges only the
declared fields — the same precedent as `proxy/cluster` in
[cert-manager](../cert-manager). The config layer sets `ServerSideApply=true` for
every component, so this resource opts out individually.

> **`oc get -o json` hides `managedFields`** unless `--show-managed-fields` is
> passed. Checking ownership without that flag returns an empty list and reads as
> "nothing owns this" — which is how this conflict was nearly shipped. If you are
> about to declare a field on an operator-managed object, check with the flag.

## The external route

`defaultRoute: true` publishes the registry at
`default-route-openshift-image-registry.apps.hub.lab.bewley.net`. That is on
`apps.hub.lab.bewley.net` and therefore covered by the `apps-wildcard-tls`
certificate issued from the homelab CA, so anyone trusting that CA can

```bash
podman login -u $(oc whoami) -p $(oc whoami -t) \
  default-route-openshift-image-registry.apps.hub.lab.bewley.net
```

without `--tls-verify=false`.

It is enabled because images built on a workstation have to get in somehow — the
immediate case being MTV's VDDK image, which is built from VMware's licensed
tarball and must live somewhere the cluster can pull from.

## Verifying

```bash
oc get co image-registry
```

```bash
oc get pods -n openshift-image-registry -l docker-registry=default
```

Two Running replicas is the signal that RWX is genuinely working. One Running and
one `Pending` means the volume came from an RWO class.

```bash
oc get pvc -n openshift-image-registry
```
