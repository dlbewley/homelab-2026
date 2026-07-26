#!/usr/bin/env bash
#
# collect-nics.sh — Collect each VM's NICs (adapter, network, MAC, and IP if
# known) and write them to a YAML file.
#
# MAC and network come from the VM hardware, so they're always available. The
# IP comes from VMware Tools (guest.net) and is only present when the guest is
# running Tools and has an address — a missing IP is fine, not an error. Only
# IPv4 addresses are reported (link-local / IPv6 are skipped).
#
# Requires: govc + GOVC_* env, and jq.
#
# Usage:
#   ./collect-nics.sh                       # all VMs in the default folder -> file
#   ./collect-nics.sh -o -                  # write YAML to stdout instead
#   ./collect-nics.sh bm-ctrl-1 bm-store-1  # only these VMs
#   ./collect-nics.sh --folder /Garden/vm/bm-hub -o bm-hub-nics.yaml
#
set -euo pipefail

FOLDER="${FOLDER:-/Garden/vm/bm-hub}"      # folder of VMs to inventory when none named
OUTPUT="${OUTPUT:-bm-hub-nics.yaml}"       # output file, or "-" for stdout
VMS=()

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --folder)    FOLDER="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -h|--help)   usage 0 ;;
    -*)          echo "Unknown option: $1" >&2; usage 1 ;;
    *)           VMS+=("$1"); shift ;;
  esac
done

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

# Target list: explicit VMs, else every VM in FOLDER (sorted for stable output).
if [[ ${#VMS[@]} -eq 0 ]]; then
  while IFS= read -r vm; do VMS+=("$vm"); done < <(govc find "$FOLDER" -type m 2>/dev/null | sort)
fi
[[ ${#VMS[@]} -gt 0 ]] || { echo "ERROR: no target VMs (folder=$FOLDER)" >&2; exit 1; }

# jq: for one VM, emit its YAML block. Ethernet cards are the devices with a
# macAddress; IPs are joined from guest.net by MAC (first IPv4 only).
JQ='
  .virtualMachines[0] as $vm
  | ( ($vm.guest.net // [])
      | map({ key: .macAddress,
              value: ([ .ipAddress[]? | select(contains(":") | not) ] | first) })
      | from_entries ) as $ipmap
  | "  - name: \($vm.name)",
    "    nics:",
    ( $vm.config.hardware.device[]
      | select(.macAddress != null)
      | "      - adapter: \"\(.deviceInfo.label)\"",
        "        network: \(.backing.deviceName // .backing.port.portgroupKey // "unknown")",
        "        mac: \"\(.macAddress)\"",
        ( ($ipmap[.macAddress]) as $ip | if $ip then "        ip: \($ip)" else empty end ) )
'

emit() {
  echo "# NIC/MAC inventory generated $(date '+%Y-%m-%d %H:%M:%S %Z') from ${FOLDER}"
  echo "vms:"
  local vm
  for vm in "${VMS[@]}"; do
    govc vm.info -json "$vm" | jq -r "$JQ"
  done
}

if [[ "$OUTPUT" == "-" ]]; then
  emit
else
  emit > "$OUTPUT"
  echo "Wrote $(grep -c '^  - name:' "$OUTPUT") VM(s) to $OUTPUT"
fi
