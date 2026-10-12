# maas-models

The models that Red Hat OpenShift AI's Models-as-a-Service (MaaS) fronts on a
cluster.

Config-only, and `overlays/<cluster>` only. Which models a cluster offers, and
where they are actually served, cannot be made cluster-agnostic.

The hub has no GPU, so nothing is served in the cluster. MaaS is used for what it
is: one governed endpoint — authentication, per-subscription token limits, API
keys — in front of models running somewhere else.

Tracked as `homelab-2026-o8y.9`, part of the epic `homelab-2026-o8y`.

## The hub's first model: LM Studio on a Mac

| | |
|---|---|
| Served by | [LM Studio](https://lmstudio.ai/) on the Mac `blackout` |
| Address | `blackout.home.bewley.net:1234`, plain HTTP |
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
- **There is no TLS.** LM Studio serves plain HTTP only. See the last section.

## What is here so far

| What | Where | Why |
|---|---|---|
| `Namespace/maas-models` | `overlays/hub/namespace.yaml` | The "model namespace": a model's credential, provider, model and catalog entry must share one |
| `ExternalSecret/lmstudio-blackout-api-key` | `overlays/hub/externalsecret-lmstudio.yaml` | LM Studio's token, from 1Password |

The model registration itself — `ExternalProvider`, `ExternalModel`,
`MaaSModelRef`, and a subscription and access policy in the
`models-as-a-service` namespace — is the next change. The credential comes
first because nothing else can be tested without it.

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
`SecretSyncedError`. Nothing else is affected.

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

## The token will cross the LAN in clear text

LM Studio does not serve TLS, so the model will be registered with
`maas.opendatahub.io/tls: "false"` and `maas.opendatahub.io/port: "1234"`.
Red Hat's guide allows that and is plain about the cost: the provider
credential is then sent unencrypted, and it says to do so only on a trusted,
isolated network.

Here that means LM Studio's token travels unencrypted from the cluster nodes,
through the router, to the Mac. On a home LAN that is a reasonable trade for a
token that only unlocks a local model server — but it is a decision, not an
accident. The way to close it is a small TLS-terminating proxy on the Mac with a
`homelab-ca` certificate, at the price of another moving part on a laptop.
