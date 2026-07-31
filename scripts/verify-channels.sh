#!/usr/bin/env bash
# Checks every manifests/olm/* component against the connected cluster's
# catalog, in two passes:
#
#   1. the pinned channel in subscription.yaml vs the catalog's default channel
#   2. the OperatorGroup shape vs the install modes the operator supports on the
#      channel that subscription.yaml pins
#
# Operator channels drift across OpenShift releases (ODF tracks stable-<ocp>,
# most others just track 'stable'), so re-run this after a cluster upgrade and
# whenever a component is added.
#
# Usage: scripts/verify-channels.sh
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
olm_dir="$repo_root/manifests/olm"

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
  sub="$(dirname "$og")/subscription.yaml"
  pkg=$(awk '/^  name:/ {print $2; exit}' "$sub")
  chan=$(awk '/^  channel:/ {print $2; exit}' "$sub")

  # An OperatorGroup targeting its own namespace needs OwnNamespace; targeting a
  # different single namespace needs SingleNamespace. Distinguish them rather
  # than assuming, so a cross-namespace OperatorGroup is not checked against the
  # wrong mode.
  og_ns=$(awk '/^  namespace:/ {print $2; exit}' "$og")
  target=$(awk '/^  targetNamespaces:/{f=1; next} f && /^    - /{print $2; exit}' "$og")

  if [[ -n "$target" ]]; then
    shape="targetNamespaces"
    if [[ "$target" == "$og_ns" ]]; then wants=OwnNamespace; else wants=SingleNamespace; fi
  else
    shape="spec: {}"; wants=AllNamespaces
  fi

  # Install modes must come from the channel this Subscription actually pins,
  # NOT from channels[0] and not from the default channel. OLM resolves against
  # the subscribed channel, and a package's channels can differ: rhbk-operator
  # defaults to stable-v26.6 while channels[0] is stable-v22. Reading the wrong
  # one can report a false 'ok' on the very check that exists to catch the
  # metallb install-mode bug.
  supported=$(oc get packagemanifest "$pkg" -n openshift-marketplace -o json 2>/dev/null \
    | jq -r --arg c "$chan" '
        .status.channels[]? | select(.name==$c)
        | .currentCSVDesc.installModes
        | map(select(.supported)) | map(.type) | join(",")' 2>/dev/null || true)

  if ! oc get packagemanifest "$pkg" -n openshift-marketplace >/dev/null 2>&1; then
    status="NOT IN CATALOG"; drift=1
  elif [[ -z "$supported" ]]; then
    status="CHANNEL '$chan' NOT FOUND"; drift=1
  elif [[ ",$supported," == *",$wants,"* ]]; then
    status="ok"
  else
    status="UNSUPPORTED — needs $wants, operator allows: $supported"; drift=1
  fi
  printf '%-22s %-18s %s\n' "$component" "$shape" "$status"
done < <(find "$olm_dir" -name operatorgroup.yaml | sort)

echo
if (( drift )); then
  echo "Problems found."
  echo "  DRIFT        update the channel in subscription.yaml, or confirm the pin is"
  echo "               intentional (the default channel is not always the one you want)."
  echo "  UNSUPPORTED  switch the OperatorGroup between 'spec: {}' (AllNamespaces) and"
  echo "               targetNamespaces (OwnNamespace/SingleNamespace) to match what the"
  echo "               operator allows on the channel you pinned."
  echo "  CHANNEL ...  the pinned channel no longer exists in the catalog. Pick a"
  echo "     NOT FOUND current one; install modes could not be checked at all."
  echo "  NOT IN       the package is absent from the catalog on this cluster."
  echo "     CATALOG"
  exit 1
fi
echo "All channels and install modes match the catalog."
