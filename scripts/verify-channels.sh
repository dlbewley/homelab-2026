#!/usr/bin/env bash
# Compare the channel in every components/olm/*/base/subscription.yaml against
# the default channel the connected cluster's catalog actually offers.
#
# Operator channels drift across OpenShift releases (ODF tracks stable-<ocp>,
# most others just track 'stable'), so re-run this after a cluster upgrade.
#
# Usage: scripts/verify-channels.sh
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
olm_dir="$repo_root/components/olm"

if ! oc whoami >/dev/null 2>&1; then
  echo "Not logged in to a cluster. Set KUBECONFIG and retry." >&2
  exit 1
fi

echo "Cluster: $(oc whoami --show-server)  OpenShift $(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
printf '\n%-22s %-18s %-18s %s\n' COMPONENT WANTED DEFAULT STATUS

drift=0
while IFS= read -r sub; do
  component=$(basename "$(dirname "$(dirname "$sub")")")
  pkg=$(awk '/^  name:/ {print $2; exit}' "$sub")
  want=$(awk '/^  channel:/ {print $2; exit}' "$sub")

  got=$(oc get packagemanifest "$pkg" -n openshift-marketplace \
          -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)

  if [[ -z "$got" ]]; then
    status="NOT IN CATALOG"; got="-"; drift=1
  elif [[ "$want" == "$got" ]]; then
    status="ok"
  else
    status="DRIFT"; drift=1
  fi
  printf '%-22s %-18s %-18s %s\n' "$component" "$want" "$got" "$status"
done < <(find "$olm_dir" -name subscription.yaml | sort)

echo
if (( drift )); then
  echo "Drift found. Update the affected subscription.yaml, or confirm the pinned"
  echo "channel is intentional (the default channel is not always the one you want)."
  exit 1
fi
echo "All channels match the catalog defaults."
