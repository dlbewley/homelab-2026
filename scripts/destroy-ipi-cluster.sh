#!/usr/bin/env bash
#
# destroy-ipi-cluster.sh — Burn down an installer-provisioned (IPI) OpenShift
# cluster on vSphere, so it can be redeployed from scratch.
#
# `openshift-install destroy cluster` does the real work: it deletes everything
# carrying the cluster's tag — VMs, RHCOS templates, the folder — plus the tag
# and tag category, the storage policy, and the CSI (CNS) volumes behind PVCs.
# This script wraps it with the parts it gets wrong or leaves out:
#
#   1. RECORD   everything the cluster owns, under .bak/, before anything changes
#               (NICs and MACs, disks, CNS volumes, tags) — the rebuild gets new MACs.
#   2. SWEEP    untagged <infra-id>-* VMs in the cluster folder. The installer only
#               finds tagged objects, and templates added on day 2 are not tagged —
#               e.g. the nested-virtualization template <infra-id>-rhcos-oak-cnv
#               built for OpenShift Virtualization nodes. Left in place they are
#               orphaned, and they keep the folder from being deleted.
#   3. DESTROY  openshift-install destroy cluster, with a metadata.json built from
#               the GOVC_* credentials in a private temp dir that is removed on exit.
#   4. VERIFY   nothing is left: VMs, tag, tag category, storage policy, CNS
#               volumes, folder and datastore directories. Exit 1 if anything is.
#
# The sweep only touches VMs directly inside FOLDER whose name starts with
# "<infra-id>-". Nothing else in vCenter is considered.
#
# Requires: govc + GOVC_* env, openshift-install, jq, ./collect-nics.sh.
#
# Status: reference only. Dry-run tested against hub-4k77l; never run for real.
#
# Usage:
#   ./destroy-ipi-cluster.sh --infra-id hub-4k77l --dry-run   # inventory + plan, change nothing
#   ./destroy-ipi-cluster.sh --infra-id hub-4k77l             # destroy (asks first)
#   ./destroy-ipi-cluster.sh --metadata ~/src/homelab/202510/hub/metadata.json
#   ./destroy-ipi-cluster.sh --infra-id hub-4k77l --purge-dirs  # also rm leftover ds dirs
#
# --metadata reads clusterName / clusterID / infraID from an install dir's
# metadata.json; its stored credentials are ignored in favour of GOVC_*.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# ---- config (override via flags or env) ----
INFRA_ID="${INFRA_ID:-}"
CLUSTER_NAME=""
CLUSTER_ID=""
METADATA_SRC=""
DATACENTER="${DATACENTER:-/Garden}"
FOLDER="${FOLDER:-}"                                  # default: $DATACENTER/vm/$INFRA_ID
INSTALLER="${INSTALLER:-openshift-install}"
LOG_LEVEL="${LOG_LEVEL:-info}"
BACKUP_ROOT="${BACKUP_ROOT:-$REPO/.bak}"              # gitignored
PURGE_DIRS=0
ASSUME_YES=0
DRY_RUN=0

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --infra-id)   INFRA_ID="$2"; shift 2 ;;
    --metadata)   METADATA_SRC="$2"; shift 2 ;;
    --folder)     FOLDER="$2"; shift 2 ;;
    --installer)  INSTALLER="$2"; shift 2 ;;
    --purge-dirs) PURGE_DIRS=1; shift ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

for c in govc jq "$INSTALLER"; do
  command -v "$c" >/dev/null || { echo "ERROR: $c is required" >&2; exit 1; }
done
[[ -n "${GOVC_URL:-}" && -n "${GOVC_USERNAME:-}" && -n "${GOVC_PASSWORD:-}" ]] \
  || { echo "ERROR: GOVC_URL / GOVC_USERNAME / GOVC_PASSWORD must be set (source ../setup_env.sh)" >&2; exit 1; }

