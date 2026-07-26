#!/usr/bin/env bash
#
# attach-iso-boot.sh — Attach an ISO (e.g. an OpenShift assisted-installer
# discovery.iso) to a set of VMs and boot them from it.
#
# For each target VM it:
#   1. ensures a CD-ROM device exists (adds one on an IDE controller if not),
#   2. inserts the ISO from a datastore and marks it connect-at-power-on,
#   3. sets the EFI boot order so CD-ROM is tried first, then disk,
#   4. powers the VM on (or resets it if already on) to boot the ISO.
#
# Idempotent: re-running reuses the existing CD-ROM and just re-inserts/reboots.
#
# Requires: govc + GOVC_* env.
#
# Usage:
#   ./attach-iso-boot.sh                       # all VMs in the default folder
#   ./attach-iso-boot.sh bm-ctrl-1 bm-ctrl-2   # only these VMs (names or paths)
#   ./attach-iso-boot.sh --dry-run             # print govc commands, change nothing
#   ./attach-iso-boot.sh --no-power            # attach only, don't power on/reset
#   ./attach-iso-boot.sh --iso boot.iso --iso-ds VMData-SSD
#
set -euo pipefail

# ---- config (override via flags or env) ----
ISO_DS="${ISO_DS:-VMData}"                 # datastore holding the ISO
ISO="${ISO:-ISO/discovery.iso}"            # ISO path relative to the datastore
FOLDER="${FOLDER:-/Garden/vm/bm-hub}"      # folder of VMs to target when none named
CONTROLLER="${CONTROLLER:-ide-200}"        # IDE controller to hang a new CD-ROM on
BOOT_ORDER="${BOOT_ORDER:-cdrom,disk}"     # EFI boot order (cdrom first, then disk)
POWER=1                                     # 1 = power on / reset; 0 = attach only
DRY_RUN=0
VMS=()

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)        ISO="$2"; shift 2 ;;
    --iso-ds)     ISO_DS="$2"; shift 2 ;;
    --folder)     FOLDER="$2"; shift 2 ;;
    --controller) CONTROLLER="$2"; shift 2 ;;
    --boot-order) BOOT_ORDER="$2"; shift 2 ;;
    --no-power)   POWER=0; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage 0 ;;
    -*)           echo "Unknown option: $1" >&2; usage 1 ;;
    *)            VMS+=("$1"); shift ;;
  esac
done

run() {
  echo "+ $*"
  [[ "$DRY_RUN" -eq 1 ]] || "$@"
}

# Target list: explicit VMs, else every VM in FOLDER.
if [[ ${#VMS[@]} -eq 0 ]]; then
  while IFS= read -r vm; do VMS+=("$vm"); done < <(govc find "$FOLDER" -type m 2>/dev/null | sort)
fi
[[ ${#VMS[@]} -gt 0 ]] || { echo "ERROR: no target VMs (folder=$FOLDER)" >&2; exit 1; }

echo "### Attaching [$ISO_DS] $ISO to ${#VMS[@]} VM(s); boot order=$BOOT_ORDER; power=$([[ $POWER -eq 1 ]] && echo on || echo skip)"
echo

# Return the VM's first CD-ROM device name, creating one if needed.
cdrom_device() {
  local vm="$1" dev
  dev="$(govc device.info -vm "$vm" 'cdrom-*' 2>/dev/null | awk '/^Name:/{print $2; exit}')"
  if [[ -n "$dev" ]]; then echo "$dev"; return; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ govc device.cdrom.add -vm $vm -controller $CONTROLLER" >&2
    echo "cdrom-NEW"; return
  fi
  govc device.cdrom.add -vm "$vm" -controller "$CONTROLLER"
}

for vm in "${VMS[@]}"; do
  name="${vm##*/}"
  echo "== $name =="

  dev="$(cdrom_device "$vm")"
  run govc device.cdrom.insert -vm "$vm" -ds "$ISO_DS" -device "$dev" "$ISO"
  # Ensure the CD-ROM is set to connect at power-on. (Note: if the ISO path is
  # wrong the device comes up with status=recoverableError and the VM boots to
  # "No operating system found" — verify $ISO_DS/$ISO exists.)
  run govc device.connect -vm "$vm" "$dev"
  run govc device.boot -vm "$vm" -firmware efi -order "$BOOT_ORDER"

  if [[ "$POWER" -eq 1 ]]; then
    state="$(govc object.collect -s "$vm" runtime.powerState 2>/dev/null || echo unknown)"
    if [[ "$state" == "poweredOn" ]]; then
      run govc vm.power -reset "$vm"      # already on: reset to boot the ISO
    else
      run govc vm.power -on "$vm"
    fi
  fi
done

echo
echo "### Done."
