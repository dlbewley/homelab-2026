# Troubleshooting

Failure modes actually hit while building this repo, with the symptom that
identifies each. Most share a trait worth internalising: **the thing that looks
healthy is not the thing that is broken.**

---

## A sync retries forever against a revision that no longer exists

**Symptom.** An Application stays `OutOfSync`, `Retrying attempt #N`, and the
error names something you already fixed and merged.

**The tell.** Compare the two revisions:

```bash
oc get app <name> -n openshift-gitops -o jsonpath='sync={.status.sync.revision}{"\n"}op={.status.operationState.operation.sync.revision}{"\n"}'
```

```
sync = f9485c1   ← current main, has the fix
op   = b732e2e   ← what the running operation is still replaying
```

**Why.** ArgoCD's retry re-attempts the *same operation* with the manifests it
rendered when that operation began. It does **not** re-render from a newer
revision. So a sync that started before your fix will replay the broken
manifests until it exhausts its retry limit — with `limit: 20` and a 5m cap,
that is a long time.

**Fix.** Terminate the in-flight operation so automated sync starts fresh:

```bash
oc patch app <name> -n openshift-gitops --type=merge -p '{"operation":null}'
```

Give it a minute — the operation may need to finish its current attempt before a
new one starts at the current revision.

**Do not delete the Application to reset it.** These carry
`resources-finalizer.argocd.argoproj.io`, so deletion **cascades and prunes
every resource the app manages**. Check before you ever consider it:

```bash
oc get app <name> -n openshift-gitops -o jsonpath='{.metadata.finalizers}{"\n"}'
```

Hit three times here: `hub-cfg-odf`, `hub-cfg-keycloak`, `hub-cfg-cert-manager`.
If an error names something absent from current `main`, check the revisions
first — it is a two-minute diagnosis, not a mystery.

---

## ArgoCD reports Synced/Healthy while the operator failed to install

**Symptom.** `hub-olm-<x>` is green, but the operator does nothing.

**Why.** The Application manages the Namespace, OperatorGroup and Subscription.
The **CSV is created by OLM** and is not part of the Application, so a `Failed`
CSV is invisible to ArgoCD.

**Check operator health at the CSV, never in the ArgoCD UI:**

```bash
oc get csv -A | grep -v Succeeded
```

Seen with metallb, whose OperatorGroup requested an unsupported install mode.
`scripts/verify-channels.sh` now catches that class before it reaches a cluster.

---

## An operator install fails on install mode

**Symptom.**

```
OwnNamespace InstallModeType not supported, cannot configure to watch own namespace
```

**Why.** `targetNamespaces` requests OwnNamespace/SingleNamespace; an empty
`spec: {}` requests AllNamespaces. The message names the mode but not the fix.

```bash
scripts/verify-channels.sh
```

Checks every component's OperatorGroup shape against the install modes the
operator supports **on the channel that Subscription pins** — channels can
disagree, and reading the wrong one gives a false pass.

---

## An operator CR is created but nothing happens

**Symptom.** The CR exists, has no `status`, no operand pod appears, and the
operator log never mentions it.

**Why.** The feature is gated. The cert-manager operator ships trust-manager but
will not deploy it unless the Subscription sets:

```yaml
- name: UNSUPPORTED_ADDON_FEATURES
  value: TrustManager=true
```

**Check for the operand pod, not the CR** — the CR looks fine either way.

---

## Permanently OutOfSync while everything is Healthy

**Symptom.** Sync reports `successfully synced (all tasks run)`, every resource
is Healthy, and the app still says `OutOfSync`.

**Why.** Fields the API server defaults that git deliberately does not set.
`ServerSideApply` makes them visible, because ArgoCD compares what it *would*
apply against the live object and defaults exist only on the live side.

**Diagnose by diffing desired against live** — if live is a strict superset,
they are defaults:

```bash
oc kustomize <path> | ...      # desired
oc get <kind> <name> -o json | jq -S .spec
```

**Fix** with `ignoreDifferences` scoped to named leaf fields, so genuine drift is
still reported. See `clusters/hub/config.yaml`.

