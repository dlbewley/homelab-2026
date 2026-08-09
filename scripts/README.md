# scripts

Tooling for this repo, in three groups. Only the first talks to vSphere; only
the second needs a cluster; the third needs neither.

| Script | Group | Needs |
|---|---|---|
| [`create-vm.sh`](create-vm.sh) | day 0 — provision | `govc` + vSphere |
| [`create-cluster-vms.sh`](create-cluster-vms.sh) | day 0 — provision | `govc` + vSphere |
| [`attach-iso-boot.sh`](attach-iso-boot.sh) | day 0 — provision | `govc` + vSphere |
| [`collect-nics.sh`](collect-nics.sh) | day 0 — inventory | `govc` + vSphere + `jq` |
| [`verify-channels.sh`](verify-channels.sh) | day 2 — cluster validation | logged-in `oc` + `jq` |
| [`create-keycloak-realm-secrets.sh`](create-keycloak-realm-secrets.sh) | day 2 — secret bootstrap | `op` + `jq` |
| [`create-github-oauth-secret.sh`](create-github-oauth-secret.sh) | day 2 — secret bootstrap | `op` + `jq` |
| [`export-homelab-ca.sh`](export-homelab-ca.sh) | day 2 — secret bootstrap | logged-in `oc` + `op` + `jq` + `openssl` |
| [`validate.sh`](validate.sh) | repo validation | `kustomize` (or `oc`/`kubectl`) |

That last distinction decides what CI can enforce. `validate.sh` needs nothing
but the repo, so [CI runs it on every PR](../.github/workflows/validate.yaml).
`verify-channels.sh` needs a live catalog and stays a manual gate — GitHub
runners have no route to the homelab cluster.

---

# Day 0 — provisioning

`govc`-based scripts for building vSphere VMs that are later installed as if
they were bare metal. They only create hardware — no guest OS or cluster
install.

## Requirements

