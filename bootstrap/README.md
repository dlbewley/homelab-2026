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

Add yourself to the group:

```bash
oc adm groups add-users cluster-admins dlbewley
```

The default ArgoCD instance already maps that group to the ArgoCD `admin` role:

```bash
oc get -n openshift-gitops argocd/openshift-gitops -o jsonpath='{.spec.rbac}'
```

## Next

```bash
oc apply -k ../clusters/hub
```
