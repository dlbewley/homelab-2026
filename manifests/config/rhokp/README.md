# rhokp

Red Hat Offline Knowledge Portal (RHOKP): a local, searchable copy of Red Hat
product documentation, solutions and articles, served at
<https://docs.apps.hub.lab.bewley.net>.

## Pieces

| What | Namespace | Why |
|---|---|---|
| `Namespace/rhokp` | — | Holds nothing else |
| `ExternalSecret/access-key` | `rhokp` | The RHOKP access key, from 1Password |
| `Deployment/rhokp` | `rhokp` | The portal, `registry.redhat.io/offline-knowledge-portal/rhokp-rhel9`, pinned by digest |
| `Service/rhokp` | `rhokp` | Port 8080 |
| `Route/rhokp` (hub overlay) | `rhokp` | `docs.apps.<cluster domain>`, edge TLS with the router's wildcard |

## MCP endpoint

The image also runs an MCP server (`mimcp`, one `search` tool over the
documentation, errata and CVEs), reachable through the same Route at
<https://docs.apps.hub.lab.bewley.net/mcp> (streamable HTTP, POST). It has no
authentication of its own, like the portal itself.

## Manual step: the access key

Generate a key at <https://access.redhat.com/offline/access> and store it in
1Password, vault `eso`, item `RHOKP`, field `credential`. Until it exists the
ExternalSecret reports `SecretSyncedError` and the pod waits in
`CreateContainerConfigError`.

## Updating the content

The documentation ships inside the image, so new content means a new image.
Look up the current manifest-list digest in the Red Hat Ecosystem Catalog and
replace the digest in `base/deployment.yaml`. The image is about 10 GB and
took almost 14 minutes to pull to a hub node, so expect that much downtime
whenever the digest changes or the pod moves to a node without it.

## Verify

```bash
oc get externalsecret,pod,route -n rhokp
curl -sI https://docs.apps.hub.lab.bewley.net | head -1
```