Worth fixing even though nothing is broken: an app permanently OutOfSync while
healthy teaches people to ignore OutOfSync, which is the signal everything else
here depends on.

---

## `Force=true` is not `--force-conflicts`

**Symptom.**

```
error validating options: --force cannot be used with --server-side
```

**Why.** ArgoCD's `Force=true` means client-side `kubectl apply --force`, which
is mutually exclusive with `--server-side`. It is **not** the SSA conflict
resolver, even though `oc apply --server-side --force-conflicts` is the manual
command that fixes the underlying ownership conflict.

**Fix.** For a resource whose live spec is small and not operator-managed, opt
that one resource out with `ServerSideApply=false`. Do not apply that broadly —
SSA exists to stop ArgoCD overwriting fields operators own.

---

## A manifest is in the repo but never deployed

**Symptom.** Nothing. Kustomize renders an unreferenced file as **nothing at
all** and exits 0.

**Why.** The file is not listed in its directory's `kustomization.yaml` — often
a commented-out entry staged for later.

```bash
scripts/validate.sh
```

Flags unreferenced manifests. Deliberate exceptions live in
`scripts/allowed-orphans.txt` with a reason.

The same shape bites with an **empty** manifest file, and with a component no
ApplicationSet references — `validate.sh` catches unreferenced *files*, not
unreferenced *components*.

---

## Schema and provider errors that dry-run cannot catch

Two different limits, worth keeping separate:

**Server-side apply catches CRD schema errors.** A field valid in one operator
release and removed in the next fails as:

```
failed to create typed patch object ... field not declared in schema
```

Neither `kustomize build` nor CI catches it, because the manifest is
schema-valid until an API server with that CRD says otherwise:

```bash
oc kustomize <path> | oc apply --server-side --dry-run=server -f -
```

**Nothing catches a wrong provider contract.** An `ExternalSecret` with a
malformed `remoteRef` is schema-valid and passes dry-run; only the provider
rejects it, at sync time. The `onepasswordSDK` provider wants a single
`<item>/<field>` key — an item name plus a separate `property:` is the *Connect*
provider's shape and silently parses to nothing.

---

## Two silent failures in the OAuth identity provider

**Symptom.** The provider simply does not appear on the login page. No error on
the OAuth CR.

**Why.** From the CRD, for both `clientSecret` and `ca`:

> If the secret or expected key is not found, **the identity provider is not
> honored.**

**Check the prerequisites directly:**

```bash
oc get secret keycloak-client-secret -n openshift-config
oc get cm homelab-ca -n openshift-config
```

---

## A custom router certificate degrades the cluster

**Symptom.**

```
RouterCertsDegraded: certificate could not validate route hostname
oauth-openshift.apps.<cluster>: x509: certificate signed by unknown authority
```

**Why.** Pointing `IngressController/default` at a privately-signed certificate
leaves cluster components unable to validate route hostnames. The cluster stays
`Available`, so it hides.

Here it went Degraded 2m23s after the wildcard secret was created and stayed
that way for **seven days**, because the router visibly served the new
certificate and that was mistaken for success.

**The router serving a certificate is not evidence the cluster accepts it.**
After changing a default ingress certificate:

```bash
oc get co
```

**Fix.** Publish the CA into the cluster-wide trust bundle via `proxy/cluster`
`trustedCA`. It is *merged* with the system roots, not substituted, so public
CAs keep working.

---

## Realm changes do not take effect

**Symptom.** You edit `KeycloakRealmImport` in git, ArgoCD syncs, nothing
changes in Keycloak.

**Why.** It is **import-on-create**, not continuous reconciliation.

**Fix.** Delete the resource and let ArgoCD recreate it:

```bash
oc delete keycloakrealmimport homelab -n keycloak
```

The consequence worth remembering: realm content edited in the admin console
diverges from git silently. That is why OpenShift group membership is **not**
synced from Keycloak here — cluster-admin would be granted by a mutable console
rather than a reviewed commit.
