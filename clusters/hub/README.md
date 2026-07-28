# hub

The Bewley hub cluster. `apps.hub.lab.bewley.net`, OpenShift 4.22.5, platform
**BareMetal** on vSphere VMs, infra ID `hub-86sqp`.

## Nodes

| Node | Role | Notes |
|---|---|---|
| ctrl-1..3 | control plane | |
| store-1..3 | worker → storage | 150G root + **1TiB non-rotational `sdb`** for ODF |
| cnv-1, cnv-2, cnv-4 | worker → virtualization | 4 NICs: adapter 1 on the lab network is the `br-ex` uplink, adapters 2-4 on Trunk |

`cnv-3` is declared in `components/config/node-labels/overlays/hub/nodes.yaml`
but was not joined to the cluster as of 2026-07-27 (the machineset reported 7
desired / 6 ready). Its Application will report that node as missing until it
joins; that is expected and does not block the others.

NIC and MAC inventory can be regenerated at any time with
[scripts/collect-nics.sh](../../scripts/collect-nics.sh).

Nodes arrive with only `node-role.kubernetes.io/worker`; the `store` and
`virtualization` roles and the ODF storage label are applied by the
`hub-cfg-node-labels` Application.

## Apply

```bash
oc apply -k clusters/hub
```

Applied once by hand. After that `hub-root` self-manages this directory.

## What gets created

```
hub-root                       ← this directory
├── hub-olm-nmstate            ← components/olm/*
├── hub-olm-metallb
├── hub-olm-local-storage
├── hub-olm-odf
├── hub-olm-virtualization
├── hub-olm-external-secrets
├── hub-cfg-node-labels        ← components/config/*
├── hub-cfg-nmstate
├── hub-cfg-metallb
├── hub-cfg-local-storage
├── hub-cfg-odf
├── hub-cfg-virtualization
└── hub-cfg-external-secrets
```

## Expect churn on first sync

The config Applications are created at the same time as the operator ones, so
several will fail their first few attempts with `no matches for kind ...` until
the CRDs land. They retry with backoff (15s doubling to 5m, 20 attempts) and
converge on their own. This replaces the "apply again until no errors" loop in
the old runbook — no action needed unless an app is still failing after ~15
minutes.

Convergence order that matters in practice:

1. `hub-cfg-node-labels` — labels the store nodes
2. `hub-olm-local-storage` → `hub-cfg-local-storage` — publishes `local-block` PVs
3. `hub-olm-odf` → `hub-cfg-odf` — consumes them as OSDs

## Not yet enabled

- **MetalLB address pool** (`components/config/metallb/overlays/hub/`) —
  `192.168.4.200-230` avoids the known VIPs and node addresses but has not been
  checked against the router's DHCP scope. Commented out of the overlay's
  kustomization until confirmed (`homelab-2026-4pq.11`).
## Manual step after sync

**External Secrets** is deployed, but its `1password-sdk` ClusterSecretStore
stays `Ready: False` until the service-account token is created by hand — it is
the credential that unlocks every other credential, so it cannot be committed
or fetched by External Secrets itself:

```bash
oc create secret generic onepassword-connect-token \
  --namespace external-secrets \
  --from-literal=token="$(op read 'op://development/eso-service-account/token')"
```

See [its README](../../components/config/external-secrets/README.md)
(`homelab-2026-4pq.5`).

The `br-vmdata` NNCP is now enabled: an OVS bridge on `ens224` with an OVN
`bridge-mappings` entry exposing localnet `physnet-vmdata`, which is the name
to reference as `physicalNetworkName` from a CUDN or NAD.

## Follow-on work

`bd show homelab-2026-4pq` — image registry on CephFS, monitoring PVs,
OAuth/RBAC, RHACM, and a second cluster to prove the layout.
