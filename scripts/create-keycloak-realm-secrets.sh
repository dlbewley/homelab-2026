#!/usr/bin/env bash
# Create the 1Password item that backs the homelab Keycloak realm.
#
# manifests/config/keycloak/overlays/hub/externalsecret-realm.yaml pulls one
# field per secret from a single item in the `eso` vault. This creates that item
# with strong random values.
#
# WHY A SCRIPT RATHER THAN `op item create` WITH ASSIGNMENTS
#
#   op item create ... 'dev1-password[password]=generate'
#
# does NOT generate anything. Assignment statements take literal values, so that
# sets the password to the seven-character string "generate" — for every field,
# silently. `op item create --generate-password` exists but only sets an item's
# single built-in password field, not custom ones.
#
# `op item create --help` also warns that assignment values are logged in shell
# history and visible to other processes via the process list. This script pipes
# a JSON template on stdin instead, so no secret ever appears in an argument
# vector. Values are produced by a shell builtin for the same reason.
#
# Usage:
#   scripts/create-keycloak-realm-secrets.sh              # create the item
#   scripts/create-keycloak-realm-secrets.sh --dry-run    # show structure, values masked
#
# Override with env: VAULT, TITLE, LENGTH.
set -euo pipefail

VAULT="${VAULT:-eso}"
TITLE="${TITLE:-keycloak-homelab}"
LENGTH="${LENGTH:-32}"

# Must match the `property:` values in externalsecret-realm.yaml. A field that
# is missing here fails only its own key, which leaves the whole ExternalSecret
# unsynced and the realm import waiting.
FIELDS=(
  ocp-hub-client-secret
  admin-password
  dev1-password
  dev2-password
  dev3-password
  alice-password
  bob-password
)

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

for c in op jq; do
  command -v "$c" >/dev/null || { echo "ERROR: $c is required" >&2; exit 1; }
done

# Excludes quotes, backslash, backtick and $ so a value can never be misread by
# a shell, by YAML, or by JSON on the way through.
gen() { LC_ALL=C tr -dc 'A-Za-z0-9!@#%^_+=-' < /dev/urandom | head -c "$LENGTH"; }

if (( ! DRY_RUN )) && op item get "$TITLE" --vault "$VAULT" >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: item "$TITLE" already exists in vault "$VAULT". Refusing to overwrite.

To rotate one field without touching the others:
  op item edit "$TITLE" --vault "$VAULT" "dev1-password[password]=\$(openssl rand -base64 24)"

To start over, delete it first — note this invalidates any password already in
use, and the realm import must be re-run to pick up new values:
  op item delete "$TITLE" --vault "$VAULT"
EOF
  exit 1
fi

# printf is a shell builtin, so the generated values never become process
# arguments. They reach jq over a pipe, and jq handles the escaping.
build_json() {
  local f
  for f in "${FIELDS[@]}"; do
    printf '%s\t%s\n' "$f" "$(gen)"
  done | jq -R -s --arg title "$TITLE" '
    {
      title: $title,
      category: "LOGIN",
      fields: (
        split("\n") | map(select(length > 0)) | map(
          split("\t") | {id: .[0], type: "CONCEALED", label: .[0], value: .[1]}
        )
      )
    }'
}

if (( DRY_RUN )); then
  # Commentary to stderr so stdout stays valid JSON and can be piped, e.g.
  #   scripts/create-keycloak-realm-secrets.sh --dry-run | jq -r '.fields[].label'
  echo "Would create item \"$TITLE\" in vault \"$VAULT\" with these fields:" >&2
  build_json | jq '.fields |= map(.value = "***\(.value | length) chars***")'
  exit 0
fi

build_json | op item create --vault "$VAULT" -

cat <<EOF

Created "$TITLE" in vault "$VAULT".

Read a value back when you need to log in as that account:
  op read 'op://$VAULT/$TITLE/dev1-password'

The ExternalSecret refreshes hourly; to pick the values up immediately:
  oc annotate externalsecret homelab-realm-secrets -n keycloak \\
    force-sync=\$(date +%s) --overwrite
EOF
