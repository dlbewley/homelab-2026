# maas-models

The models that Red Hat OpenShift AI's Models-as-a-Service (MaaS) fronts on a
cluster.

Config-only, and `overlays/<cluster>` only. Which models a cluster offers, and
where they are actually served, cannot be made cluster-agnostic.

The hub has no GPU, so nothing is served in the cluster. MaaS is used for what it
is: one governed endpoint — authentication, per-subscription token limits, API
keys — in front of models running somewhere else.

Tracked as `homelab-2026-o8y.9`, part of the epic `homelab-2026-o8y`.

## Status: registered, not yet reachable

`qwen2.5-7b-instruct` is in the MaaS catalog and every object below reports
Ready, **but a request for it cannot succeed yet.** RHOAI 3.5.1 will only talk to
an external model over TLS on port 443 with a publicly trusted certificate, and
LM Studio offers plain HTTP on port 1234. The gap, and the ways to close it, are
in [What RHOAI 3.5.1 requires of an external model](#what-rhoai-351-requires-of-an-external-model).

Do not trust the status fields here. `MaaSModelRef` reports `RuntimeReady: Backend
is healthy` while the gateway is being refused on port 443.

## The hub's first model: LM Studio on a Mac

| | |
|---|---|
| Served by | [LM Studio](https://lmstudio.ai/) on the Mac `blackout` |
| Address | `blackout.home.bewley.net:1234`, plain HTTP — which is the problem |
| API | OpenAI-compatible (`/v1/chat/completions`, `/v1/models`) |
| Auth | Bearer token, required — the server answers `401` without one |

Checked on 2026-10-12: the name resolves from the cluster's DNS, and both MaaS
gateway pods can reach the port and get that `401`.

Things to know about depending on a laptop:

- **It is a laptop.** When it sleeps or leaves the network the model is gone and
  MaaS returns errors for it.
- **The address is a DHCP lease** on a different subnet from the cluster
  (192.168.3.0/24 against 192.168.4.0/24). It works because the router forwards
  between them and DNS follows the lease.
- **There is no TLS.** LM Studio serves plain HTTP only, and RHOAI 3.5.1
  requires TLS. See the last section.

## Pieces

| What | Namespace | Why |
|---|---|---|
| `Namespace/maas-models` | — | The "model namespace": a model's credential, provider, model and catalog entry must share one |
| `ExternalSecret/lmstudio-blackout-api-key` | `maas-models` | LM Studio's token, from 1Password |
| `ExternalProvider/lmstudio-blackout` | `maas-models` | Where LM Studio is and how to authenticate to it |
| `ExternalModel/qwen2-5-7b-instruct` | `maas-models` | The model name clients use, mapped to that provider |
| `MaaSModelRef/qwen2-5-7b-instruct` | `maas-models` | Puts the model in the MaaS catalog |
| `MaaSAuthPolicy/qwen2-5-7b-instruct` | `models-as-a-service` | Who may use it: the `cluster-admins` group |
| `MaaSSubscription/lmstudio-local` | `models-as-a-service` | The token budget: 200,000 an hour |

From the first three MaaS generates the plumbing itself — an ExternalName
Service, an Istio ServiceEntry and an HTTPRoute on the MaaS gateway. They are not
in git and should not be.

## How a request travels

```
client ── MaaS API key ──▶ https://maas.apps.hub.lab.bewley.net/v1/chat/completions
                                 │  gateway: Authorino checks the key and the
                                 │  group; Limitador counts tokens
                                 ▼
                           payload processor: reads "model" from the body,
                           picks the provider, swaps the client's key for
                           LM Studio's token, rewrites the model name
                                 │  TLS, port 443, always
                                 ▼
                           blackout.home.bewley.net:443   ✗ nothing listens here
                           (LM Studio is on :1234, plain HTTP)
```

Two model names are in play, deliberately:

| | Value | Who uses it |
|---|---|---|
| `modelName` | `qwen2.5-7b-instruct` | MaaS clients, in the `model` field of a request |
| `targetModel` | `qwen2.5-7b-instruct-1m` | LM Studio. Its exact model key, which has a `-1m` suffix |

If LM Studio's key for the model changes — a different quantisation, a
re-download — `targetModel` has to follow. `lms ls` or `GET /v1/models` shows it.

## Access and quota

MaaS denies by default, so both of these are required:

- **`MaaSAuthPolicy`** grants the model to the `cluster-admins` group. That is
  the one populated group on the hub. To open it to anyone who can log in, add
  `system:authenticated`. Keycloak's groups are not synced into OpenShift, so
  they cannot be named yet.
- **`MaaSSubscription`** `lmstudio-local` is what an API key is issued against.
  Its 200,000 tokens an hour is a starting figure, not a measured one — roomy
  for one person, small enough that a runaway agent loop is stopped by MaaS
  with a `429` rather than by the laptop's fans.

Both live in `models-as-a-service`, RHOAI's tenant namespace, not beside the
model. That is where the controller looks for them.

## The credential

MaaS clients never see LM Studio's token. They authenticate to MaaS with their
own MaaS API key; the gateway's payload processor replaces it with the
provider's credential on the way out.

```
1Password  eso / LM Studio / tokens / blackout
     │  ClusterSecretStore 1password-sdk
     ▼
maas-models/lmstudio-blackout-api-key     key: api-key
     ▲
     └─ payload processor, when a request is routed to the model
```

The Secret's shape is dictated by MaaS
([Red Hat's guide, 1.21.4](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service#configuring-maas-external-models_maas-deploy)):

- the data key must be `api-key`
- the Secret must carry the label `inference.llm-d.ai/ipp-managed: "true"`;
  without it the payload processor does not read the Secret
- it must be in the same namespace as the `ExternalProvider` that names it

### The item has to be in the `eso` vault

The `1password-sdk` store reads exactly one vault, `eso`, and the cluster's
1Password service account can see only that vault. That is deliberate: the
cluster should be able to read the secrets meant for it and nothing else.

The token was first saved at `op://development/LM Studio/tokens/blackout`, which
the cluster cannot read. The ExternalSecret asks for the same
item / section / field path, resolved in `eso`. Until an item named `LM Studio`
with a `tokens` section and a `blackout` field exists there, it reports
`SecretSyncedError`. The item was moved there on 2026-10-12 and the three-part
key resolves.

Moving the item is one command:

```bash
op item move "LM Studio" --current-vault development --destination-vault eso
```

Granting the service account the `development` vault instead would work but is
the wrong trade: that vault holds the service account's own token, among other
things.

### Verifying

```bash
oc get externalsecret lmstudio-blackout-api-key -n maas-models
```

`READY` should be `True`, `STATUS` `SecretSynced`. Then check the shape without
printing the value:

```bash
oc get secret lmstudio-blackout-api-key -n maas-models -o json | jq '{keys: (.data | keys), label: .metadata.labels["inference.llm-d.ai/ipp-managed"]}'
```

If the token is regenerated in LM Studio, update the 1Password item. External
Secrets picks it up within the hour.

## Verifying the model

```bash
oc get externalprovider,externalmodel,maasmodelref -n maas-models
```

```bash
oc get maasauthpolicy,maassubscription -n models-as-a-service
```

All should report Ready. If the model is `Failed`, look at what the controller
generated:

```bash
oc get service,httproute,serviceentry,destinationrule -n maas-models
```

On 3.5.1 the Service and ServiceEntry are always port 443 and the
DestinationRule always `tls.mode: SIMPLE`, whatever the model is annotated with.

Then, as a member of `cluster-admins`, list the catalog with an OpenShift token:

```bash
curl -s -H "Authorization: Bearer $(oc whoami -t)" https://maas.apps.hub.lab.bewley.net/v1/models | jq '.data[].id'
```

An end-to-end completion needs a MaaS API key, created in the dashboard under
the `lmstudio-local` subscription or through `/v1/api-keys`.

If requests fail and the objects look right, check the controller is alive
before anything else — see [rhoai](../rhoai/README.md#the-maas-controller-needs-more-memory-than-it-ships-with).

## Running LM Studio so the cluster can use it

```bash
lms server start --bind 0.0.0.0
```

Binding beyond localhost exposes the server to the LAN, which is why token
authentication is switched on in LM Studio's server settings first. No model
needs to be loaded in advance if just-in-time loading is enabled there.

- [Serve on the local network](https://lmstudio.ai/docs/developer/core/server/serve-on-network)
- [Authentication](https://lmstudio.ai/docs/developer/core/authentication)
- [Running headless](https://lmstudio.ai/docs/developer/core/headless)
- [OpenAI compatibility](https://lmstudio.ai/docs/developer/openai-compat) and [tool use](https://lmstudio.ai/docs/developer/openai-compat/tools)

## What RHOAI 3.5.1 requires of an external model

Found on the hub on 2026-10-12, by reading what the controllers generated and
what Envoy was actually configured with.

| Requirement | Evidence |
|---|---|
| **Port 443.** No other port can be used | The generated Service, ServiceEntry and HTTPRoute backend are all 443 |
| **TLS.** Plain HTTP cannot be used | The ServiceEntry protocol is `HTTPS` and the DestinationRule is `tls.mode: SIMPLE` |
| **A certificate from a public CA** | Envoy validates the provider against its system trust store: 146 public CAs, `homelab-ca` not among them |
| **No way to supply your own CA** | `ExternalProvider` has four fields: `provider`, `endpoint`, `auth`, `config` |

### The documented escape hatch does not work

Red Hat's guide
([1.21.4](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service#configuring-maas-external-models_maas-deploy))
documents two annotations on the `ExternalModel` for precisely this case, with an
internal vLLM on port 8000 as its example:

```yaml
maas.opendatahub.io/tls: "false"
maas.opendatahub.io/port: "8000"
```

On 3.5.1 they are ignored. Three things were checked:

- **Applied as documented**, on the `inference.opendatahub.io` ExternalModel: the
  generated objects stayed at 443 and TLS.
- **The controller that builds those objects has no such setting.** The payload
  processor's binary contains neither those annotation keys nor the newer
  `inference.opendatahub.io/tls` and `/port` that upstream now documents on the
  `ExternalProvider`.
- **The older API does not help.** The `maas-controller` does recognise the
  annotations on the legacy `maas.opendatahub.io/v1alpha1` ExternalModel, but it
  immediately migrates such an object to the new API and the annotations are
  dropped on the way. Tried with a throwaway object, since deleted.

Where this is heading does not help either: upstream's current code does honour
port and TLS annotations, but
[refuses plain HTTP with API-key authentication](https://github.com/opendatahub-io/ai-gateway-payload-processing/blob/main/docs/external-provider-model.md),
because the key would travel in clear text. LM Studio with its token switched on
will need TLS on any version.

### Ways to close the gap

| Option | What it takes | Trade |
|---|---|---|
| **TLS on the Mac, public certificate** | A reverse proxy on `blackout` listening on 443 and forwarding to `127.0.0.1:1234`, with a Let's Encrypt certificate for its hostname (DNS-01, since the Mac is not reachable from the internet) | Nothing changes in the cluster, the token is encrypted, and LM Studio can go back to listening on localhost only. Needs software and certificate renewal on a laptop, and DNS API access for the challenge |
| **TLS inside the cluster** | A small proxy Deployment here that terminates TLS and forwards to `blackout:1234`, with `endpoint` pointed at its Service; plus the gateway made to trust the CA that signs it | Everything stays in git and nothing is installed on the Mac. Two unproven pieces: pointing an ExternalProvider at an in-cluster Service, and adding a CA to the gateway's trust store. The token still crosses the LAN in clear text on the last hop |
| **A different first model** | Register a provider that already has public TLS on 443 | Proves MaaS end to end today; says nothing about LM Studio |

None is chosen yet. Tracked in `homelab-2026-o8y.9`.

