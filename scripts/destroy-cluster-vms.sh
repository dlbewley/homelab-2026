#!/usr/bin/env bash
#
# destroy-cluster-vms.sh — Burn down the node VMs built by create-cluster-vms.sh,
# so the cluster can be redeployed from scratch. The inverse of that script.
#
# For each target VM it:
#   1. records its hardware (NICs, MACs, disks) under .bak/ before anything changes,
#   2. powers it off (hard) if it is running,
#   3. ejects every CD-ROM, so the shared discovery ISO is never at risk,
#   4. destroys it — VM files and every attached disk, including the EVO-* OSD disk,
#   5. checks each datastore directory the VM used, and reports any left behind.
#
# Scoping is deliberately tight, because this vCenter holds many unrelated VMs:
# only VMs directly inside FOLDER whose name matches NAME_REGEX are ever touched.
# Anything else — even when named on the command line — is skipped with a
# warning. The folder itself is left in place; create-cluster-vms.sh needs it.
#
# This only removes vSphere hardware. An Assisted Installer cluster also has a
# record on console.redhat.com — delete that there before reinstalling.
#
# Requires: govc + GOVC_* env; jq and ./collect-nics.sh for the hardware record.
#
# Usage:
#   ./destroy-cluster-vms.sh --dry-run          # show the plan, change nothing
#   ./destroy-cluster-vms.sh                    # every node VM in the folder (asks first)
#   ./destroy-cluster-vms.sh bm-store-1         # only these VMs (names or paths)
#   ONLY=cnv ./destroy-cluster-vms.sh           # limit to one role: ctrl | cnv | store
#   ./destroy-cluster-vms.sh --purge-dirs       # also remove leftover datastore dirs
#   ./destroy-cluster-vms.sh --yes              # skip the confirmation prompt
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# ---- config (override via flags or env) ----
FOLDER="${FOLDER:-/Garden/vm/bm-hub}"                     # the only folder VMs are taken from
NAME_REGEX="${NAME_REGEX:-^bm-(ctrl|cnv|store)-[0-9]+$}"  # the only names ever destroyed
ONLY="${ONLY:-}"                                          # optional role filter: ctrl | cnv | store
BACKUP_ROOT="${BACKUP_ROOT:-$REPO/.bak}"                  # gitignored; holds the pre-destroy record
PURGE_DIRS=0                                              # 1 = datastore.rm leftover VM directories
INVENTORY=1                                               # 0 = skip the pre-destroy hardware record
ASSUME_YES=0
DRY_RUN=0
ARGS=()

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --folder)       FOLDER="$2"; shift 2 ;;
    --purge-dirs)   PURGE_DIRS=1; shift ;;
    --no-inventory) INVENTORY=0; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage 0 ;;
    -*)             echo "Unknown option: $1" >&2; usage 1 ;;
    *)              ARGS+=("$1"); shift ;;
  esac
done

case "$ONLY" in ""|ctrl|cnv|store) ;; *) echo "ERROR: ONLY must be ctrl, cnv or store" >&2; exit 1 ;; esac
[[ "$FOLDER" == /* && "$FOLDER" != */ ]] \
  || { echo "ERROR: --folder must be an absolute inventory path without a trailing slash" >&2; exit 1; }
command -v govc >/dev/null || { echo "ERROR: govc is required" >&2; exit 1; }
[[ -n "${GOVC_URL:-}" ]] || { echo "ERROR: GOVC_URL is not set (source ../setup_env.sh)" >&2; exit 1; }

run() {
  echo "+ $*"
  [[ "$DRY_RUN" -eq 1 ]] || "$@"
}

# May this VM path be destroyed? It must sit directly in FOLDER and match
# NAME_REGEX (and the ONLY role, when set).
eligible() {
  local path="$1" name="${1##*/}"
  [[ "${path%/*}" == "$FOLDER" ]] || return 1
  [[ "$name" =~ $NAME_REGEX ]] || return 1
  [[ -z "$ONLY" || "$name" == bm-"$ONLY"-* ]] || return 1
}

# "[EVO-1] bm-store-1/osd-001.vmdk" for every disk of a VM.
disk_files() {
  govc device.info -vm "$1" 'disk-*' 2>/dev/null | awk '/^ *File:/{sub(/^ *File: */, ""); print}'
}