if [[ -n "$METADATA_SRC" ]]; then
  [[ -r "$METADATA_SRC" ]] || { echo "ERROR: cannot read $METADATA_SRC" >&2; exit 1; }
  md_infra="$(jq -r '.infraID // empty' "$METADATA_SRC")"
  [[ -z "$INFRA_ID" || "$INFRA_ID" == "$md_infra" ]] \
    || { echo "ERROR: --infra-id $INFRA_ID does not match $METADATA_SRC ($md_infra)" >&2; exit 1; }
  INFRA_ID="$md_infra"
  CLUSTER_NAME="$(jq -r '.clusterName // empty' "$METADATA_SRC")"
  CLUSTER_ID="$(jq -r '.clusterID // empty' "$METADATA_SRC")"
fi

# An infra ID is <cluster-name>-<5 random chars>. Insist on that shape: it is
# the prefix that scopes the sweep, so a short or empty one would be dangerous.
[[ "$INFRA_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?-[a-z0-9]{5}$ ]] \
  || { echo "ERROR: --infra-id (or --metadata) is required and must look like <name>-xxxxx, got '${INFRA_ID}'" >&2; exit 1; }
CLUSTER_NAME="${CLUSTER_NAME:-${INFRA_ID%-*}}"
FOLDER="${FOLDER:-$DATACENTER/vm/$INFRA_ID}"

# vCenter host from GOVC_URL: strip scheme, userinfo, port and path.
VCENTER="${GOVC_URL#*://}"; VCENTER="${VCENTER##*@}"; VCENTER="${VCENTER%%/*}"; VCENTER="${VCENTER%%:*}"

run() {
  echo "+ $*"
  [[ "$DRY_RUN" -eq 1 ]] || "$@"
}

# ---------------------------------------------------------------------------
# Inventory helpers (read-only).
# ---------------------------------------------------------------------------
# Managed-object refs (vm-123) of VMs carrying the cluster tag.
tagged_vm_refs() { govc tags.attached.ls "$INFRA_ID" 2>/dev/null | sed -n 's/^VirtualMachine://p'; }

# Every VM directly in FOLDER, as "<ref> <path>".
folder_vms() {
  local vm
  while IFS= read -r vm; do
    [[ -n "$vm" ]] && printf '%s %s\n' "$(govc ls -i "$vm" | sed 's/^.*://')" "$vm"
  done < <(govc find "$FOLDER" -maxdepth 1 -type m 2>/dev/null | sort)
}

# "[EVO-1] dir/file.vmdk" for every disk of a VM.
disk_files() { govc device.info -vm "$1" 'disk-*' 2>/dev/null | awk '/^ *File:/{sub(/^ *File: */, ""); print}'; }

# CNS volumes whose cluster column is this infra ID.
cns_volumes() { govc volume.ls -l 2>/dev/null | awk -v id="$INFRA_ID" '$NF == id'; }

storage_policy() { govc storage.policy.ls 2>/dev/null | awk -v p="openshift-storage-policy-$INFRA_ID" '$2 == p'; }

# ---------------------------------------------------------------------------
# 1. Plan.
# ---------------------------------------------------------------------------
TAGGED="$(tagged_vm_refs)"
VM_PATHS=()     # every VM in the folder
SWEEP=()        # the untagged <infra-id>-* ones the installer would miss
FOREIGN=()      # anything else in the folder; blocks the run
DS_DIRS=()      # "ds|dir" pairs to verify afterwards

echo "### vCenter $VCENTER — cluster $CLUSTER_NAME, infra ID $INFRA_ID${CLUSTER_ID:+, cluster ID $CLUSTER_ID}"
echo "### folder $FOLDER"
echo
while read -r ref vm; do
  [[ -n "$vm" ]] || continue
  name="${vm##*/}"
  state="$(govc object.collect -s "$vm" runtime.powerState 2>/dev/null)"
  [[ "$(govc object.collect -s "$vm" config.template 2>/dev/null)" == true ]] && state=template
  if grep -qx "$ref" <<<"$TAGGED"; then how=installer
  elif [[ "$name" == "$INFRA_ID"-* ]]; then how="SWEEP (untagged)"; SWEEP+=("$vm")
  else how="FOREIGN"; FOREIGN+=("$vm")
  fi
  VM_PATHS+=("$vm")
  printf '  %-34s %-10s %s\n' "$name" "$state" "$how"
  while IFS= read -r d; do
    [[ -n "$d" ]] && DS_DIRS+=("$d")
  done < <(disk_files "$vm" | sed -nE 's/^\[([^]]+)\] ([^/]+)\/.*/\1|\2/p')
done < <(folder_vms)
[[ ${#VM_PATHS[@]} -gt 0 ]] || echo "  (no VMs in $FOLDER)"

# Tagged VMs outside the folder are still destroyed by the installer — show them.
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  path="$(govc ls -L "VirtualMachine:$ref" 2>/dev/null)"
  [[ "${path%/*}" == "$FOLDER" ]] || printf '  %-34s %-10s %s\n' "${path:-$ref}" "-" "installer (tagged, outside folder)"
done <<<"$TAGGED"

echo
echo "  CNS volumes:    $(cns_volumes | wc -l | tr -d ' ')"
echo "  storage policy: $(storage_policy | awk '{print $2}' | grep . || echo none)"
echo "  tag category:   $(govc tags.category.ls 2>/dev/null | grep -x "openshift-$INFRA_ID" || echo none)"
echo

if [[ ${#FOREIGN[@]} -gt 0 ]]; then
  echo "ERROR: $FOLDER holds VMs that are neither tagged nor named $INFRA_ID-*:" >&2
  printf '  %s\n' "${FOREIGN[@]}" >&2
  echo "The installer deletes the folder, so move these out first." >&2
  exit 1
fi

# Other clusters' leftovers elsewhere in vCenter are worth knowing about, never touched.
others="$(govc find "$DATACENTER/vm" -type m -name "$CLUSTER_NAME-*" 2>/dev/null | grep -v "^$FOLDER/" || true)"
if [[ -n "$others" ]]; then
  echo "NOTE: other $CLUSTER_NAME-* VMs outside this folder (not touched; likely older installs):"
  sed 's/^/  /' <<<"$others"
  echo
fi

if [[ "$DRY_RUN" -ne 1 && "$ASSUME_YES" -ne 1 ]]; then
  printf 'This destroys the cluster and cannot be undone. Type the infra ID "%s" to proceed: ' "$INFRA_ID"
  read -r answer </dev/tty
  [[ "$answer" == "$INFRA_ID" ]] || { echo "Aborted."; exit 1; }
  echo
fi

# ---------------------------------------------------------------------------
# 2. Record the cluster before destroying it.
# ---------------------------------------------------------------------------
RECORD="$BACKUP_ROOT/destroy-$INFRA_ID-$(date +%Y%m%d-%H%M%S)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "+ record NICs, devices, CNS volumes and tags to $RECORD/"
else
  mkdir -p "$RECORD"
  if [[ ${#VM_PATHS[@]} -gt 0 ]]; then
    "$HERE/collect-nics.sh" -o "$RECORD/nics.yaml" "${VM_PATHS[@]}" \
      || { echo "ERROR: NIC snapshot failed; nothing destroyed" >&2; exit 1; }
    for vm in "${VM_PATHS[@]}"; do
      { echo "== ${vm##*/}"; govc device.info -vm "$vm"; echo; } >> "$RECORD/devices.txt"
    done
  fi
  cns_volumes > "$RECORD/cns-volumes.txt"
  govc tags.attached.ls "$INFRA_ID" > "$RECORD/tagged-objects.txt" 2>/dev/null || true
  echo "Recorded pre-destroy state in $RECORD/"
fi
echo

# ---------------------------------------------------------------------------
# 3. Sweep untagged <infra-id>-* VMs and templates. Done BEFORE the installer
#    so the folder is empty by the time it tries to delete it.
# ---------------------------------------------------------------------------
for vm in ${SWEEP[@]+"${SWEEP[@]}"}; do
  echo "== sweep ${vm##*/} =="
  if [[ "$(govc object.collect -s "$vm" runtime.powerState 2>/dev/null)" == poweredOn ]]; then
    run govc vm.power -off -force "$vm"
  fi
  # Eject first: a CD-ROM may point at a shared ISO (e.g. [VMData] ISO/*.iso).
  while IFS= read -r dev; do
    [[ -n "$dev" ]] && run govc device.cdrom.eject -vm "$vm" -device "$dev"
  done < <(govc device.info -vm "$vm" 'cdrom-*' 2>/dev/null | awk '/^Name:/{print $2}')
  run govc vm.destroy "$vm"
done
[[ ${#SWEEP[@]} -gt 0 ]] && echo

# ---------------------------------------------------------------------------
# 4. openshift-install destroy cluster. The metadata.json holds the vCenter
#    password, so it lives only in a 0700 temp dir that is deleted on exit;
#    the installer's log is kept in the record.
# ---------------------------------------------------------------------------
WORK=""
# `if`, not `&&`: under set -e a false test in an EXIT trap replaces the exit status.
cleanup() { if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

echo "+ $INSTALLER destroy cluster --dir <tmp> --log-level=$LOG_LEVEL   # infraID=$INFRA_ID"
if [[ "$DRY_RUN" -ne 1 ]]; then
  WORK="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/destroy-$INFRA_ID.XXXXXX")"
  (umask 077 && jq -n \
    --arg name "$CLUSTER_NAME" --arg id "$CLUSTER_ID" --arg infra "$INFRA_ID" --arg vc "$VCENTER" \
    '{clusterName: $name, clusterID: $id, infraID: $infra,
      vsphere: {terraform_platform: "vsphere",
                VCenters: [{vCenter: $vc, username: env.GOVC_USERNAME, password: env.GOVC_PASSWORD}]}}' \
    > "$WORK/metadata.json")
  rc=0
  "$INSTALLER" destroy cluster --dir "$WORK" --log-level="$LOG_LEVEL" || rc=$?
  cp "$WORK/.openshift_install.log" "$RECORD/openshift-install-destroy.log" 2>/dev/null || true
  [[ "$rc" -eq 0 ]] || echo "WARNING: $INSTALLER exited $rc — see $RECORD/openshift-install-destroy.log" >&2
fi
echo

# ---------------------------------------------------------------------------
# 5. Verify. Datastore directories get the most suspicion: a surviving
#    osd-001.vmdk on an EVO disk would break the rebuild's disk create.
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "(dry run — nothing was changed)"
  exit 0
fi

LEFT=()
[[ -z "$(govc find "$FOLDER" -type m 2>/dev/null)" ]] || LEFT+=("VMs remain in $FOLDER")
[[ -z "$(govc find "$FOLDER" -maxdepth 0 2>/dev/null)" ]] || LEFT+=("folder $FOLDER")
[[ -z "$(tagged_vm_refs)" ]]                     || LEFT+=("VMs tagged $INFRA_ID")
govc tags.category.ls 2>/dev/null | grep -qx "openshift-$INFRA_ID" && LEFT+=("tag category openshift-$INFRA_ID")
[[ -z "$(storage_policy)" ]]                     || LEFT+=("storage policy openshift-storage-policy-$INFRA_ID")
[[ -z "$(cns_volumes)" ]]                        || LEFT+=("$(cns_volumes | wc -l | tr -d ' ') CNS volume(s)")

while IFS='|' read -r ds dir; do
  [[ -n "$ds" ]] || continue
  govc datastore.ls -ds "$ds" "$dir" >/dev/null 2>&1 || continue
  # Only a directory named for this cluster is ever removed.
  if [[ "$PURGE_DIRS" -eq 1 && "$dir" == "$INFRA_ID"-* ]]; then
    run govc datastore.rm -ds "$ds" "$dir" || LEFT+=("[$ds] $dir")
  else
    LEFT+=("[$ds] $dir")
  fi
done < <(printf '%s\n' ${DS_DIRS[@]+"${DS_DIRS[@]}"} | sort -u)

if [[ ${#LEFT[@]} -eq 0 ]]; then
  echo "### $INFRA_ID is gone. Record: $RECORD/"
  exit 0
fi
echo "### Left behind:"
printf '  %s\n' "${LEFT[@]}"
echo "Record: $RECORD/  (re-run to retry; --purge-dirs removes $INFRA_ID-* datastore dirs)"
exit 1
