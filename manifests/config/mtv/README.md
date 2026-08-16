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