- [`govc`](https://github.com/vmware/govmomi/tree/main/govc)
- `GOVC_URL`, `GOVC_USERNAME`, `GOVC_PASSWORD` exported in the environment
  (see [`../setup_env.sh`](../setup_env.sh))
- `jq`, for `collect-nics.sh`

Every script here takes `--dry-run` (or `-o -`). Use it first.

## `create-vm.sh` — single-VM primitive

Creates one VM: RHEL9/EFI, pvscsi, vmxnet3, an OS disk on a **shared** datastore
and an optional data disk on a **unique** per-VM datastore. Everything (CPU,
memory, NICs, firmware, disks, datastores, nested virtualization) is a flag, so
other VM types reuse it.

```bash
# store node: OS on shared VMData, 1 TB OSD disk on the EVO-1 SSD
./create-vm.sh --name bm-store-1 --primary-ds VMData --secondary-ds EVO-1
```

```bash
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

## `create-cluster-vms.sh` — cluster wrapper

Provisions a full set of nodes by calling `create-vm.sh` per VM. Counts, name
prefixes, datastores, sizes and per-role networks live in a `CONFIG` block at
the top of the file.

| Role | Prefix | Qty | CPU | RAM | NICs | Extra |
|------|--------|-----|-----|-----|------|-------|
| control plane | `bm-ctrl` | 3 | 12 | 32 GB | 1 | — |
| CNV | `bm-cnv` | 4 | 16 | 48 GB | 4 | nested virt + vPMC + CPU hot-add |
| store | `bm-store` | 3 | 16 | 34 GB | 2 | 1 TB data disk on a unique EVO SSD |

Common to all: 150 GB root disk on the shared datastore, RHEL9 guest, HW version
19, created powered-off.

```bash
./create-cluster-vms.sh --dry-run       # print every govc command, change nothing
```

```bash
ONLY=store ./create-cluster-vms.sh      # limit to one role: ctrl | cnv | store
```

`./create-cluster-vms.sh` creates all VMs powered off; add `--power-on` to start
them.

**Networking model:** every node's first NIC is on `PRIMARY_NET`
(`lab-192-168-4-0-b24`), the network all nodes share; any additional NICs are on
`TRUNK_NET` (`Trunk`). Per-role NIC counts are `CTRL_NICS` / `CNV_NICS` /
`STORE_NICS`. Override the networks via the `PRIMARY_NET` / `TRUNK_NET` env vars.

**Review before a real run:** `FOLDER` defaults to `/Garden/vm`; set it to a
per-cluster folder if desired. It must already exist — `govc` will not create it.

## `attach-iso-boot.sh` — boot VMs from a discovery ISO

Attaches an ISO (typically the assisted-installer `discovery.iso`) to a set of
VMs and boots them from it. Per VM it ensures a CD-ROM exists, inserts the ISO
and marks it connect-at-power-on, sets the EFI boot order to `cdrom,disk`, then
powers on — or resets, if already running.

Idempotent: re-running reuses the existing CD-ROM and just re-inserts and
reboots.

```bash
./attach-iso-boot.sh --dry-run                    # print govc commands, change nothing
```

```bash
./attach-iso-boot.sh                              # every VM in the default folder
```

```bash
./attach-iso-boot.sh bm-ctrl-1 bm-ctrl-2          # only these VMs
```

Defaults, each overridable by flag or env: ISO `ISO/discovery.iso` on datastore
`VMData`, folder `/Garden/vm/bm-hub`, controller `ide-200`, boot order
`cdrom,disk`. `--no-power` attaches without powering on.

## `collect-nics.sh` — NIC and MAC inventory

Writes each VM's NICs — adapter, network, MAC, and IP where known — to YAML.
MAC and network come from VM hardware so they are always present; the IP comes
from VMware Tools and is absent unless the guest is running Tools and has an
IPv4 address. A missing IP is normal, not an error.

```bash
./collect-nics.sh -o -                            # YAML to stdout
```

```bash
./collect-nics.sh --folder /Garden/vm/bm-hub -o bm-hub-nics.yaml
```

This is where the NIC facts in
[`manifests/config/nmstate/overlays/hub/`](../manifests/config/nmstate/overlays/hub/)
come from — which physical adapter is the `br-ex` uplink and which are spare
Trunk NICs. Regenerate it before changing a `NodeNetworkConfigurationPolicy`:
pointing a bridge at the wrong NIC will cut the node off the network.

Output is not committed. Generate it when you need it.

---

# Day 2 — cluster validation

## `verify-channels.sh`

Checks every `manifests/olm/*` component against the connected cluster's
catalog, in two passes:

1. the pinned channel in `subscription.yaml` vs the catalog's default channel
2. the OperatorGroup shape vs the install modes the operator supports **on the
   channel that `subscription.yaml` pins**

```bash
./verify-channels.sh
```

Pass 2 exists because an OperatorGroup asking for a mode the operator does not
support fails at resolution time with a message that names the mode but not the
fix:

```
OwnNamespace InstallModeType not supported, cannot configure to watch own namespace
```

`targetNamespaces` requests OwnNamespace — or SingleNamespace, if it targets a
namespace other than its own; an empty `spec: {}` requests AllNamespaces.

Install modes are read from the **pinned** channel, not the default and not the
first listed. Channels genuinely disagree — `kubearmor-operator-certified`
offers `AllNamespaces` on `alpha` but only `OwnNamespace,SingleNamespace` on
`stable` — so reading the wrong one can report a false `ok`.

Exit 1 on any problem. Statuses: `DRIFT`, `UNSUPPORTED`, `CHANNEL NOT FOUND`,
`NOT IN CATALOG`. Re-run after a cluster upgrade and whenever a component is
added.

Needs a logged-in `oc` and `jq`.

---

# Day 2 — secret bootstrap

## `create-keycloak-realm-secrets.sh`

Creates the 1Password item backing the homelab Keycloak realm — one field per
secret the `ExternalSecret` in
[`manifests/config/keycloak/overlays/hub`](../manifests/config/keycloak/overlays/hub)
pulls.

```bash
./create-keycloak-realm-secrets.sh --dry-run
```

```bash
./create-keycloak-realm-secrets.sh
```

Refuses to overwrite an existing item, and prints the `op item edit` form for
rotating a single field.

**Why this exists rather than a plain `op item create`.** Assignment statements
take *literal* values, so

```bash
op item create ... 'dev1-password[password]=generate'
```

sets the password to the string `generate` — for every field, with no error.
`--generate-password` does generate a value, but only for an item's single
built-in password field, not custom ones. `op item create --help` also warns
that assignment values are recorded in shell history and visible to other
processes. This script pipes a JSON template on stdin and builds values with a
shell builtin, so no secret becomes a process argument.

`--dry-run` writes JSON to stdout with values masked, and its commentary to
stderr, so it can be piped:

```bash
./create-keycloak-realm-secrets.sh --dry-run | jq -r '.fields[].label'
```

## `create-github-oauth-secret.sh`

Stores a GitHub OAuth App's client ID and secret in 1Password for the `github`
identity provider.

```bash
./create-github-oauth-secret.sh --client-id <id> --dry-run
```

```bash
./create-github-oauth-secret.sh --client-id <id>
```

The mirror image of the script above: that one **generates** values, this one
**stores** values GitHub gave you. The shared constraint is that neither may put
a secret in a process argument, so the secret is read from a hidden prompt and
reaches `op` over a pipe rather than as an assignment statement.

Refuses to overwrite an existing item, and prints the `op item edit` form plus
the annotation to force the ExternalSecret to re-read after a rotation.

## `export-homelab-ca.sh`

Exports the existing homelab root CA from a cluster into 1Password, so every
cluster shares one root instead of generating its own.

```bash
./export-homelab-ca.sh --dry-run
```

```bash
./export-homelab-ca.sh
```

**Run once, before merging the change that switches cert-manager to the
ExternalSecret.** After that the ExternalSecret is the only source of the CA —
if 1Password does not already hold it, cert-manager has nothing to issue from.

Exports the *existing* root rather than generating a new one, so anything
already trusting `Bewley Homelab CA` keeps working.

Refuses to overwrite an existing item, since that would be a CA rotation rather
than an export. Before publishing it checks `basicConstraints CA:TRUE` and that
the private key matches the certificate — a mismatched pair distributed to every
cluster is a failure worth catching locally. The key is never printed and never
becomes a process argument.

---

# Repo validation

## `validate.sh`

Everything that can be checked without a cluster. [CI runs this same
script](../.github/workflows/validate.yaml), so a green local run means a green
CI run.

```bash
./validate.sh
```

1. **every directory containing a `kustomization.yaml` builds**
2. **no manifest is present-but-unreferenced**

Check 2 exists because kustomize renders an unreferenced file as *nothing at
all* and exits 0. A manifest you believe is deployed but silently is not looks
identical to a healthy one in ArgoCD.

Deliberate exceptions live in [`allowed-orphans.txt`](allowed-orphans.txt), one
path per line with a reason and the issue that retires it. An `ORPHAN` is
therefore always one of three things: a file to wire into its
`kustomization.yaml`, a file to delete, or an exception to record.

Uses `kustomize` if installed, else `oc`, else `kubectl`. CI pins kustomize so
an upstream release cannot change what this repo renders without a reviewable
commit.

### What it does not cover

Server-side apply dry-run, which is what catches CRD schema errors — a field
valid in one operator release and removed in the next. It needs a live cluster,
so run it by hand before trusting a change to operator CRs:

```bash
oc kustomize manifests/config/odf/overlays/hub | oc apply --server-side --dry-run=server -f -
```
