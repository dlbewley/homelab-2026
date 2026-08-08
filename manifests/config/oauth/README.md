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

## GitHub, the second provider

Deliberately independent of Keycloak: it does not need CloudNativePG, ODF or
the Keycloak pod to be healthy, so it is a genuine fallback rather than a
convenience.

### `mappingMethod: add`, and why the order already worked out

Keycloak runs `claim`, which **refuses** to bind an existing User to a second
identity. Since the Keycloak login already created `User/dlbewley`, a `claim`
GitHub provider would simply fail. `add` attaches a second `Identity` to the
same `User`, so one person keeps one set of RBAC however they signed in:

```
Identity  keycloak:<sub-uuid>  ─┐
                                ├─►  User dlbewley  ◄── Group cluster-admins
Identity  github:<login>       ─┘
```

Note the Keycloak identity embeds the OIDC `sub` (a UUID), not the username —
`preferred_username` only sets the **User** name. Groups and RBAC key on the
User, which is what makes merging work.

The cost is real: **whoever controls either provider holds that User's
permissions**. `organizations` bounds that, and GitHub usernames can be renamed
or re-registered, so check what actually landed after first login:

```bash
oc get identity
```

### `organizations` is required, and must be a real Organization

```
one of organizations or teams must be specified unless hostname is set or lookup is used
```

Deliberate — it stops you granting login to all of GitHub.

**A personal User account passes validation and then matches nobody.** The API
cannot tell the difference, so the provider deploys green and no one can ever
log in. `dwnwrd` was confirmed to be an Organization via the GitHub API before
being used. Check before trusting a name:

```bash
curl -sS https://api.github.com/orgs/<name> | jq -r '.login // .message'
```

### Callback URL

GitHub requires the redirect to be a **subdirectory** of the registered callback
URL — *"The redirect URL's path must reference a subdirectory of the callback
URL"* — so registering:

```
https://oauth-openshift.apps.hub.lab.bewley.net/oauth2callback
```

covers `/oauth2callback/github` and works for any provider name. That is looser
than the Keycloak client, whose `redirectUri` must match the provider name
exactly.

### It must be an OAuth App, not a GitHub App

Different things, adjacent in the GitHub UI, and the failure is confusing.
OpenShift's `github` provider needs **Settings → Developer settings → OAuth
Apps**.

### The secret

```bash
scripts/create-github-oauth-secret.sh --client-id <id>
```

Prompts for the secret rather than taking it as an argument, so it stays out of
shell history and the process list, and writes it to the `github-oauth-hub`
item in the `eso` vault. `--dry-run` shows the structure with the secret
redacted.

The client **ID** is committed in `oauth.yaml` — not because it is public, but
because the OAuth CR takes it as a plain string with no secret-reference option.

## Not done here

Nothing outstanding for identity providers. `htpasswd` was considered as
break-glass and rejected: `kubeadmin` already fills that role, and every extra
local credential is one more thing to rotate.
