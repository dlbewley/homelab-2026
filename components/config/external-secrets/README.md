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
  --from-literal=token="$(op read 'op://development/eso-service-account/credential')"
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
  --from-literal=token="$(op read 'op://development/eso-service-account/credential')" \
  --dry-run=client -o yaml | oc replace -f -
```

### Why not seal it or commit it encrypted?

Sealed Secrets or SOPS would work, but both add a second secret-management
system to bootstrap for the sake of one value that changes rarely. One manual
`oc create secret` per cluster build is the smaller cost. Revisit if the number
of clusters grows.

## Not yet wired in

The manifests are complete but no ApplicationSet references them, so nothing
deploys yet. To enable, uncomment the `external-secrets` element in
[clusters/hub/operators.yaml](../../../clusters/hub/operators.yaml) and add a
matching one to [clusters/hub/config.yaml](../../../clusters/hub/config.yaml):

```yaml
          - name: external-secrets
            namespace: external-secrets-operator
            path: components/config/external-secrets/overlays/hub
```

Expect `hub-cfg-external-secrets` to fail its first attempts with
`no matches for kind "ClusterSecretStore"` until the operator installs those
CRDs; it retries and converges. The store will then sit `Ready: False` until
the token secret above exists.

Tracked as `homelab-2026-4pq.5`.

## Reference

- [Securing Cloud-init User Data with External Secrets and OpenShift Virtualization](https://guifreelife.com/blog/2025/10/06/Securing-Cloud-init-User-Data-with-External-Secrets-and-OpenShift-Virtualization/)
