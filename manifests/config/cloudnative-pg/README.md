# cloudnative-pg

[CloudNativePG](https://cloudnative-pg.io/), the PostgreSQL operator. It is
shared infrastructure: it owns no database of its own and exists to serve other
components.

| | |
|---|---|
| package | `cloudnative-pg` |
| catalog | `certified-operators` |
| channel | `stable-v1` |
| install mode | AllNamespaces → `spec: {}`, **chosen** — see below |
| namespace | `cnpg-system` |

## Who depends on it

| Consumer | `Cluster` | Lives in | State |
|---|---|---|---|
| [keycloak](../keycloak) | `keycloak-db` | `keycloak` | in git, running |
| Red Hat OpenShift AI — Models-as-a-Service (`maas-api`) | not yet written | to be decided | planned, `homelab-2026-o8y.7` |
| Red Hat OpenShift AI — MLflow backend store | not yet written | to be decided | planned, `homelab-2026-o8y.10` |

**Keycloak is no longer the only reason this operator is installed.** Every
other note in this repo that explains CloudNativePG by pointing at Keycloak was
written when that was true. Removing Keycloak does not make the
`cloudnative-pg` elements in `clusters/hub/operators.yaml` and
`clusters/hub/config.yaml` removable — check this table first.

### Why Models-as-a-Service needs it

`maas-api` keeps API key metadata in PostgreSQL: hashed tokens, subscription
bindings, expiry and revocation. It will not start without it. The pod
crash-loops until it can connect and run its schema migration. Red Hat's guide
lists a PostgreSQL 14+ database *that you provide* as a prerequisite — RHOAI does
not ship one — and the DataScienceCluster status gives no hint of it until the
gateway and Connectivity Link problems in front of it are solved.

`keycloak-db` runs PostgreSQL 18, so the version this operator deploys by default
clears that bar.

- [Govern LLM access with Models-as-a-Service — 1.2 Prerequisites](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service#maas-prerequisites_maas-deploy)
- [1.5 Configure the PostgreSQL secret](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service#configure-postgresql-secret-for-maas_maas-deploy)
- Upstream: [Install MaaS components — Database setup](https://opendatahub-io.github.io/models-as-a-service/v0.2.0/install/maas-setup/)

### Why MLflow would need it

RHOAI's MLflow supports SQLite for development and PostgreSQL for anything
else. It is only a dependency if MLflow is deployed with a real backend store.

- [Working with MLflow — Install and configure MLflow](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_mlflow/installing-mlflow_mlflow)

## The database belongs to its consumer

This component is the operator's own configuration and nothing else: the
`cnpg-pull-secret` its Deployment references. A `Cluster` is declared by the
component that uses it, next to the thing that reads it — `keycloak-db` is in
[manifests/config/keycloak/base/postgres-cluster.yaml](../keycloak/base/postgres-cluster.yaml).
New consumers follow that, which is why the operator is installed AllNamespaces:
an OwnNamespace install would resolve cleanly and then never reconcile a
`Cluster` anywhere else.

## What each consumer reads

For a `Cluster` named `<name>` the operator generates a Secret `<name>-app` in
the same namespace. Keys, checked on `keycloak-db-app`:

```
dbname  host  port  user  username  password  pgpass
uri  jdbc-uri  fqdn-uri  fqdn-jdbc-uri
```

`uri` uses the short Service name and only resolves inside the Cluster's own
namespace. `fqdn-uri` is the one to use from anywhere else.

| Consumer | Wants | Fit |
|---|---|---|
| Keycloak | `username` and `password`, by reference from the Keycloak CR | direct |
| `maas-api` | Secret `maas-db-config`, key `DB_CONNECTION_URL`, in `redhat-ai-gateway-infra`, as `postgresql://…?sslmode=require` | **not direct** — different Secret name, key and namespace |
| MLflow | Secret `mlflow-db-credentials`, key `backend-store-uri`, in `redhat-ods-applications` | **not direct** — same problem |

Keycloak could take the generated Secret as it is. The two RHOAI consumers
cannot: each wants a complete connection URL under its own key name, in a
namespace the operator does not write to. Something has to build that Secret
without putting a credential in git. That is the open design question in
`homelab-2026-o8y.7`, and whatever answers it for `maas-api` should be reused
for MLflow.

- CloudNativePG: [Connecting from an application — Secrets](https://cloudnative-pg.io/docs/1.30/applications)

## Not configured

**Backups.** None of these databases has one. Ceph replication is not a backup.
`homelab-2026-4pq.22` covers scheduled backups for `keycloak-db`; each new
`Cluster` needs the same answer or a stated reason for going without. Losing the
`maas-api` database invalidates every issued API key.
