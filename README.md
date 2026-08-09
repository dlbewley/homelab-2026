# homelab-2026

Build and configure the Bewley homelab OpenShift clusters.

| Stage | Where | How |
|---|---|---|
| Day 0 — build the cluster | [scripts/](scripts/) | shell + `govc` against vSphere |
| Day 1 — install GitOps | [bootstrap/](bootstrap/) | `oc apply -k bootstrap/` |
| Day 2 — configure the cluster | [clusters/](clusters/), [manifests/](manifests/) | ArgoCD: `oc apply -k clusters/hub` |

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
docs/                   Cross-cutting notes, incl. troubleshooting.
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

Three steps, and the middle one is easy to miss. Everything in this repo that
holds a secret reads it from 1Password through External Secrets — including the
CA that signs the router certificate — so **nothing can be issued until the
1Password service-account token exists in the cluster.**

```bash
oc apply -k bootstrap/
```

Installs the GitOps operator and the cluster-admin RBAC. Wait for the operator
to finish, then hand the cluster to ArgoCD:

```bash
oc apply -k clusters/hub
```

Operators begin installing. Once External Secrets has created its operand
namespace, seed the one credential that cannot come from External Secrets
itself — it is the credential that unlocks every other credential:

```bash
oc get ns external-secrets   # wait for this to exist
```

```bash
oc create secret generic onepassword-connect-token \
  --namespace external-secrets \
  --from-file=token=/path/to/service-account-token
```

The value is the **1Password service-account token** — the credential issued when
the service account was created, scoped to the `eso` vault. It is not one of the
items listed below; those are what it is *used to read*. If you keep a copy in
1Password, substitute `--from-literal=token="$(op read 'op://…')"` with wherever
you filed it.

From here the cluster converges on its own. Until that secret exists it will sit
partly built rather than failing loudly: no CA, so no certificates; the router
keeps its built-in self-signed cert; the OAuth identity providers are silently
not honored. `kubeadmin` works throughout, so you are never locked out.

### What must already be in 1Password

These live in the `eso` vault and outlive any cluster, so a rebuild finds them
already there. A **first** build, or a fork, has to create them:

| Item | Holds | Created by |
|---|---|---|
| `homelab-ca` | the lab-wide root CA keypair | [`scripts/export-homelab-ca.sh`](scripts/export-homelab-ca.sh) |
| `keycloak-homelab` | realm client secret and account passwords | [`scripts/create-keycloak-realm-secrets.sh`](scripts/create-keycloak-realm-secrets.sh) |
| `github-oauth-hub` | GitHub OAuth App credentials | [`scripts/create-github-oauth-secret.sh`](scripts/create-github-oauth-secret.sh) |

`homelab-ca` is the one that matters most on a rebuild. Because the CA is an
artifact rather than something each cluster generates, a rebuilt cluster
materialises the **same** root — so every client that already trusts
`Bewley Homelab CA` keeps working. Losing that item means every client re-trusts
a new CA.

### Checking it actually converged

```bash
oc get co            # no cluster operator Degraded
oc get csv -A | grep -v Succeeded    # ArgoCD will not tell you an operator failed
```

ArgoCD reporting Synced/Healthy is not sufficient on its own — see
[docs/troubleshooting.md](docs/troubleshooting.md).

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

## Troubleshooting

[docs/troubleshooting.md](docs/troubleshooting.md) — failure modes actually hit
building this, each with the symptom that identifies it. Most share a trait:
the thing that looks healthy is not the thing that is broken.

Two worth knowing before you need them:

- A sync that retries forever against a revision you already fixed. Compare
  `.status.sync.revision` against
  `.status.operationState.operation.sync.revision`.
- ArgoCD reporting an operator Synced/Healthy when its CSV failed to install.
  Check `oc get csv -A | grep -v Succeeded`, not the ArgoCD UI.

## Issue tracking

This repo uses [beads](https://github.com/gastownhall/beads). `bd ready` for
available work; the GitOps buildout is epic `homelab-2026-4pq`.
