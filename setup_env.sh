#! env bash

# OpenShift Environment Setup Script
# Usage: source setup_env.sh

# Set the KUBECONFIG environment variable to the user's preferred path
# For OpenShift hub cluster
export KUBECONFIG=/Users/dale/.kube/ocp/hub/kubeconfig
#export REGISTRY_AUTH_FILE=/Users/dale/.kube/ocp/agent/quay-push-secret.json
#export APP_NAMESPACE=ovn-recon
#export APP_NAME='ovn-recon'
#export APP_SELECTOR="app.kubernetes.io/name=$APP_NAME"

# enable VMware interaction
#
source /Users/dale/.govc.env
export CONTAINER_TOOL=podman
export KIND_EXPERIMENTAL_PROVIDER=podman

# It will keep local go mod tidy/go test behavior aligned with CI and prevent accidental go.mod/go.sum churn from your host Go 1.26 toolchain.
#export GOTOOLCHAIN=go1.23.0

#QUAY_USERNAME="$(op read op://development/pull-secret/QUAY/username)"
#QUAY_USERNAME="$(op read op://development/pull-secret/QUAY/username)"
#QUAY_PASSWORD="$(op read op://development/pull-secret/QUAY/password)"
#echo $QUAY_PASSWORD | podman login -u $QUAY_USER --password-stdin quay.io

#QUAY_USERNAME="dbewley"
#REGISTRY_AUTH_FILE

# Alias kubectl to oc for convenience and consistency
alias kubectl='oc'
alias docker='podman'
# Replace eza alias if exists
alias ls >/dev/null && unalias ls

echo "# Environment configured:"
echo "  KUBECONFIG=$KUBECONFIG"
echo "  REGISTRY_AUTH_FILE=$REGISTRY_AUTH_FILE"
echo "  APP_NAMESPACE=$APP_NAMESPACE"
echo "  APP_NAME=$APP_NAME"
echo "  APP_SELECTOR=$APP_SELECTOR"
echo "# Aliases configured:"
echo "  'kubectl' aliased to 'oc'"
echo "  'ls' unaliased"