# ---------------------------------------------------------------------------
# 1. Build the target list. Bare names are resolved inside FOLDER, so one can't
#    match a same-named VM elsewhere in the inventory.
# ---------------------------------------------------------------------------
CANDIDATES=()
if [[ ${#ARGS[@]} -eq 0 ]]; then
  while IFS= read -r vm; do CANDIDATES+=("$vm"); done < <(govc find "$FOLDER" -maxdepth 1 -type m 2>/dev/null | sort)
else
  for a in "${ARGS[@]}"; do
    if [[ "$a" == /* ]]; then CANDIDATES+=("$a"); else CANDIDATES+=("$FOLDER/$a"); fi
  done
fi

TARGETS=()
for vm in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
  if ! eligible "$vm"; then
    echo "SKIP: $vm — outside $FOLDER or not matching $NAME_REGEX${ONLY:+ (ONLY=$ONLY)}" >&2
    continue
  fi
  # Command substitution rather than `| grep -q`: see create-vm.sh on pipefail + SIGPIPE.
  if [[ -z "$(govc ls "$vm" 2>/dev/null)" ]]; then
    echo "SKIP: $vm — not found" >&2
    continue
  fi
  TARGETS+=("$vm")
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "Nothing to destroy in $FOLDER."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Show the plan: each VM, its power state and every disk it takes with it.
# ---------------------------------------------------------------------------
echo "### vCenter: $GOVC_URL"
echo "### Destroying ${#TARGETS[@]} VM(s) from $FOLDER — VM files AND every attached disk:"
echo
for vm in "${TARGETS[@]}"; do
  state="$(govc object.collect -s "$vm" runtime.powerState 2>/dev/null || echo unknown)"
  printf '  %-14s %s\n' "${vm##*/}" "$state"
  disk_files "$vm" | sed 's/^/                   /'
done
echo

if [[ "$DRY_RUN" -ne 1 && "$ASSUME_YES" -ne 1 ]]; then
  confirm="${FOLDER##*/}"
  printf 'This cannot be undone. Type the folder name "%s" to proceed: ' "$confirm"
  read -r answer </dev/tty
  [[ "$answer" == "$confirm" ]] || { echo "Aborted."; exit 1; }
  echo
fi

# ---------------------------------------------------------------------------
# 3. Record the hardware before destroying it. The rebuilt VMs get NEW MACs,
#    so anything keyed on the old ones (DHCP reservations, the nmstate NIC
#    facts in manifests/config/nmstate/overlays/hub) needs updating from this.
# ---------------------------------------------------------------------------
if [[ "$INVENTORY" -eq 1 ]]; then
  RECORD="$BACKUP_ROOT/destroy-${FOLDER##*/}-$(date +%Y%m%d-%H%M%S)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ record NICs and devices to $RECORD/"
  else
    mkdir -p "$RECORD"
    "$HERE/collect-nics.sh" -o "$RECORD/nics.yaml" "${TARGETS[@]}" \
      || { echo "ERROR: NIC snapshot failed; nothing destroyed (use --no-inventory to skip)" >&2; exit 1; }
    for vm in "${TARGETS[@]}"; do
      { echo "== ${vm##*/}"; govc device.info -vm "$vm"; echo; } >> "$RECORD/devices.txt"
    done
    echo "Recorded pre-destroy hardware in $RECORD/"
  fi
  echo
fi

# ---------------------------------------------------------------------------
# 4. Destroy. Carry on past a failed VM so one bad node doesn't strand the
#    rest; the summary and exit code report it.
# ---------------------------------------------------------------------------
DESTROYED=()
FAILED=()
LEFTOVER=()

destroy_one() {
  local vm="$1" state dev
  state="$(govc object.collect -s "$vm" runtime.powerState 2>/dev/null || echo unknown)"
  if [[ "$state" != "poweredOff" ]]; then
    run govc vm.power -off -force "$vm" || return 1
  fi

  # Eject rather than trust Destroy to leave ISO backings alone — the
  # discovery ISO on VMData is shared by every node.
  while IFS= read -r dev; do
    if [[ -n "$dev" ]]; then run govc device.cdrom.eject -vm "$vm" -device "$dev" || return 1; fi
  done < <(govc device.info -vm "$vm" 'cdrom-*' 2>/dev/null | awk '/^Name:/{print $2}')

  run govc vm.destroy "$vm" || return 1
}

for vm in "${TARGETS[@]}"; do
  name="${vm##*/}"
  echo "== $name =="

  # Datastore directories this VM lives in, captured while it still exists:
  # "[VMData] bm-store-1/..." -> "VMData|bm-store-1".
  dirs=()
  while IFS= read -r d; do
    if [[ -n "$d" ]]; then dirs+=("$d"); fi
  done < <(
    { disk_files "$vm"; govc object.collect -s "$vm" config.files.vmPathName 2>/dev/null; } \
      | sed -nE 's/^\[([^]]+)\] ([^/]+)\/.*/\1|\2/p' | sort -u
  )

  if ! destroy_one "$vm"; then
    echo "FAILED: $name" >&2
    FAILED+=("$name")
    continue
  fi
  DESTROYED+=("$name")
  [[ "$DRY_RUN" -eq 1 ]] && continue

  # Destroy removes the files it knows about, but an empty or stray directory
  # can survive — and a stray osd-001.vmdk would make the rebuild's disk create fail.
  for entry in ${dirs[@]+"${dirs[@]}"}; do
    ds="${entry%%|*}" dir="${entry#*|}"
    # Exit status, not output: an empty surviving directory lists nothing.
    govc datastore.ls -ds "$ds" "$dir" >/dev/null 2>&1 || continue
    # Only a directory named after the VM is ever removed.
    if [[ "$PURGE_DIRS" -eq 1 && "$dir" == "$name" ]]; then
      run govc datastore.rm -ds "$ds" "$dir" || LEFTOVER+=("[$ds] $dir")
    else
      LEFTOVER+=("[$ds] $dir")
    fi
  done
done

# ---------------------------------------------------------------------------
# 5. Summary.
# ---------------------------------------------------------------------------
echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "### Would destroy: ${#DESTROYED[@]}"
  echo "(dry run — nothing was changed)"
  exit 0
fi
echo "### Destroyed: ${#DESTROYED[@]}  Failed: ${#FAILED[@]}  Leftover dirs: ${#LEFTOVER[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then printf '  failed:   %s\n' "${FAILED[@]}"; fi
if [[ ${#LEFTOVER[@]} -gt 0 ]]; then
  printf '  leftover: %s\n' "${LEFTOVER[@]}"
  echo "  (inspect with 'govc datastore.ls -ds <ds> <dir>'; re-run with --purge-dirs to remove)"
fi
[[ ${#FAILED[@]} -eq 0 ]]
