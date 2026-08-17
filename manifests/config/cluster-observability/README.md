# cluster-observability

The Cluster Observability Operator, plus the **Dashboards** console plugin.

Upstream is [rhobs/observability-operator](https://github.com/rhobs/observability-operator),
which is worth knowing: its CRDs live under `monitoring.rhobs` and
`observability.openshift.io`, not the `monitoring.coreos.com` group the built-in
stack uses.

| | |
|---|---|
| package | `cluster-observability-operator` |
| catalog | `redhat-operators` |
| channel | `stable` (also available: `fast`) |
| CSV | `cluster-observability-operator.v1.5.1` |
| install mode | AllNamespaces → `spec: {}` |
| namespace | `openshift-cluster-observability-operator` |

## It does not collide with cluster monitoring

The CSV declares ownership of `ServiceMonitor`, `PodMonitor`, `Prometheus`,
`Alertmanager`, `PrometheusRule` and friends, which reads like a conflict with
the built-in monitoring stack. It is not. Checked on the cluster:

| CRD | owner |
|---|---|
| `servicemonitors.monitoring.coreos.com` | `cluster-version-operator`, `part-of=openshift-monitoring` |
| `prometheuses.monitoring.coreos.com` | same |
| `uiplugins.observability.openshift.io` | `olm.managed=true`, this operator |
| `monitoringstacks.monitoring.rhobs` | `olm.managed=true`, this operator |

COO declares those kinds but does not own the installed CRDs — the CVO does — and
its own CRDs sit under different API groups. The two coexist.

## The UIPlugin name is not a choice

```yaml
kind: UIPlugin
metadata:
  name: dashboards      # <- required
spec:
  type: Dashboards
```

The API server rejects anything else:

```
The UIPlugin "test-arbitrary-name" is invalid: <nil>: Invalid value:
UIPlugin name must be 'dashboards' if type is Dashboards
```

Verified with a server-side dry-run. Each `UIPlugin` type has its own required
name, so renaming one to match a local convention fails outright.

Two more things about it:

- **`UIPlugin` is cluster-scoped**, so no namespace is set and the Application's
  destination namespace is irrelevant to where it lands.
- **`Dashboards` takes no config block.** `spec` offers optional sub-objects for
  `distributedTracing`, `logging`, `monitoring` and `troubleshootingPanel` — none
  apply here. `type` is the only required field.

Valid types are `Dashboards`, `TroubleshootingPanel`, `DistributedTracing`,
`Logging`, `Monitoring`.

## Installing this by console leaves something git cannot reproduce

The web console creates the OperatorGroup with `generateName`, producing a name
like `openshift-cluster-observability-operator-skb2n`. A random suffix cannot be
committed.

That matters when adopting a hand-installed instance rather than starting clean.
A namespace may hold **exactly one** OperatorGroup, and a second makes OLM refuse
to resolve anything in that namespace at all. So adoption means **deleting** the
console's OperatorGroup and letting the one here replace it — not adding this one
alongside it.

This component was built after a clean uninstall, so it does not carry that
problem. The note exists for whoever hits it on another cluster.

## Verifying

Judge the operator by its CSV, not by ArgoCD — the CSV is created by OLM and is
not part of the Application:

```bash
oc get csv -n openshift-cluster-observability-operator
```

`hub-cfg-cluster-observability` will fail its first attempts with `no matches for
kind "UIPlugin"` until the CSV registers the CRD. That is the usual retry
convergence, not a fault, and is why the CR carries
`SkipDryRunOnMissingResource=true`.

```bash
oc get uiplugin dashboards
```

Then confirm the console picked it up:

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
```

The console redeploys when that list changes, so expect a brief reload rather
than an outage.

## Deliberately not deployed

Installing the operator costs nothing on its own; the CRs are what consume
resources. A `MonitoringStack`, `ThanosQuerier`, or Perses dashboards and
datasources are separate decisions — and the sizing lesson from
[rhacm-observability](../rhacm-observability) applies to `MonitoringStack` too:
an unset field means the CRD's opinion, not no opinion.
