# hub

The Bewley hub cluster. `apps.hub.lab.bewley.net`, OpenShift 4.22.5, platform
**BareMetal** on vSphere VMs, infra ID `hub-86sqp`.

## Nodes

| Node | Role | Notes |
|---|---|---|
| ctrl-1..3 | control plane | |
| store-1..3 | worker → storage | 150G root + **1TiB non-rotational `sdb`** for ODF |
| cnv-1, cnv-2, cnv-4 | worker → virtualization | 4 NICs: adapter 1 on the lab network is the `br-ex` uplink, adapters 2-4 on Trunk |

A `cnv-3` VM exists but is not currently joined — the machineset reports 7
desired / 6 ready. Add it to
`components/config/node-labels/overlays/hub/nodes.yaml` when it joins.

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
├── hub-cfg-node-labels        ← components/config/*
├── hub-cfg-nmstate
├── hub-cfg-metallb
├── hub-cfg-local-storage
├── hub-cfg-odf
└── hub-cfg-virtualization
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

Two resources are written but commented out of their kustomizations because I
could not verify the values against the cluster:

- **`br-vmdata` NNCP** (`components/config/nmstate/overlays/hub/`) — targets
  `ens161`, a spare down Trunk NIC. Interface names were only checked on cnv-1.
  Pointing this at the wrong NIC will cut a node off the network.
- **MetalLB address pool** (`components/config/metallb/overlays/hub/`) —
  `192.168.4.200-230` avoids the known VIPs and node addresses but has not been
  checked against the router's DHCP scope.

## Follow-on work

`bd show homelab-2026-4pq` — image registry on CephFS, default StorageClass,
monitoring PVs, OAuth/RBAC, External Secrets + 1Password, RHACM.
