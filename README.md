# homelab-2026

Build and configure the Bewley homelab OpenShift clusters.

| Stage | Where | How |
|---|---|---|
| Day 0 — build the cluster | [scripts/](scripts/) | shell + `govc` against vSphere |
| Day 1 — install GitOps | [bootstrap/](bootstrap/) | `oc apply -k bootstrap/` |
| Day 2 — configure the cluster | [clusters/](clusters/), [manifests/](manifests/) | ArgoCD |

## Layout

```
bootstrap/              Day 1. The only thing applied by hand. GitOps operator + RBAC.
clusters/<name>/        What one cluster is. AppProject, root Application, and the
                        two ApplicationSets naming which components it gets.
manifests/              Reusable building blocks. Plain Kustomizations, not
                        Kustomize Components — see components/ for that.
  olm/<name>/base/      Install an operator: Namespace + OperatorGroup + Subscription.
  config/<name>/
    base/               The operator's CRs, with nothing cluster-specific in them.
    overlays/<cluster>/ Per-cluster values, patched onto the base.
components/             Reserved for genuine Kustomize Components. Empty today.
scripts/                Day 0 VM provisioning, plus repo and cluster validation.
```

Two rules keep this multi-cluster:

1. **Nothing under `manifests/*/base/` names a cluster or a machine.** Anything
   that varies goes in `overlays/<cluster>/`. Node selection is by label, never
   by hostname — the one exception is `manifests/config/node-labels/`, which
   exists only as an overlay because assigning labels to machines is inherently
   cluster-specific.
2. **Applications only ever point at this repo.** To use upstream content such
   as `redhat-cop/gitops-catalog`, reference it as a remote base from inside a
   component's `kustomization.yaml`. That keeps the repo URL in three files
   instead of one per component.

Adding a second cluster is therefore `cp -r clusters/hub clusters/foo`, editing
the element lists, and adding `overlays/foo/` wherever values differ.

## Bringing up a cluster

```bash
oc apply -k bootstrap/
```

Wait for the GitOps operator to finish, then hand the cluster over to ArgoCD:

```bash
oc apply -k clusters/hub
```

That is the last manual step. `hub-root` watches `clusters/hub/`, so every later
change — including changes to the ApplicationSets themselves — arrives via git.

## Conventions

- **Sync waves** order resources *within* an Application (Namespace 0,
  OperatorGroup 1, Subscription 2). They do **not** order the Applications that
  ApplicationSets generate; see [clusters/hub/config.yaml](clusters/hub/config.yaml)
  for why, and why retry/backoff is used instead.
- **Server-side apply** is on for the config layer. Operators own large parts of
  CRs like `HyperConverged` and `StorageCluster`; SSA lets ArgoCD own only the
  fields git declares.
- **Operator channels** are pinned, not floating. Re-check them after an
  OpenShift upgrade with `scripts/verify-channels.sh`.

## Issue tracking

This repo uses [beads](https://github.com/gastownhall/beads). `bd ready` for
available work; the GitOps buildout is epic `homelab-2026-4pq`.
