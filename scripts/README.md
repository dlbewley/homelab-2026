# VM provisioning scripts

`govc`-based scripts for building vSphere VMs that are later installed as if they
were bare metal (e.g. an OpenShift cluster). They only create hardware — no guest
OS or cluster install.

## Requirements

- [`govc`](https://github.com/vmware/govmomi/tree/main/govc)
- `GOVC_URL`, `GOVC_USERNAME`, `GOVC_PASSWORD` exported in the environment
  (see `../setup_env.sh`)

## Scripts

### `create-vm.sh` — single-VM primitive

Creates one VM, modeled on the `hub-4k77l-*` nodes: RHEL9/EFI, pvscsi, vmxnet3,
an OS disk on a **shared** datastore and an optional data disk on a **unique**
per-VM datastore. Everything (CPU, memory, NICs, firmware, disks, datastores,
nested virtualization) is a flag so other VM types reuse it.

```bash
# store node: OS on shared VMData, 1 TB OSD disk on the EVO-1 SSD
./create-vm.sh --name bm-store-1 --primary-ds VMData --secondary-ds EVO-1

# nested-virt (CNV) node: expose VT-x to the guest, 16c/48G, two NICs, HW v19
./create-vm.sh --name bm-cnv-1 --cpu 16 --memory 49152 \
    --nested --vpmc --cpu-hot-add --hw-version 19 \
    --network lab-192-168-4-0-b24 --network Trunk --no-secondary
```

Run `./create-vm.sh --help` for the full flag list. Key flags:

| Flag | Purpose |
|------|---------|
| `--cpu` / `--memory` / `--cores-per-socket` | CPU & RAM |
| `--network` (repeatable) / `--nic-adapter` | NICs; first is the primary adapter |
| `--primary-ds` / `--primary-size` | OS disk (shared datastore) |
| `--secondary-ds` / `--secondary-size` / `--no-secondary` | data disk (unique datastore) |
| `--nested` / `--vpmc` / `--cpu-hot-add` / `--mem-hot-add` | nested virtualization & hot-add |
| `--hw-version` / `--firmware` / `--guest-id` | VM hardware version, firmware, guest id |
| `--power-on` / `--dry-run` | power on after create / print commands only |

### `create-cluster-vms.sh` — cluster wrapper

Provisions a full set of nodes by calling `create-vm.sh` per VM. Counts,
name prefixes, datastores, sizes and per-role networks live in a `CONFIG`
block at the top of the file.

| Role | Prefix | Qty | CPU | RAM | NICs | Extra |
|------|--------|-----|-----|-----|------|-------|
| control plane | `bm-ctrl` | 3 | 12 | 32 GB | 1 | — |
| CNV | `bm-cnv` | 4 | 16 | 48 GB | 4 | nested virt + vPMC + CPU hot-add |
| store | `bm-store` | 3 | 12 | 32 GB | 2 | 1 TB data disk on a unique EVO SSD |

Common to all: 150 GB root disk on the shared datastore, RHEL9 guest, HW version
19, created powered-off.

```bash
./create-cluster-vms.sh --dry-run       # print every govc command, change nothing
./create-cluster-vms.sh                  # create all VMs (powered off)
./create-cluster-vms.sh --power-on       # create and power on
ONLY=store ./create-cluster-vms.sh       # limit to one role: ctrl | cnv | store
```

**Networking model:** every node's first NIC is on `PRIMARY_NET`
(`lab-192-168-4-0-b24`), the network all nodes share; any additional NICs are on
`TRUNK_NET` (`Trunk`). Per-role NIC counts are `CTRL_NICS` / `CNV_NICS` /
`STORE_NICS`. Override the networks via the `PRIMARY_NET` / `TRUNK_NET` env vars.

**Review before a real run:**

- **Folder** — defaults to `/Garden/vm`; set `FOLDER` to a per-cluster folder if
  desired (it must already exist — `govc` will not create it).
