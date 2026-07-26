#!/usr/bin/env bash
#
# create-vm.sh — Create a vSphere VM with govc, modeled on the hub-4k77l-store-* nodes.
#
# The store nodes have two disks with different placement goals:
#   * primary / OS disk  -> a SHARED datastore (the cluster's general pool)
#   * secondary / data   -> a UNIQUE per-VM datastore (a dedicated local SSD, e.g. EVO-1)
#
# Everything is parametrized so other VM types can reuse this by varying CPU,
# memory, networking, firmware, disks and datastores. Defaults reproduce a
# store node.
#
# Requires: govc, and GOVC_URL / GOVC_USERNAME / GOVC_PASSWORD in the environment.
#
# Examples
# --------
#   # One store-style node (OS on shared VMData, OSD on the EVO-1 SSD):
#   ./create-vm.sh --name mystore-1 --primary-ds VMData --secondary-ds EVO-1
#
#   # A compute node: more CPU, no second disk, different network, no OSD:
#   ./create-vm.sh --name compute-1 --cpu 16 --memory 65536 \
#       --network lab-192-168-5-0-b24 --primary-ds VMData --no-secondary
#
#   # Multiple NICs (repeat --network); first is the primary adapter:
#   ./create-vm.sh --name router-1 --network Trunk --network Management
#
#   # A CNV / nested-virt node (like hub-4k77l-cnv-*): expose VT-x to the guest,
#   # 16 vCPU / 48 GB, two NICs, single OS disk, HW v19:
#   ./create-vm.sh --name cnv-1 --cpu 16 --memory 49152 \
#       --nested --vpmc --cpu-hot-add --hw-version 19 \
#       --network lab-192-168-4-0-b24 --network Trunk \
#       --primary-ds VMData --no-secondary
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults — a hub-4k77l-store-* node
# ---------------------------------------------------------------------------
NAME=""
CPU=12
CORES_PER_SOCKET=1          # store nodes use 1; only applied when != 1 (best effort)
MEMORY_MB=32768             # 32 GB
GUEST_ID="rhel9_64Guest"
FIRMWARE="efi"              # bios | efi
HW_VERSION=""               # ESXi hardware version, e.g. 19 (max on vCenter 7.0.3); empty = host default
SCSI="pvscsi"               # disk controller type
NIC_ADAPTER="vmxnet3"
NETWORKS=()                 # collected via repeated --network; defaults below

# Nested-virtualization / CPU capability toggles (the hub-4k77l-cnv-* nodes set
# all three). These expose hardware-assisted virtualization to the guest so it
# can itself run VMs (OpenShift Virtualization / KubeVirt).
NESTED_HV=0                 # nestedHVEnabled  — expose VT-x/AMD-V to the guest
VPMC=0                      # vPMCEnabled      — virtual CPU performance counters
CPU_HOT_ADD=0              # cpuHotAddEnabled
MEM_HOT_ADD=0              # memoryHotAddEnabled

PRIMARY_DS="VMData"         # SHARED datastore — holds VM home + OS disk
PRIMARY_SIZE="120GB"

WANT_SECONDARY=1
SECONDARY_DS="EVO-1"        # UNIQUE per-VM datastore — dedicated SSD for the data disk
SECONDARY_SIZE="1024GB"     # 1 TB
SECONDARY_NAME="osd-001"    # basename of the vmdk (placed under the VM folder)
SECONDARY_THIN=1            # observed OSD disks are thin-provisioned

FOLDER="/Garden/vm"         # inventory folder
POOL=""                     # resource pool (optional)
HOST=""                     # target host (optional; single-host labs can omit)
POWER_ON=0                  # leave off by default so you can inspect before boot
DRY_RUN=0

# ---------------------------------------------------------------------------
usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)             NAME="$2"; shift 2 ;;
    --cpu)              CPU="$2"; shift 2 ;;
    --cores-per-socket) CORES_PER_SOCKET="$2"; shift 2 ;;
    --memory)           MEMORY_MB="$2"; shift 2 ;;
    --guest-id)         GUEST_ID="$2"; shift 2 ;;
    --firmware)         FIRMWARE="$2"; shift 2 ;;
    --hw-version)       HW_VERSION="$2"; shift 2 ;;
    --nested)           NESTED_HV=1; shift ;;
    --vpmc)             VPMC=1; shift ;;
    --cpu-hot-add)      CPU_HOT_ADD=1; shift ;;
    --mem-hot-add)      MEM_HOT_ADD=1; shift ;;
    --scsi)             SCSI="$2"; shift 2 ;;
    --nic-adapter)      NIC_ADAPTER="$2"; shift 2 ;;
    --network)          NETWORKS+=("$2"); shift 2 ;;
    --primary-ds)       PRIMARY_DS="$2"; shift 2 ;;
    --primary-size)     PRIMARY_SIZE="$2"; shift 2 ;;
    --secondary-ds)     SECONDARY_DS="$2"; shift 2 ;;
    --secondary-size)   SECONDARY_SIZE="$2"; shift 2 ;;
    --secondary-name)   SECONDARY_NAME="$2"; shift 2 ;;
    --no-secondary)     WANT_SECONDARY=0; shift ;;
    --thick)            SECONDARY_THIN=0; shift ;;
    --folder)           FOLDER="$2"; shift 2 ;;
    --pool)             POOL="$2"; shift 2 ;;
    --host)             HOST="$2"; shift 2 ;;
    --power-on)         POWER_ON=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)          usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$NAME" ]] || { echo "ERROR: --name is required" >&2; usage 1; }
