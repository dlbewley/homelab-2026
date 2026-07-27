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

printf '\n%-22s %-18s %s\n' COMPONENT OPERATORGROUP STATUS

# An OperatorGroup with targetNamespaces requests OwnNamespace/SingleNamespace.
# An empty spec requests AllNamespaces. Asking for a mode the operator does not
# support fails at resolution time with a message that names the mode but not
# the fix, e.g.
#   OwnNamespace InstallModeType not supported, cannot configure to watch own namespace
while IFS= read -r og; do
  component=$(basename "$(dirname "$(dirname "$og")")")
  pkg=$(awk '/^  name:/ {print $2; exit}' "$(dirname "$og")/subscription.yaml")

  if grep -q '^  targetNamespaces:' "$og"; then
    wants=OwnNamespace; shape="targetNamespaces"
  else
    wants=AllNamespaces; shape="spec: {}"
  fi

  supported=$(oc get packagemanifest "$pkg" -n openshift-marketplace \
    -o jsonpath='{.status.channels[0].currentCSVDesc.installModes}' 2>/dev/null \
    | jq -r 'map(select(.supported)) | map(.type) | join(",")' 2>/dev/null || true)

  if [[ -z "$supported" ]]; then
    status="NOT IN CATALOG"; drift=1
  elif [[ ",$supported," == *",$wants,"* ]]; then
    status="ok"
  else
    status="UNSUPPORTED — operator allows: $supported"; drift=1
  fi
  printf '%-22s %-18s %s\n' "$component" "$shape" "$status"
done < <(find "$olm_dir" -name operatorgroup.yaml | sort)

echo
if (( drift )); then
  echo "Problems found."
  echo "  DRIFT       update the channel in subscription.yaml, or confirm the pin is"
  echo "              intentional (the default channel is not always the one you want)."
  echo "  UNSUPPORTED switch the OperatorGroup between 'spec: {}' (AllNamespaces) and"
  echo "              targetNamespaces (OwnNamespace) to match what the operator allows."
  exit 1
fi
echo "All channels and install modes match the catalog."
