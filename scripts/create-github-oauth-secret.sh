#!/usr/bin/env bash
# Store a GitHub OAuth App's credentials in 1Password for the github identity
# provider in manifests/config/oauth.
#
# Companion to create-keycloak-realm-secrets.sh, but the opposite problem: that
# script GENERATES values, this one STORES values GitHub gave you. The shared
# constraint is that neither may put a secret in a process argument.
#
#   op item create ... 'client-secret[password]=<paste>'
#
# would work, and would also record the secret in your shell history and expose
# it in the process list — `op item create --help` warns about exactly this.
# So the secret is read from a hidden prompt and reaches `op` over a pipe.
#
# Usage:
#   scripts/create-github-oauth-secret.sh --client-id <id>
#   scripts/create-github-oauth-secret.sh --client-id <id> --dry-run
#
# Override with env: VAULT, TITLE.
set -euo pipefail

VAULT="${VAULT:-eso}"
TITLE="${TITLE:-github-oauth-hub}"
CLIENT_ID=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-id) CLIENT_ID="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

for c in op jq; do
  command -v "$c" >/dev/null || { echo "ERROR: $c is required" >&2; exit 1; }
done

[[ -n "$CLIENT_ID" ]] || { echo "ERROR: --client-id is required" >&2; exit 1; }

if (( ! DRY_RUN )) && op item get "$TITLE" --vault "$VAULT" >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: item "$TITLE" already exists in vault "$VAULT". Refusing to overwrite.

To rotate the secret after regenerating it on GitHub:
  op item edit "$TITLE" --vault "$VAULT" client-secret[password]=...
  # then force the ExternalSecret to re-read it:
  oc annotate externalsecret github-client-secret -n openshift-config \\
    force-sync=\$(date +%s) --overwrite
EOF
  exit 1
fi

# Read into the environment rather than an argument. jq reads it via env.*, so
# the value never appears in any argv.
if (( DRY_RUN )); then
  GH_CLIENT_SECRET="dry-run-placeholder-value-not-real"
else
  read -rsp "GitHub OAuth App client secret for ${TITLE}: " GH_CLIENT_SECRET
  echo >&2
  [[ -n "$GH_CLIENT_SECRET" ]] || { echo "ERROR: empty secret" >&2; exit 1; }
fi
export GH_CLIENT_SECRET GH_CLIENT_ID="$CLIENT_ID"

build_json() {
  jq -n --arg title "$TITLE" '
    {
      title: $title,
      category: "LOGIN",
      fields: [
        # client-id is not a secret — it appears in the OAuth redirect and is
        # committed to git, because the OAuth CR takes it as a plain string with
        # no secret-reference option. Kept here so the item is a complete record
        # of the GitHub App rather than half of one.
        {id: "client-id",     type: "STRING",    label: "client-id",     value: env.GH_CLIENT_ID},
        {id: "client-secret", type: "CONCEALED", label: "client-secret", value: env.GH_CLIENT_SECRET}
      ]
    }'
}

if (( DRY_RUN )); then
  echo "Would create item \"$TITLE\" in vault \"$VAULT\":" >&2
  build_json | jq '.fields |= map(if .type=="CONCEALED" then .value = "***redacted***" else . end)'
  exit 0
fi

build_json | op item create --vault "$VAULT" -

cat <<EOF

Created "$TITLE" in vault "$VAULT".

The ExternalSecret in manifests/config/oauth reads:
  op://$VAULT/$TITLE/client-secret

It refreshes hourly; to pick it up immediately:
  oc annotate externalsecret github-client-secret -n openshift-config \\
    force-sync=\$(date +%s) --overwrite
EOF
