# bootstrap

Day 1. The bare minimum to make ArgoCD available on a new cluster, and the only
thing in this repo applied by hand.

```bash
oc apply -k bootstrap/
```

Contents:

- **`openshift-gitops.yaml`** — Namespace, OperatorGroup and Subscription for
  the OpenShift GitOps operator. The operator then creates the default
  `openshift-gitops` ArgoCD instance.
- **`rbac.yaml`** — the `cluster-admins` group, and cluster-admin for the ArgoCD
  service accounts.

## Why the RBAC is here and not in GitOps

ArgoCD cannot grant itself the permissions it needs to configure the cluster.
Without these bindings the config layer fails with:

```
nmstates.nmstate.io "nmstate" is forbidden: User
"system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller"
cannot patch resource "nmstates" in API group "nmstate.io" at the cluster scope
```

The GitOps operator grants cluster-scoped access only for namespaces listed in
`ARGOCD_CLUSTER_CONFIG_NAMESPACES`. Binding it explicitly is idempotent and
removes the guesswork.

The human-facing binding is named **`homelab-cluster-admins`**, not
`cluster-admins`. OpenShift ships a built-in ClusterRoleBinding by that exact
name whose subjects are the `system:cluster-admins` group and the `system:admin`
user; reusing the name replaces them.

Group membership is declared in `rbac.yaml` rather than added imperatively with
`oc adm groups add-users`, so it is reviewable and survives a rebuild. Edit the
`users:` list there to grant access.

The default ArgoCD instance already maps that group to the ArgoCD `admin` role:

```bash
oc get -n openshift-gitops argocd/openshift-gitops -o jsonpath='{.spec.rbac}'
```

## Next

```bash
oc apply -k ../clusters/hub
```

**That is not the last manual step.** Once External Secrets has created its
operand namespace, the 1Password service-account token has to be seeded by hand
— it is the credential every other credential is fetched with, so it cannot
itself come from External Secrets:

```bash
oc create secret generic onepassword-connect-token \
  --namespace external-secrets \
  --from-file=token=/path/to/service-account-token
```

The value is the 1Password **service-account token**, scoped to the `eso` vault
— the credential issued when the service account was created, not one of the
items it reads.

Until then the cluster sits partly built rather than failing loudly: no CA, so
no certificates, and the OAuth identity providers are silently not honored.
`kubeadmin` keeps working throughout.

See the [root README](../README.md#bringing-up-a-cluster) for the full sequence
and the 1Password items it depends on.
