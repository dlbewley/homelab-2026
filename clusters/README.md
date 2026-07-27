# clusters

One directory per OpenShift cluster. This is the only place that decides which
components a given cluster gets.

Each cluster directory holds four files:

| File | What |
|---|---|
| `appproject.yaml` | An AppProject per cluster, so the blast radius and the UI grouping are per-cluster |
| `root.yaml` | The app of apps. Watches this directory, so the ApplicationSets below become self-managing |
| `operators.yaml` | ApplicationSet — which operators to install |
| `config.yaml` | ApplicationSet — how they are configured |

## Adding a cluster

```bash
cp -r clusters/hub clusters/foo
```

Then:

1. Rename `hub` → `foo` throughout all four files (AppProject name and
   references, Application/ApplicationSet names, `homelab.bewley.net/cluster`
   labels, generated app name prefixes).
2. Trim the element lists to what `foo` actually needs.
3. Add `components/config/<name>/overlays/foo/` for any component whose values
   differ, and point the element's `path` at it. Where nothing differs, point
   at `base` — see the `virtualization` element in `hub/config.yaml`.
4. `oc kustomize clusters/foo` to confirm it builds.
5. Against the new cluster: `oc apply -k bootstrap/`, then `oc apply -k clusters/foo`.

If step 3 makes you want to edit something under `components/*/base/`, that is
the signal a cluster-specific value leaked into a shared base — move it to an
overlay instead.

## Sources

Every Application here targets `https://github.com/dlbewley/homelab-2026.git`
on `main`. Working from a fork or a branch means changing `repoURL` /
`targetRevision` in `root.yaml`, `operators.yaml` and `config.yaml`:

```bash
sed -i '' 's|dlbewley/homelab-2026|you/your-fork|g' clusters/foo/*.yaml
```
