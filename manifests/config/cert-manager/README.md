# cert-manager

Issues and automatically renews TLS certificates. On this cluster it replaces
the manual extract-and-distribute ritual — `ext-kubeconfig-cacerts.sh`, then
telling every client to trust a fresh set of certs after each rebuild — with one
CA you trust once.

## How it works, in four objects

| Object | Answers | Scope |
|---|---|---|
| `ClusterIssuer` | *who signs* | cluster-wide |
| `Certificate` | *what you want* — DNS names, lifetime, target Secret | namespaced |
| `CertificateRequest`, `Order`, `Challenge` | machinery cert-manager creates itself | — |
| `Secret` (`kubernetes.io/tls`) | the result | namespaced |

You write a `Certificate`. cert-manager produces a `Secret`. You point something
at that Secret. It renews on its own and rewrites the Secret in place, so
whatever consumes it picks up the new key material without further action.

The one rule that catches people: **`Certificate` and its `Secret` live in the
same namespace**, and it must be the namespace of whatever consumes it. That is
why the wildcard below is defined in `openshift-ingress` and not here.

## Two namespaces

Same split as [external-secrets](../external-secrets):

| Namespace | Created by | Contains |
|---|---|---|
| `cert-manager-operator` | `manifests/olm/cert-manager/base` | the operator |
| `cert-manager` | the operator, from the `CertManager` CR | controller, webhook, cainjector — **and where a ClusterIssuer looks for its CA secret** |

## The issuer chain

Three objects in `base/`, applied in sync-wave order because each needs the one
before it:

```
selfsigned-bootstrap  (ClusterIssuer, wave 5)   can sign anything, trusted by nothing
        │  signs
        ▼
homelab-ca            (Certificate, wave 6)     isCA: true → secret homelab-ca-tls
        │  becomes
        ▼
homelab-ca            (ClusterIssuer, wave 7)   ← reference this one
```

cert-manager cannot conjure a CA from nothing — something must sign the root,
and a self-signed issuer is that something. `selfsigned-bootstrap` exists only
for that; **reference `homelab-ca` for everything else.**

## Trusting the CA

Certificates from `homelab-ca` are not publicly trusted, so clients warn until
they trust the root once:

```bash
oc extract secret/homelab-ca-tls -n cert-manager --keys=tls.crt --to=- > homelab-ca.crt
```

On macOS:

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homelab-ca.crt
```

That is one CA, and it survives cluster rebuilds as long as the
`homelab-ca-tls` secret does — unlike the per-cluster certs that had to be
re-extracted each time.

> **Multi-cluster note.** The root is generated per cluster, so a second cluster
> means a second CA to distribute. The better pattern is one lab-wide CA keypair
> in 1Password, delivered to each cluster by External Secrets — the machinery is
> already in place. Left simple here because a self-signed root needs no manual
> bootstrap step.

## What `overlays/hub` does

**`apps-wildcard`** — one certificate covering every Route on the cluster:
console, ArgoCD, and any application Route. Defined in `openshift-ingress`, so
the Secret lands where the router reads it.

A wildcard matches **one label only**: `foo.apps.hub.lab.bewley.net` yes,
`foo.bar.apps.hub.lab.bewley.net` no.

**`ingresscontroller.yaml`** — points the default router at it, by declaring
only `spec.defaultCertificate` and letting server-side apply merge that into the
cluster-owned object. Same partial-apply pattern as the
[StorageClass defaults](../odf) and [Node labels](../node-labels), including
`Prune=false,Delete=false` so removing the file can never delete the cluster's
IngressController.

### Applying this triggers a router rollout

Expect browsers to warn until the homelab CA is trusted. That is the CA needing
trust, not a broken certificate.

Ordering is safe: ArgoCD has a built-in health check for cert-manager
`Certificate` resources, so wave 20 does not start until the wave 10 Certificate
reports `Ready`. The router is never pointed at a Secret that does not exist.

To revert to the built-in self-signed cert:

```bash
oc patch ingresscontroller/default -n openshift-ingress-operator \
  --type=json -p '[{"op":"remove","path":"/spec/defaultCertificate"}]'
```

## Verifying

```bash
oc get clusterissuer
```

Both should report `READY True`. Then:

```bash
oc get certificate -A
```

`homelab-ca` in `cert-manager` and `apps-wildcard` in `openshift-ingress`, both
`READY True`. A Certificate stuck `False` explains itself:

```bash
oc describe certificate apps-wildcard -n openshift-ingress
```

Confirm the router is actually serving it:

```bash
echo | openssl s_client -connect console-openshift-console.apps.hub.lab.bewley.net:443 2>/dev/null | openssl x509 -noout -issuer -subject -dates
```

The issuer should be `Bewley Homelab CA`.

## Using it for your own certificates

Anywhere in the cluster, request a cert by writing a `Certificate` in the
namespace that needs it:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-app
  namespace: my-app
spec:
  secretName: my-app-tls
  dnsNames:
    - my-app.apps.hub.lab.bewley.net
  issuerRef:
    name: homelab-ca
    kind: ClusterIssuer
    group: cert-manager.io
```

Then reference `my-app-tls` from a Route or Ingress. No renewal handling — the
Secret is rewritten in place before expiry.

## Adding Let's Encrypt later

Publicly trusted certs are possible without replacing any of this: add a second
`ClusterIssuer` and choose per `Certificate` which to use.

`bewley.net` is served by self-hosted nameservers (`ns1`/`ns2.bewley.net`), so
the cloud DNS-01 solvers do not apply. The route is **ACME with DNS-01 over
RFC2136**, writing `_acme-challenge` TXT records straight into BIND with a TSIG
key. It works for internal-only addresses because DNS-01 never needs inbound
HTTP — which matters here, since `api.hub.lab.bewley.net` resolves to
`192.168.4.17` internally.

Prerequisites are outside this repo: a TSIG key, and BIND configured to allow
dynamic updates for the zone. The key belongs in 1Password, delivered by
External Secrets.
