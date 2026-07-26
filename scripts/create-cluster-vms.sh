#!/usr/bin/env bash
#
# create-cluster-vms.sh — Provision a full set of bare-metal-style VMs for an
# OpenShift cluster, using create-vm.sh as the per-VM primitive.
#
# Node types (edit counts/specs in the CONFIG block below):
#
#   role    prefix     qty  cpu  mem    nics  extra
#   ----    ------     ---  ---  ----   ----  -----------------------------------
#   ctrl    bm-ctrl     3   12   32 GB   1    control plane
#   cnv     bm-cnv      4   16   48 GB   4    nested virt (VT-x) + vPMC + hot-add
#   store   bm-store    3   12   32 GB   2    + 1 TB data disk on a unique EVO SSD
#
# Common to all: 150 GB root disk on a shared datastore, RHEL9 guest, HW version 19.
#
# The VMs are created powered-off so you can PXE/virtual-media boot them like
# bare metal. This script does NOT install OpenShift — it only builds hardware.
#
# Requires: govc + GOVC_* env; ./create-vm.sh next to this script.
#
# Usage:
#   ./create-cluster-vms.sh [--dry-run] [--power-on]
#   ./create-cluster-vms.sh --dry-run          # print every govc command, change nothing
#   ONLY=store ./create-cluster-vms.sh --dry-run   # limit to one role (ctrl|cnv|store)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE="$HERE/create-vm.sh"
[[ -x "$CREATE" ]] || { echo "ERROR: $CREATE not found or not executable" >&2; exit 1; }

# ===========================================================================
# CONFIG — edit for your environment
# ===========================================================================
PRIMARY_DS="${PRIMARY_DS:-VMData}"     # shared datastore holding every root disk
ROOT_SIZE="${ROOT_SIZE:-150GB}"        # common root disk for all node types
HW_VERSION="${HW_VERSION:-19}"         # keep the cluster on one HW version (19 = max on vCenter 7.0.3)
FOLDER="${FOLDER:-/Garden/vm}"         # inventory folder (must already exist)

# Counts per role
CTRL_COUNT=3
CNV_COUNT=4
STORE_COUNT=3

# Name prefixes per role -> bm-ctrl-1, bm-cnv-1, bm-store-1, ...
CTRL_PREFIX="bm-ctrl"
CNV_PREFIX="bm-cnv"
STORE_PREFIX="bm-store"

# Per-role NICs. The NUMBER of entries sets the NIC count; the VALUES are the
# port groups. REVIEW these names for your networks — the counts match the spec
# (ctrl=1, cnv=4, store=2) but the port-group choices are a starting point.
CTRL_NETWORKS=(lab-192-168-4-0-b24)
CNV_NETWORKS=(lab-192-168-4-0-b24 Trunk Trunk Trunk)
STORE_NETWORKS=(lab-192-168-4-0-b24 Trunk)

# Store data disk: 1 TB each, and each store node's disk lives on its OWN
# datastore (a dedicated SSD). Index-aligned with the store nodes; there must
# be at least STORE_COUNT entries.
STORE_DATA_SIZE="1024GB"
STORE_DATASTORES=(EVO-1 EVO-2 EVO-3)
# ===========================================================================

# Pass-through flags for create-vm.sh (e.g. --dry-run, --power-on).
PASS=("$@")
# Optional role filter: ONLY=ctrl|cnv|store
ONLY="${ONLY:-}"

# Expand a bash array of networks into repeated "--network X" args in NET_ARGS.
build_net_args() {
  NET_ARGS=()
  local n
  for n in "$@"; do NET_ARGS+=(--network "$n"); done
}

want() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

echo "### Cluster VMs: ctrl=$CTRL_COUNT cnv=$CNV_COUNT store=$STORE_COUNT"
echo "### root=$ROOT_SIZE on $PRIMARY_DS, hw=v$HW_VERSION, folder=$FOLDER"
echo

# --- Control plane -------------------------------------------------------
if want ctrl; then
  for i in $(seq 1 "$CTRL_COUNT"); do
    build_net_args "${CTRL_NETWORKS[@]}"
    echo "== ${CTRL_PREFIX}-${i} (control plane) =="
    "$CREATE" --name "${CTRL_PREFIX}-${i}" \
      --cpu 12 --memory 32768 \
      "${NET_ARGS[@]}" \
      --no-secondary \
      --primary-ds "$PRIMARY_DS" --primary-size "$ROOT_SIZE" \
      --hw-version "$HW_VERSION" --folder "$FOLDER" \
      ${PASS[@]+"${PASS[@]}"}
  done
fi

# --- CNV / nested-virt ---------------------------------------------------
if want cnv; then
  for i in $(seq 1 "$CNV_COUNT"); do
    build_net_args "${CNV_NETWORKS[@]}"
    echo "== ${CNV_PREFIX}-${i} (nested virt) =="
    "$CREATE" --name "${CNV_PREFIX}-${i}" \
      --cpu 16 --memory 49152 \
      --nested --vpmc --cpu-hot-add \
      "${NET_ARGS[@]}" \
      --no-secondary \
      --primary-ds "$PRIMARY_DS" --primary-size "$ROOT_SIZE" \
      --hw-version "$HW_VERSION" --folder "$FOLDER" \
      ${PASS[@]+"${PASS[@]}"}
  done
fi

# --- Store (unique data-disk datastore per node) -------------------------
if want store; then
  if [[ "$STORE_COUNT" -gt "${#STORE_DATASTORES[@]}" ]]; then
    echo "ERROR: STORE_COUNT=$STORE_COUNT exceeds STORE_DATASTORES (${#STORE_DATASTORES[@]}); add more unique datastores" >&2
    exit 1
  fi
  for i in $(seq 1 "$STORE_COUNT"); do
    ds="${STORE_DATASTORES[$((i - 1))]}"
    build_net_args "${STORE_NETWORKS[@]}"
    echo "== ${STORE_PREFIX}-${i} (store, data disk on $ds) =="
    "$CREATE" --name "${STORE_PREFIX}-${i}" \
      --cpu 12 --memory 32768 \
      "${NET_ARGS[@]}" \
      --primary-ds "$PRIMARY_DS" --primary-size "$ROOT_SIZE" \
      --secondary-ds "$ds" --secondary-size "$STORE_DATA_SIZE" \
      --hw-version "$HW_VERSION" --folder "$FOLDER" \
      ${PASS[@]+"${PASS[@]}"}
  done
fi

echo
echo "### Done."
