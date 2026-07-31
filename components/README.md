# components

**Reserved.** Nothing here yet, deliberately.

This directory is for genuine [Kustomize Components][spec] — `kind: Component`,
`apiVersion: kustomize.config.k8s.io/v1alpha1`. The building blocks that make up
this cluster's configuration live in [`manifests/`](../manifests) and are plain
`kind: Kustomization` files forming base/overlay chains.

The split exists because "component" is overloaded. Calling the whole tree
`components/` while none of it contained a Kustomize Component was a needless
trip hazard, so the name is now reserved for the real feature.

[spec]: https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/component/

## Component vs Kustomization

| | Kustomization | Component |
|---|---|---|
| `kind:` | `Kustomization` | `Component` |
| referenced by | `resources:` | `components:` |
| applied | once, deduplicated | once per inclusion |
| evaluated | with resources | after resources, in listed order |
| can add resources | yes | yes |
| can patch resources it does not own | no | **yes** |

That last row is the point. A Component can say "additionally, patch whatever
is already here", which a base cannot.

## Two rules

**Reference with `components:`, never `resources:`.** Kustomize rejects the
second outright:

```
expected kind != 'Component' for path '.../mycomp'
```

**Never point an ApplicationSet `path:` at a Component directory.** ArgoCD runs
`kustomize build` on whatever the path resolves to, and a patch-only Component
built standalone emits **nothing and exits 0** — no resources, no error. The
Application reports Synced/Healthy having deployed nothing. That is the same
silent-nothing failure as an unreferenced manifest, which is why
`scripts/validate.sh` checks for it.

Only `manifests/**/base` and `manifests/**/overlays/<cluster>` are safe as
Application paths.

## When to add one

**When a second overlay would copy something.** Not before — a Component used
once is indirection with no payoff.

With a single cluster there is nothing here yet. The candidates that appear the
moment a second cluster exists:

| Today, in `manifests/` | Becomes a Component when |
|---|---|
| `config/odf/overlays/hub` mds/OSD resource patch | a second ODF cluster shares the "3-node small" profile |
| `config/local-storage/overlays/hub` disk-size bounds | a second cluster has the same disk geometry |
| `config/odf/overlays/hub/storageclass-defaults.yaml` | strongest candidate — "rbd default + virt default" is a convention for *any* ODF+CNV cluster, not a hub-specific value |
| `config/metallb/overlays/hub/addresspool.yaml` | you want an on/off slice rather than a commented-out line |

Optional slices are the clearest case. Three overlays in `manifests/` currently
do nothing but `resources: [../../base]` — they exist only because an
ApplicationSet path must resolve to a Kustomization. "This cluster additionally
wants X" is exactly what a Component expresses.

## What Components cannot fix

All six `manifests/olm/*/base/kustomization.yaml` files are structurally
identical:

```yaml
resources: [namespace.yaml, operatorgroup.yaml, subscription.yaml]
```

That looks like duplication a Component should absorb. It is not — the
*referenced files* differ in content, and kustomize has no templating, so
nothing can parameterize them. This boilerplate is irreducible in plain
kustomize. Reach for a generator or a chart if it ever becomes intolerable.
