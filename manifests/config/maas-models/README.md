# maas-models

The models that Red Hat OpenShift AI's Models-as-a-Service (MaaS) fronts on a
cluster.

Config-only, and `overlays/<cluster>` only. Which models a cluster offers, and
where they are actually served, cannot be made cluster-agnostic.

The hub has no GPU, so nothing is served in the cluster. MaaS is used for what it
is: one governed endpoint — authentication, per-subscription token limits, API
keys — in front of models running somewhere else.

Tracked as `homelab-2026-o8y.9`, part of the epic `homelab-2026-o8y`.

## Models

| Model | Served by | State |
|---|---|---|
| `claude-haiku-5-5` | Anthropic's API | **Working**, verified end to end on 2026-10-12 — without streaming |
| `qwen2.5-7b-instruct` | LM Studio on a Mac on the LAN | **Registered, not reachable.** RHOAI 3.5.1 requires TLS on 443 with a public certificate; LM Studio offers plain HTTP on 1234. See [What RHOAI 3.5.1 requires of an external model](#what-rhoai-351-requires-of-an-external-model) |

Do not trust the status fields for the second. Its `MaaSModelRef` reports
`RuntimeReady: Backend is healthy` while the gateway is being refused on port 443.

## Pieces

| What | Namespace | Why |
|---|---|---|
| `Namespace/maas-models` | — | The "model namespace": a model's credential, provider, model and catalog entry must share one |
| `MaaSAuthPolicy/homelab-admins` | `models-as-a-service` | Who may use the models: the `cluster-admins` group |
| `MaaSSubscription/homelab-admins` | `models-as-a-service` | The token budgets, one per model |
| `ConfigMap/payload-processing-plugins` | `openshift-ingress` | Turns on response translation in the gateway, for Anthropic. RHOAI's object; one key patched |
| `ExternalSecret/anthropic-api-key` | `maas-models` | Anthropic API key, from 1Password |
| `ExternalProvider/anthropic` | `maas-models` | `api.anthropic.com` |
| `ExternalModel`, `MaaSModelRef` `claude-haiku-5-5` | `maas-models` | The model and its catalog entry |
| `ExternalSecret/lmstudio-blackout-api-key` | `maas-models` | LM Studio's token, from 1Password |
| `ExternalProvider/lmstudio-blackout` | `maas-models` | `blackout.home.bewley.net` |
| `ExternalModel`, `MaaSModelRef` `qwen2-5-7b-instruct` | `maas-models` | The model and its catalog entry |

From each provider and model MaaS generates the plumbing itself — an ExternalName
Service, an Istio ServiceEntry and DestinationRule, and an HTTPRoute on the MaaS
gateway. They are not in git and should not be.

## Access and quota

MaaS denies by default, so both of these are required. They live in
`models-as-a-service`, RHOAI's tenant namespace, not beside the models.

- **`MaaSAuthPolicy/homelab-admins`** grants every model here to the
  `cluster-admins` group, the one populated group on the hub. To open them to
  anyone who can log in, add `system:authenticated` — remembering that one of
  them costs money per token. Keycloak's groups are not synced into OpenShift,
  so they cannot be named yet.
- **`MaaSSubscription/homelab-admins`** is what an API key is issued against,
  and carries a token budget per model.

One policy and one subscription for the group, listing every model, rather than
a pair per model: one API key then works for all of the group's models, and two
subscriptions for the same group at the same priority would leave MaaS guessing
which applies.

| Model | Budget | What the limit is for |
|---|---|---|
| `claude-haiku-5-5` | 200,000 tokens / hour | **The spending cap on the Anthropic key.** At list price when this was written ($0.10 per million input tokens, $0.50 output, for prompts up to 100K tokens) that cannot exceed about ten cents an hour, under $2.50 a day flat out. [Check current prices](https://www.anthropic.com/pricing) before raising it |
| `qwen2.5-7b-instruct` | 200,000 tokens / hour | Stops a runaway loop from pinning the laptop. Costs nothing per token |

Exceeding a budget returns `429` until the window rolls over.

## Claude Haiku 5.5 on Anthropic

The kind of provider RHOAI 3.5.1 is built for: public TLS on 443, public CA.

```
client ── MaaS API key ──▶ https://maas.apps.hub.lab.bewley.net
                                 │  gateway: Authorino checks the key and the
                                 │  group; Limitador counts tokens
                                 ▼
                           payload processor: reads "model", picks the
                           provider, swaps the client's key for Anthropic's
                           (as x-api-key), translates OpenAI ⇄ Messages
                                 │  TLS, port 443
                                 ▼
                           api.anthropic.com/v1/messages
```

Clients can speak either dialect:

| Client sends | To | What MaaS does |
|---|---|---|
| OpenAI Chat Completions | `/v1/chat/completions` | Translates the request to Anthropic's Messages format and the response back |
| Anthropic Messages | `/v1/messages` | Passes it through |

### What was verified, and what does not work

Tested through `https://maas.apps.hub.lab.bewley.net` on 2026-10-12 with a
short-lived MaaS API key:

| Request | Result |
|---|---|
| Catalog, `GET /v1/models` | Lists the model |
| OpenAI format, `POST /v1/chat/completions` | `200`, an OpenAI-shaped `chat.completion` with `usage` |
| Tool calling, OpenAI format | `200`, `finish_reason: tool_calls` with a well-formed `tool_calls` entry |
| Anthropic format, `POST /v1/messages` | `200`, passed through unchanged |
| OpenAI format without `max_tokens` | `200`; the translator supplies one |
| With `temperature: 0.2` | `400`, "`temperature` is deprecated for this model" |
| A revoked API key | `403` |
| **OpenAI format, `stream: true`** | `200`, but **not a stream**: one complete `chat.completion` JSON body, delivered at the end, under `content-type: text/event-stream` |
| **Anthropic format, `stream: true`** | **`400`** from Anthropic: `stream_options: Extra inputs are not permitted` |

**Do not ask this model for a stream.** Neither dialect streams correctly on
RHOAI 3.5.1:

- In OpenAI format the response translator collects Anthropic's stream and
  returns a single JSON object, still labelled as an event stream. A client that
  parses server-sent events gets nothing it recognises.
- In Anthropic format the gateway's `stream-usage-enforcer` plugin adds
  OpenAI's `stream_options` to every streamed request so it can meter tokens,
  and Anthropic's API rejects the field.

Turning response translation back off does not help: an OpenAI-style client
would then receive Anthropic's stream events untranslated. Tracked as
`homelab-2026-o8y.13`.

Other things an OpenAI-style client needs to know:

- **Do not send `temperature`, `top_p` or `top_k`.** Haiku 5.5 rejects any
  non-default sampling value, and many OpenAI clients send `temperature` unasked.
- `frequency_penalty`, `presence_penalty`, `logprobs`, `n`, `response_format` and
  `seed` are dropped silently by the translator; Anthropic has no equivalent.

### The name clients use is the resource name

On RHOAI 3.5.1 the catalog lists a model by `metadata.name` of its
`ExternalModel` / `MaaSModelRef`, and the gateway routes on that — not on
`spec.modelName`. For Haiku all the names are the same, so it does not matter.
For the LM Studio model they differ, and a request for the `modelName`
(`qwen2.5-7b-instruct`) returned `404`; the catalog ID is `qwen2-5-7b-instruct`.
A resource name cannot contain a dot, so pick model names accordingly.

The model ID `claude-haiku-5-5` is Anthropic's own and is complete as written.
A newer Haiku is a new ID, so moving to it is a change to
`overlays/hub/anthropic-haiku.yaml`.

- [Anthropic models](https://docs.anthropic.com/en/docs/about-claude/models), [Messages API](https://docs.anthropic.com/en/api/messages)
- Upstream: [Anthropic as an external provider](https://github.com/opendatahub-io/ai-gateway-payload-processing/blob/main/docs/providers/anthropic.md)

### Response translation has to be switched on

RHOAI's payload processor translates OpenAI requests to Messages format out of
the box, but translating the **answer back** is a separate plugin step that
ships switched off, so that streamed responses from OpenAI-compatible models are
not held up by a response processor. With it off, an OpenAI-style client asking
for `claude-haiku-5-5` gets an Anthropic-shaped answer it cannot parse.

`overlays/hub/payload-processing-plugins.yaml` turns it on. The only change from
what RHOAI generates:

```yaml
        response: []            # RHOAI's default
        response:               # here
        - pluginRef: api-translation
```

The ConfigMap is RHOAI's. RHOAI creates it, stamps it
`opendatahub.io/managed: "false"`, and from then on leaves edits alone, which
makes this the intended way to change it. Server-side apply owns just that one
key. Two consequences:

- **An RHOAI upgrade will not update it either.** After upgrading, compare this
  content with what a fresh install generates and carry the one edit across.
- **The payload processor reads it only at start-up.** After changing it:

```bash
oc rollout restart deployment/payload-processing -n openshift-ingress
```

## qwen2.5-7b-instruct on LM Studio

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

### How a request would travel

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

Three names are in play:

| | Value | Who uses it |
|---|---|---|
| `metadata.name` | `qwen2-5-7b-instruct` | MaaS clients, in the `model` field of a request. The catalog ID |
| `modelName` | `qwen2.5-7b-instruct` | Nobody, on this build; asking for it returned `404` |
| `targetModel` | `qwen2.5-7b-instruct-1m` | LM Studio. Its exact model key, which has a `-1m` suffix |

If LM Studio's key for the model changes — a different quantisation, a
re-download — `targetModel` has to follow. `lms ls` or `GET /v1/models` shows it.

### The LM Studio credential

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

## Credentials have to be in the `eso` vault

The `1password-sdk` store reads exactly one vault, `eso`, and the cluster's
1Password service account can see only that vault. That is deliberate: the
cluster should be able to read the secrets meant for it and nothing else.

| Secret | 1Password reference | ExternalSecret key |
|---|---|---|
| Anthropic API key | `op://eso/Anthropic/rhoai` | `Anthropic/rhoai` |
| LM Studio token | `op://eso/LM Studio/tokens/blackout` | `LM Studio/tokens/blackout` |

The key is the reference without the vault: `<item>/<field>`, or
`<item>/<section>/<field>` when the field is in a section. Both forms resolve
through this store.

An item saved in any other vault is invisible to the cluster and its
ExternalSecret reports `SecretSyncedError`. The LM Studio token started out in
`development` and had to be moved:

```bash
op item move "LM Studio" --current-vault development --destination-vault eso
```

Granting the service account another vault instead would work but is the wrong
trade: `development` holds the service account's own token, among other things.

### Verifying the credentials

```bash
oc get externalsecret -n maas-models
```

Both should be `READY` `True`, `STATUS` `SecretSynced`. Then check the shape
without printing a value:

```bash
oc get secret anthropic-api-key lmstudio-blackout-api-key -n maas-models -o json | jq '.items[] | {name: .metadata.name, keys: (.data | keys), label: .metadata.labels["inference.llm-d.ai/ipp-managed"]}'
```

To rotate either credential, change it at its source (the Anthropic Console, or
LM Studio's server settings), update the 1Password item, and External Secrets
picks it up within the hour.

## Verifying the models

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
the `homelab-admins` subscription or through `/v1/api-keys`:

```bash
curl -s https://maas.apps.hub.lab.bewley.net/v1/chat/completions \
  -H "Authorization: Bearer $MAAS_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"claude-haiku-5-5","max_tokens":64,"messages":[{"role":"user","content":"Say hello"}]}' | jq
```

To get a key from the command line, as a member of `cluster-admins`:

```bash
curl -s -X POST https://maas.apps.hub.lab.bewley.net/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
  -d '{"name":"my-key","expiresIn":"30d","subscription":"homelab-admins"}' | jq -r .key
```

The key is shown once. `DELETE /maas-api/v1/api-keys/<id>` revokes it.

The reply should be OpenAI-shaped (`choices[0].message.content`). If it is
Anthropic-shaped (`content[0].text`, `stop_reason`), response translation is not
in effect: check the ConfigMap and restart the payload processor.

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

