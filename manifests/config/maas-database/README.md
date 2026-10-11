# maas-database

PostgreSQL for Red Hat OpenShift AI's `maas-api`, and the Secret that connects
the two.

Config-only: the operator is [cloudnative-pg](../cloudnative-pg), which this is
the second consumer of.

## Why it is here

`maas-api` stores API key metadata in PostgreSQL — hashed tokens, subscription
bindings, expiry, revocation. It will not start without it: the pod crash-loops
until it can connect and run its schema migration.

RHOAI does not provide the database. Red Hat's guide lists PostgreSQL 14 or
later, supplied by you, as a
[prerequisite](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service#maas-prerequisites_maas-deploy),
and the DataScienceCluster status on this hub gave no hint of it while the
missing gateway was still the reported problem.

Tracked as `homelab-2026-o8y.7`, part of the epic `homelab-2026-o8y`.

## Pieces

| What | Namespace | Why |
|---|---|---|
| `Namespace/maas-db` | — | Owned by this repo, so the data outlives MaaS being switched off |
| `Cluster/maas-db` | `maas-db` | 2 instances, 2Gi each, database `maas`, owner `maas` |
| `ServiceAccount`, `Role`, `RoleBinding` `maas-db-reader` | `maas-db` | May `get` one Secret, `maas-db-app` |
| `ClusterSecretStore/maas-db` | — | Reads that Secret; usable only from `redhat-ai-gateway-infra` |
| `Namespace/redhat-ai-gateway-infra` | — | RHOAI's; declared so the Secret can exist before MaaS is enabled |
| `ExternalSecret/maas-db-config` | `redhat-ai-gateway-infra` | Writes the Secret `maas-api` reads |

## How the credential gets there

```
CloudNativePG ──writes──▶ maas-db/maas-db-app
                            keys: uri, fqdn-uri, username, password, …
                                 │
        ClusterSecretStore/maas-db reads it as ServiceAccount maas-db-reader
                                 │
ExternalSecret/maas-db-config ◀──┘
        │ templates  "{{ fqdn-uri }}?sslmode=require"
        ▼
redhat-ai-gateway-infra/maas-db-config
   key: DB_CONNECTION_URL          ◀── maas-api reads this
```

**No credential is written in this repo, and none is kept in 1Password.**
CloudNativePG generates the password; External Secrets copies it across the
namespace boundary in the shape `maas-api` wants. Every other secret here comes
from 1Password; this one does not need to, because nothing outside the cluster
ever has to know it.

`maas-api` cannot use the generated Secret directly. It wants a single key,
`DB_CONNECTION_URL`, in a Secret named `maas-db-config`, in its own namespace
([Red Hat's guide, 1.5](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service#configure-postgresql-secret-for-maas_maas-deploy)).

Details that matter:

- **`fqdn-uri`, not `uri`.** `uri` uses the short Service name `maas-db-rw`,
  which resolves only inside `maas-db`.
- **`?sslmode=require`** is appended to match the form Red Hat's guide gives. It
  encrypts without verifying the server certificate, which CloudNativePG signs
  with its own CA.
- **The store is restricted.** A `ClusterSecretStore` can be referenced from any
  namespace and this one opens a database password, so its `conditions` allow
  only `redhat-ai-gateway-infra`.

The store is built the same way as the cluster pull-secret store in
[external-secrets](../external-secrets): identity and RBAC next to the Secret
they read.

## Two namespaces, on purpose

The database is **not** in `redhat-ai-gateway-infra`, where `maas-api` runs.
That namespace belongs to RHOAI. When the hand-installed RHOAI was removed from
this hub the operator deleted it, and a database inside it would have gone too
— along with every issued API key. `maas-db` is this repo's, so Models-as-a-
Service can be disabled, reinstalled or upgraded without losing them.

`redhat-ai-gateway-infra` is still declared here, name only, with
`Prune=false,Delete=false`. The maas-controller creates it when MaaS is enabled;
declaring it lets the Secret be in place first. Red Hat's guide says that when
the Secret exists before MaaS is enabled `maas-api` starts cleanly, and
otherwise it must be restarted.

**Not yet confirmed:** that the controller is content with a namespace it did
not create. Its log line on an existing one is `managed namespace already
exists`, which suggests it is. If MaaS misbehaves over this, remove the
Namespace from `connection-secret.yaml`; the ExternalSecret will then fail and
retry until the controller has made the namespace, and `maas-api` will need one
restart.

## Order

Within the Application, by sync wave:

```
0  Namespace/maas-db
1  Cluster/maas-db, ServiceAccount, Role, RoleBinding
2  ClusterSecretStore/maas-db
3  Namespace/redhat-ai-gateway-infra
4  ExternalSecret/maas-db-config     needs maas-db-app, which CloudNativePG
                                     writes once the Cluster has bootstrapped
```

The ExternalSecret reports an error for the first minute or so, until
`maas-db-app` exists. It converges on its own.

This component does not depend on RHOAI being configured. It can and should land
before the DataScienceCluster enables Models-as-a-Service.

## Verifying

```bash
oc get cluster.postgresql.cnpg.io -n maas-db
```

Wait for `Cluster in healthy state` with 2 ready instances.

```bash
oc get clustersecretstore maas-db
```

```bash
oc get externalsecret maas-db-config -n redhat-ai-gateway-infra
```

Both should be `Ready`. Then confirm the key is there, without printing it:

```bash
oc get secret maas-db-config -n redhat-ai-gateway-infra -o jsonpath='{.data}' | jq 'keys'
```

Once MaaS is enabled:

```bash
oc get deployment maas-api -n redhat-ai-gateway-infra
```

```bash
oc get maastenantconfig default-tenant -n models-as-a-service -o jsonpath='{.status.infraNamespace}{"\n"}'
```

The second should print `redhat-ai-gateway-infra`. If it prints anything else,
the ExternalSecret and the store's `conditions` are aimed at the wrong
namespace.

## If the password changes

CloudNativePG does not rotate it on its own. If it is rotated, External Secrets
picks the new value up within the hour, but RHOAI's controller does not push
later changes into the running pod:

```bash
oc rollout restart deployment/maas-api -n redhat-ai-gateway-infra
```

## Not configured

**Backups.** None. Ceph replication is not a backup. Losing this database
invalidates every issued API key; they can be re-issued, which is why this is a
known gap rather than a blocker. `homelab-2026-4pq.22` covers scheduled backups
for `keycloak-db`, and whatever it settles on should be applied here too.

**NetworkPolicy.** `maas-db` has none, so any pod in the cluster can reach
port 5432; the password is the control. If RHOAI turns out to restrict egress
from `redhat-ai-gateway-infra`, that is where a failed connection would come
from.

## References

- CloudNativePG: [Connecting from an application — Secrets](https://cloudnative-pg.io/docs/1.30/applications)
- Upstream MaaS: [Install MaaS components — Database setup](https://opendatahub-io.github.io/models-as-a-service/v0.2.0/install/maas-setup/)
- Upstream MaaS: [Upgrade to 3.5 — Database credential management](https://opendatahub-io.github.io/models-as-a-service/latest/migration/upgrade-to-3.5/)