[[ ${#NETWORKS[@]} -gt 0 ]] || NETWORKS=("lab-192-168-4-0-b24")

run() {
  echo "+ $*"
  [[ "$DRY_RUN" -eq 1 ]] || "$@"
}

# ---------------------------------------------------------------------------
# 1. Create the VM shell + primary/OS disk on the SHARED datastore.
#    -on=false so we can attach the data disk before first boot.
# ---------------------------------------------------------------------------
create_args=(
  vm.create
  -on=false
  -c "$CPU"
  -m "$MEMORY_MB"
  -g "$GUEST_ID"
  -firmware="$FIRMWARE"
  -net "${NETWORKS[0]}"
  -net.adapter "$NIC_ADAPTER"
  -disk.controller "$SCSI"
  -disk "$PRIMARY_SIZE"
  -ds "$PRIMARY_DS"
  -folder "$FOLDER"
)
[[ -n "$HW_VERSION" ]] && create_args+=(-version="$HW_VERSION")
[[ -n "$POOL" ]] && create_args+=(-pool "$POOL")
[[ -n "$HOST" ]] && create_args+=(-host "$HOST")
create_args+=("$NAME")

run govc "${create_args[@]}"

# ---------------------------------------------------------------------------
# 2. Additional NICs (first one was attached at create time).
# ---------------------------------------------------------------------------
for ((i = 1; i < ${#NETWORKS[@]}; i++)); do
  run govc vm.network.add -vm "$NAME" -net "${NETWORKS[$i]}" -net.adapter "$NIC_ADAPTER"
done

# ---------------------------------------------------------------------------
# 3. CPU capability toggles: nested virtualization, virtual perf counters,
#    and hot-add. Applied together in one reconfigure when any are requested.
#    (The hub-4k77l-cnv-* nodes enable nested HV + vPMC + CPU hot-add.)
# ---------------------------------------------------------------------------
change_args=(vm.change -vm "$NAME")
change=0
[[ "$NESTED_HV"   -eq 1 ]] && { change_args+=(-nested-hv-enabled=true);     change=1; }
[[ "$VPMC"        -eq 1 ]] && { change_args+=(-vpmc-enabled=true);          change=1; }
[[ "$CPU_HOT_ADD" -eq 1 ]] && { change_args+=(-cpu-hot-add-enabled=true);   change=1; }
[[ "$MEM_HOT_ADD" -eq 1 ]] && { change_args+=(-memory-hot-add-enabled=true); change=1; }
[[ "$change" -eq 1 ]] && run govc "${change_args[@]}"

# ---------------------------------------------------------------------------
# 3b. Cores-per-socket (best effort; govc has no dedicated flag, so use the
#     numvcpus extraConfig-style change only when it differs from 1).
# ---------------------------------------------------------------------------
if [[ "$CORES_PER_SOCKET" -ne 1 ]]; then
  echo "NOTE: set cores-per-socket=$CORES_PER_SOCKET manually if govc ignores it" >&2
  run govc vm.change -vm "$NAME" -c "$CPU" -e "numvcpus=$CPU" || true
fi

# ---------------------------------------------------------------------------
# 4. Secondary / data disk on the UNIQUE per-VM datastore.
#    Placed under the VM's own folder on that datastore, matching
#    "[EVO-1] <vm>/osd-001.vmdk".
# ---------------------------------------------------------------------------
if [[ "$WANT_SECONDARY" -eq 1 ]]; then
  disk_args=(
    vm.disk.create
    -vm "$NAME"
    -ds "$SECONDARY_DS"
    -name "$NAME/$SECONDARY_NAME"
    -size "$SECONDARY_SIZE"
    -controller "$SCSI"
  )
  [[ "$SECONDARY_THIN" -eq 1 ]] || disk_args+=(-thick)
  run govc "${disk_args[@]}"
fi

# ---------------------------------------------------------------------------
# 5. Optionally power on.
# ---------------------------------------------------------------------------
if [[ "$POWER_ON" -eq 1 ]]; then
  run govc vm.power -on "$NAME"
fi

echo "Done: $NAME"
[[ "$DRY_RUN" -eq 1 ]] && echo "(dry run — nothing was changed)"
