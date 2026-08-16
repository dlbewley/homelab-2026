# mtv

Migration Toolkit for Virtualization — migrates VMs from VMware onto OpenShift
Virtualization. This component installs the operator and brings up
`ForkliftController`. Source providers are separate.

## Scope, and what is not here

| | Issue |
|---|---|
| operator + `ForkliftController` | this component |
| vSphere source `Provider` and its credentials | `homelab-2026-4pq.30` |

Splitting them means MTV is usable — and its console plugin visible — before any
decision about which vCenter to trust it with.

## The install mode is the thing to get right

```
installModes: OwnNamespace
```

Not SingleNamespace, not AllNamespaces. Along with [rhacm](../rhacm), this is one
of the two most restrictive operators in the repo, so the OperatorGroup must set
`targetNamespaces`. An empty `spec: {}` would request AllNamespaces and fail
resolution exactly the way metallb did — with a message naming the mode but not
the fix.

```bash
scripts/verify-channels.sh
```

checks that against the pinned channel, along with the channel itself.

There is no operator/operand namespace split: the operator and
`ForkliftController` both live in `openshift-mtv`, which is the namespace the
package itself suggests.

## Values came from the cluster, not the docs

`docs.redhat.com` returns HTTP 403 to automated fetches, so every value here was
read from the catalog on the cluster rather than transcribed. That is the better
source anyway — it describes the version you will actually install.

```bash
oc get packagemanifest mtv-operator -n openshift-marketplace -o json | jq -r \
  '.status.defaultChannel as $d | .status.channels[]|select(.name==$d)
   | "\(.currentCSV)  modes=\(.currentCSVDesc.installModes|map(select(.supported))|map(.type)|join(","))"'
```

| | |
|---|---|
| package | `mtv-operator` |
| catalog | `redhat-operators` |
| channel | `release-v2.12` (also available: `release-v2.11`) |
| CSV | `mtv-operator.v2.12.5` |
| namespace | `openshift-mtv` |

## `feature_*` values are strings

```yaml
spec:
  feature_ui_plugin: "true"
  feature_validation: "true"
  feature_volume_populator: "true"
```

The quotes are not stylistic. That is how the shipped `alm-examples` has them and
how the CRD takes them; unquoted `true` is a different type.

| | |
|---|---|
| `feature_ui_plugin` | the console plugin, which is how migrations are driven day to day |
| `feature_validation` | pre-migration checks that flag VMs needing attention before a plan runs |
| `feature_volume_populator` | populator-based disk transfer rather than the older CDI path |

## Judge it by the CSV, not by ArgoCD

`hub-olm-mtv` reporting Synced/Healthy only means the Subscription exists. The
CSV is created by OLM and is not part of the Application, so the app can be green
while the operator sits in `Failed`:

```bash
oc get csv -n openshift-mtv
```

`hub-cfg-mtv` will also fail its first attempts with `no matches for kind
"ForkliftController"` until the CSV registers the CRD. The operator is a separate
Application, so ordering is by retry rather than sync wave — the same arrangement
as [rhacm](../rhacm). That is why the CR carries
`SkipDryRunOnMissingResource=true`.

```bash
oc get forkliftcontroller -n openshift-mtv
```

## Migrations run outside this namespace

A migration does not run in `openshift-mtv` — it runs in the **target** namespace
where the VMs are landing, which for real work is a customer or tenant namespace.
Those pods still pull images out of `openshift-mtv`, most importantly the VDDK
image.

`allow-image-pullers` is what permits that. Without it, migrations fail on image
pull rather than on anything naming permissions, so it reads as a registry or
networking fault.

The namespace already ships a `system:image-pullers` binding, but its only
subject is `system:serviceaccounts:openshift-mtv` — service accounts *inside*
this namespace. Pods in a target namespace are not in that group, so the two
bindings are additive rather than redundant.

What it grants is narrower than the name suggests:

```
system:image-puller  ->  get on imagestreams/layers
```

Read-only, and only for imagestreams in this namespace. No push, no delete, no
other resource.

> The subject is `system:authenticated` — every authenticated user and service
> account on the cluster. That breadth is deliberate: the alternative is naming
> each target namespace's service accounts and editing this binding per
> migration. Note the VDDK image is built from VMware's licensed distribution, so
> this makes it pullable in-cluster by anyone already authenticated here. It
> changes nothing about external exposure.

## The vSphere source provider

`overlays/hub` adds the lab vCenter as a migration source: a `Provider` plus the
`ExternalSecret` that feeds it.

### MTV's key names differ from ACM's

| MTV key | 1Password `vcenter/...` |
|---|---|
| `user` | `username` — **note the rename** |
| `password` | `password` |
| `cacert` | `cacertificate` |

The [ACM credential](../rhacm) holds the same values under `username`. The two
Secrets are **not** interchangeable; ESO does the renaming, which is why both can
share one 1Password item.

### No thumbprint, deliberately

MTV also accepts `thumbprint` — the SHA-1 of the certificate vCenter serves — but
it is **not required** when a valid CA is supplied and `insecureSkipVerify` is
false. Verified on hub 2026-08-16 with a throwaway Provider carrying no
thumbprint:

```
ConnectionTestSucceeded=True   Connection test, succeeded.
InventoryCreated=True          The inventory has been loaded.
```

This matters because a thumbprint pins the **leaf** certificate:

| | expires |
|---|---|
| leaf (what a thumbprint pins) | 2028-05-11 |
| CA (what `cacert` trusts) | 2036-05-06 |

Pinning the leaf would plant a migration-breaking expiry two years earlier than
necessary, for no security gain over verifying against the CA.

`insecureSkipVerify` is explicitly `"false"` rather than omitted — the
certificate is ignored entirely when it is true, which would silently make
`cacert` decorative.

### Judge the Provider by its conditions

A Provider with bad credentials, a wrong URL or an untrusted certificate is still
a valid object, so `hub-cfg-mtv` reports Synced either way.

```bash
oc get provider vsphere-lab -n openshift-mtv \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

`ConnectionTestSucceeded` and `InventoryCreated` are the ones that mean it works.
A TLS/certificate error rather than an authentication error is the tell that the
CA is wrong rather than the credentials.

> `url` must be the **SDK** endpoint (`/sdk`), not the UI you log into. Pointing
> it at the bare hostname produces a Provider that exists and never connects.
> `spec.type` has no enum in the CRD, so a typo there is accepted by the API
> server and only surfaces as a Provider that will not connect.

## Prerequisite already met

MTV migrates *onto* OpenShift Virtualization, which this cluster already runs —
see [virtualization](../virtualization). Nothing additional is required.

## Verifying

```bash
oc get csv -n openshift-mtv
```

```bash
oc get pods -n openshift-mtv
```

The console plugin appears under Migration once `ForkliftController` reconciles.
If the operator installed but the plugin never shows, check that
`feature_ui_plugin` is the string `"true"` rather than a boolean.
