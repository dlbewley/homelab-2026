# workload-availability

Node Health Check plus Self Node Remediation — the first step toward VM high
availability. Detect a virtualization node that has stopped being healthy,
remediate it, and let its VMs restart elsewhere.

## Node Health Check does nothing on its own

`NodeHealthCheck` detects unhealthy nodes but cannot act. Its spec requires a
`remediationTemplate` pointing at a provider, so installing it alone gives you a
CR that watches forever and never remediates. Self Node Remediation is that
provider here.

| | version | owns |
|---|---|---|
| `node-healthcheck-operator` | 0.12.1 | `NodeHealthCheck` |
| `self-node-remediation` | 0.13.1 | `SelfNodeRemediation`, `SelfNodeRemediationConfig`, `SelfNodeRemediationTemplate` |

Both come from `redhat-operators` on the `stable` channel — the only channel
either publishes.

## Two operators, one OperatorGroup

This component is shaped differently from every other `olm/` component here, and
the deviation is forced rather than stylistic.

**A namespace may contain exactly one OperatorGroup.** A second makes OLM refuse
to resolve anything in that namespace at all. Both operators suggest the same
namespace — `openshift-workload-availability` — so they must share one
OperatorGroup, which means they must live in one component with two
Subscriptions.

Both are **AllNamespaces**, so the OperatorGroup is `spec: {}` — the opposite of
[rhacm](../rhacm) and [mtv](../mtv), which are OwnNamespace-only and must set
`targetNamespaces`.

> `scripts/verify-channels.sh` originally assumed one `subscription.yaml` per
> component and broke on this one — the first with two. It now finds
> `subscription*.yaml` and checks the OperatorGroup shape against **every**
> package in the directory, since one OperatorGroup has to satisfy all of them.

## The shipped sample points at the wrong namespace

`NodeHealthCheck`'s own `alm-examples` references:

```yaml
remediationTemplate:
  namespace: openshift-operators
```

SNR creates its default templates in **its own** namespace, which here is
`openshift-workload-availability`. Copying the sample verbatim produces a
NodeHealthCheck referencing a template that does not exist — and the failure mode
is silence. The CR is accepted, reports no error, and simply never remediates.

**Verify the template name after SNR installs** rather than trusting the one
written here:

```bash
oc get selfnoderemediationtemplate -n openshift-workload-availability
```

## Why these thresholds

```yaml
minHealthy: "51%"
unhealthyConditions:
  - {type: Ready, status: "False",   duration: 300s}
  - {type: Ready, status: Unknown,   duration: 300s}
```

**`minHealthy: 51%`** against four virtualization nodes means at least three must
be healthy before any remediation proceeds — one node at a time, and nothing at
all if two fail together. That is the safety valve: a network partition making
several nodes look unhealthy must not trigger mass reboots.

**`300s`** because a node briefly `NotReady` during a kubelet restart or a
network blip must not be rebooted. Only a sustained failure should be.

`status: Unknown` is covered as well as `False` — a node that stops reporting
altogether is the more common real failure, and it presents as Unknown.

## Only the VM hosts are watched

The selector is the `virtualization` role, so the four `cnv` nodes are covered
and the `store` nodes deliberately are not: remediating one reboots an ODF OSD
host, a much larger event than rebooting a VM host.

Selecting by role label rather than hostname is what keeps this cluster-agnostic
and therefore in `base/`, per the convention in [manifests](../../README.md).

## There is no hardware watchdog on these nodes

Checked on `cnv-1`, 2026-08-17: `/dev/watchdog` does not exist.

SNR uses a watchdog device when present and falls back to a **software reboot**
otherwise. That is a weaker guarantee that a sick node has actually stopped
writing — which matters here, because VMs restart on shared ODF storage and two
hosts believing they own the same disk is the failure worth avoiding.

Fence Agents Remediation with `fence_vmware_rest` against vCenter would be true
out-of-band power fencing, and the vCenter credentials already exist in 1Password
from the MTV and ACM work. SNR was chosen first deliberately, to watch the
simpler mechanism behave before adding fencing credentials and per-node
configuration.

## Verifying

Judge the operators by their CSVs, not by ArgoCD — the CSV is created by OLM and
is not part of the Application:

```bash
oc get csv -n openshift-workload-availability
```

```bash
oc get nodehealthcheck virtualization-nodes -o yaml
```

The status reports how many nodes the selector matched. **Four** is the expected
answer here; zero means the role label is missing and the CR is watching nothing
while looking perfectly healthy.

```bash
oc get selfnoderemediationtemplate -n openshift-workload-availability
```

## Remediating the node may not be sufficient

Rebooting an unhealthy node is necessary for VMs to restart elsewhere, but
whether they actually do depends on the VMs' own `runStrategy` and eviction
behaviour. That is deliberately out of scope here and worth testing before
treating VM HA as solved.
