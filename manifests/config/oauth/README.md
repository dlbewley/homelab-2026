# oauth

Adds Keycloak as an OpenShift identity provider, so people log in as themselves
rather than sharing `kubeadmin`.

## Why IntegratedOAuth and not `Authentication type: OIDC`

Verified against the live cluster:

```
authentications.config.openshift.io  spec.oidcProviders      maxItems: 1
oauths.config.openshift.io           spec.identityProviders  unbounded
```

External OIDC permits exactly **one** provider, which would forbid adding GitHub
alongside Keycloak. IntegratedOAuth supports both in the same CR, and rollback
is removing a list entry rather than reconfiguring kube-apiserver.

## Three names that must agree

None of the failures says so plainly:

| Setting | Value | Must match |
|---|---|---|
| `identityProviders[].name` | `keycloak` | the tail of the Keycloak client's `redirectUri` |
| `openID.clientID` | `ocp-hub` | the `clientId` in the `homelab` realm |
| `openID.issuer` | `.../realms/homelab` | the realm's issuer exactly |

Change the provider name without the client's redirect URI and login fails with
a `redirect_uri` mismatch that names neither side.

## Two silent failure modes

The OAuth CRD is unusually blunt about both:

> The key `clientSecret` is used to locate the data. **If the secret or expected
> key is not found, the identity provider is not honored.**

> `ca` … **If specified and the config map or expected key is not found, the
> identity provider is not honored.**

"Not honored" means the provider quietly disappears from the login page. There is
no error on the OAuth CR. So:

- the `ExternalSecret` writes key `clientSecret` into `openshift-config`, from
  the same 1Password field the realm import uses for the client's own secret —
  one source, so the two sides cannot drift
- the CA comes from the trust-manager `Bundle` in
  [cert-manager](../cert-manager), because Keycloak serves a `homelab-ca`
  certificate rather than a public root

## Group membership stays in git

`claims.groups` is deliberately **not** set, though OpenShift supports it:

> groups is the list of claims value of which should be used to **synchronize
> groups from the OIDC provider to OpenShift** for the user.

Syncing would make Keycloak the single source of truth for membership — but
`KeycloakRealmImport` is import-on-create, so realm groups can be edited in the
admin console and drift from git. Cluster-admin would then be granted by a
mutable console rather than a reviewed commit.

Membership therefore stays declared in
[bootstrap/rbac.yaml](../../../bootstrap/rbac.yaml), where granting it is a
diffable change. Per-cluster authorization is unaffected either way: that comes
from each cluster's own `ClusterRoleBinding`, not from membership.

The realm still emits the `groups` claim, which other OIDC clients such as
Grafana can consume.

## `mappingMethod: claim`

Provisions an OpenShift `User` from `preferred_username`, and **refuses** if a
User of that name already exists mapped to a different identity. That is
deliberate — it stops a second provider silently taking over an existing
account.

Adding GitHub later for the same person means setting `mappingMethod: add` on
that provider, which attaches a second `Identity` to the same `User`. Note the
consequence: whoever controls either provider can then obtain that User's RBAC.

Supported values are `add`, `claim` and `lookup` — the API rejects anything
else. `generate` appears in older documentation but is not accepted here.

## Verifying

The provider appears on the login page within a minute or so:

```bash
oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}{"\n"}'
```

```bash
oc get co authentication
```

Wait for `Progressing=False` — the authentication operator rolls out new pods on
every change to this CR.

Confirm the prerequisites actually landed, since both fail quietly:

```bash
oc get secret keycloak-client-secret -n openshift-config -o jsonpath='{.data.clientSecret}' | wc -c
oc get cm homelab-ca -n openshift-config -o jsonpath='{.data.ca\.crt}' | head -1
```

Then log in as a realm user:

```bash
oc login -u dlbewley --server=https://api.hub.lab.bewley.net:6443
```

```bash
oc get user; oc get identity
```

`Identity` is `keycloak:dlbewley`; `User` is `dlbewley`. Groups and RBAC key on
the **User** name, which is why `bootstrap/rbac.yaml` listing `dlbewley` in
`cluster-admins` is what grants admin.

## Rollback

`kubeadmin` keeps working throughout. To remove the provider:

```bash
oc patch oauth cluster --type=json -p '[{"op":"remove","path":"/spec/identityProviders"}]'
```

ArgoCD will put it back — delete the element from `oauth.yaml` for a permanent
removal.

## Not done here

**GitHub.** Planned as a second provider restricted to an organization, useful
precisely because it does not depend on Keycloak, CloudNativePG or ODF being
healthy. It needs a GitHub OAuth App registered first. See `homelab-2026-4pq.8`.
