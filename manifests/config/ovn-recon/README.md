# ovn-recon

Open Virtual Network Reconnaissance — an OpenShift Console plugin that
visualises virtual and node network state, making OVN-Kubernetes topology
legible instead of something you reconstruct from `oc debug` output.

Upstream: <https://github.com/dlbewley/ovn-recon>

It maps physical node networking (interfaces, bridges, OVN bridge mappings),
the connections between network resources (VRFs, secondary networks,
attachments), and LLDP neighbours.

## Pieces

| Component | Default | Purpose |
|---|---|---|
| Console plugin | **enabled** | the topology UI, served into the OpenShift Console |
| Collector | **disabled** | backend enabling the *logical* OVN topology view |

The collector is **off in `base/` because it is still experimental**, and opted
into per cluster. `overlays/hub` enables it. Any cluster that should not run it
simply omits the patch.

It probes `openshift-ovn-kubernetes` and `openshift-frr-k8s`, which is why the
OperatorGroup in [`manifests/olm/ovn-recon`](../../olm/ovn-recon) is
AllNamespaces: the operator has to act outside its own namespace. An
OwnNamespace install would resolve cleanly and then quietly do nothing.

## Where the operator comes from

Not from `redhat-operators`. It ships in a self-published catalog registered by
[`manifests/olm/bewley-catalog`](../../olm/bewley-catalog), which is a separate
component because a catalog can serve several packages and should not be pruned
along with any one of them.

Consequence: `hub-olm-ovn-recon` cannot resolve until that catalog is
registered and serving. They are separate Applications, so ordering is by
ArgoCD retry — expect brief resolution failures on a first sync.

## Verifying

```bash
oc get csv -n ovn-recon
```

ArgoCD reports the Application Healthy once the Subscription exists, which is
not the same as the operator having installed — check the CSV.

```bash
oc get ovnrecon -n ovn-recon
```

Then look for **Networking → OVN Recon** in the Console. A plugin that fails to
load usually shows up in the console operator rather than here:

```bash
oc get consoleplugin
oc get console.operator cluster -o jsonpath='{.spec.plugins}{"\n"}'
```

## Known gaps

- The `CatalogSource` tracks a floating `:latest` tag polled hourly, so catalog
  contents can change with no commit. A digest is recorded in that manifest if
  you would rather pin.
- The image fields in `base/ovn-recon.yaml` give a repository with no tag or
  digest. Whether the CRD supplies a default has not been verified against the
  cluster.
