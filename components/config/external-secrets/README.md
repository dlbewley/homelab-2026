# external-secrets

Configures the Red Hat build of the External Secrets Operator and points it at
1Password, so that `ExternalSecret` resources can pull credentials into the
cluster without those credentials living in git.

## Two namespaces

This component is easy to get wrong because there are two:

| Namespace | Created by | Contains |
|---|---|---|
| `external-secrets-operator` | `components/olm/external-secrets/base` | the operator (OLM Subscription, CSV, operator pod) |
| `external-secrets` | the operator, from `ExternalSecretsConfig` | the operand: controller/webhook pods, **and the token secret** |

The operator installs `AllNamespaces`-only, so its OperatorGroup has an empty
spec rather than `targetNamespaces` like the other components in this repo.

## Provider: 1Password SDK, not Connect

`overlays/hub/clustersecretstore.yaml` uses the `onepasswordSDK` provider. The
controller talks to the 1Password service directly using a **service account
token**. There is no Connect server to deploy, run or reach — which is the main
reason to prefer it here.

The consequence is that the controller needs outbound internet access. That is
what the `allow-external-secrets-egress` NetworkPolicy in
`base/externalsecretsconfig.yaml` is for; without it the store fails to
authenticate even with a valid token.

The service account must be granted read access to the **`eso` vault**
(`spec.provider.onepasswordSDK.vault`). A token that authenticates fine but
cannot see that vault produces confusing empty-result errors rather than an
auth failure.

## Manual step: the token

**This is the one thing GitOps cannot do for you.**

The token that authenticates the cluster to 1Password is the credential that
unlocks every other credential. It cannot be committed, and it cannot be
fetched by External Secrets, because External Secrets needs it in order to
fetch anything. Bootstrapping it by hand is the cost of not having a
pre-existing trust anchor.

After the operator has reconciled `ExternalSecretsConfig` and the
`external-secrets` namespace exists:

```bash
oc create secret generic onepassword-connect-token \
  --namespace external-secrets \
  --from-literal=token="$(op read 'op://development/eso-service-account/token')"
```

Adjust the `op://` reference to wherever the service account token actually
lives. To avoid the shell, use
`--from-file=token=/path/to/token` instead.

> The secret is named `onepassword-connect-token` for continuity, but it holds
> a **service account** token, not a Connect token. Renaming it means updating
> `serviceAccountSecretRef.name` in `clustersecretstore.yaml` to match.

Verify:

```bash
oc get secret onepassword-connect-token -n external-secrets
oc get clustersecretstore 1password-sdk -o jsonpath='{.status.conditions}' | jq
```

A healthy store reports `type: Ready, status: "True"`. If it does not, check in
this order: the token value, then that the service account can read the `eso`
vault, then that egress to 1Password is actually permitted.

Rotation is manual — after rotating in 1Password:

```bash
oc create secret generic onepassword-connect-token \
  --namespace external-secrets \
  --from-literal=token="$(op read 'op://development/eso-service-account/token')" \
  --dry-run=client -o yaml | oc replace -f -
```

### Why not seal it or commit it encrypted?

Sealed Secrets or SOPS would work, but both add a second secret-management
system to bootstrap for the sake of one value that changes rarely. One manual
`oc create secret` per cluster build is the smaller cost. Revisit if the number
of clusters grows.

## What to expect on first sync

Both layers are wired into the hub cluster, as `hub-olm-external-secrets` and
`hub-cfg-external-secrets`.

1. `hub-olm-external-secrets` installs the operator into
   `external-secrets-operator`.
2. `hub-cfg-external-secrets` will **fail its first attempts** with
   `no matches for kind "ExternalSecretsConfig"` / `"ClusterSecretStore"` until
   the CSV registers those CRDs. Both come from the same CSV, so they appear
   together and ordinary retry/backoff converges — this is not the kind of
   deadlock hit in [nmstate](../nmstate), where one CR had to be applied before
   the other's CRD existed.
3. `ExternalSecretsConfig` then creates the `external-secrets` namespace and
   the operand.
4. The `1password-sdk` ClusterSecretStore sits `Ready: False` until you create
   the token secret above. That is expected, not a fault.

If the `external-secrets` namespace does not appear once the operand is
running, create it before the `oc create secret` step — the operator is
expected to create it, but that has not been verified on this cluster:

```bash
oc get ns external-secrets || oc create ns external-secrets
```

Verify the whole chain:

```bash
oc get csv -n external-secrets-operator
oc get externalsecretsconfig cluster
oc get clustersecretstore 1password-sdk
```

Tracked as `homelab-2026-4pq.5`.

## Reference

- [Securing Cloud-init User Data with External Secrets and OpenShift Virtualization](https://guifreelife.com/blog/2025/10/06/Securing-Cloud-init-User-Data-with-External-Secrets-and-OpenShift-Virtualization/)
