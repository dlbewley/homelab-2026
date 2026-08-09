#!/usr/bin/env bash
# Export the existing homelab root CA from a cluster into 1Password, so every
# cluster can share it instead of generating its own.
#
# RUN THIS ONCE, against the cluster that currently holds the CA, BEFORE merging
# the change that replaces the self-signed chain with an ExternalSecret. After
# that change the ExternalSecret is the only source of the CA — if 1Password
# does not already hold it, cert-manager has nothing to issue from.
#
# Exporting the existing CA rather than generating a new one is the whole point:
# anything that already trusts `Bewley Homelab CA` keeps working. A fresh root
# would mean re-distributing trust to every client.
#
# The private key never becomes a process argument and is never printed. It is
# read from the cluster into a variable and reaches `op` over a pipe.
#
# Usage:
#   scripts/export-homelab-ca.sh --dry-run   # show what would be stored
#   scripts/export-homelab-ca.sh
#
# Override with env: VAULT, TITLE, NAMESPACE, SECRET.
set -euo pipefail

VAULT="${VAULT:-eso}"
TITLE="${TITLE:-homelab-ca}"
NAMESPACE="${NAMESPACE:-cert-manager}"
SECRET="${SECRET:-homelab-ca-tls}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

for c in oc op jq openssl; do
  command -v "$c" >/dev/null || { echo "ERROR: $c is required" >&2; exit 1; }
done
oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged in to a cluster" >&2; exit 1; }

if ! oc get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: secret $SECRET not found in namespace $NAMESPACE." >&2
  echo "       Run this against the cluster that still holds the CA." >&2
  exit 1
fi

CRT=$(oc get secret "$SECRET" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d)
KEY=$(oc get secret "$SECRET" -n "$NAMESPACE" -o jsonpath='{.data.tls\.key}' | base64 -d)
[[ -n "$CRT" && -n "$KEY" ]] || { echo "ERROR: secret is missing tls.crt or tls.key" >&2; exit 1; }

# Refuse to export something that is not a CA — a leaf certificate here would
# produce an issuer that silently fails to sign anything.
if ! openssl x509 <<<"$CRT" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE'; then
  echo "ERROR: $SECRET does not contain a CA certificate (basicConstraints CA:TRUE)" >&2
  exit 1
fi
# And that the key actually matches the certificate, so a mismatched pair is not
# published to every cluster in the lab.
if [[ "$(openssl x509 <<<"$CRT" -noout -pubkey 2>/dev/null)" != "$(openssl pkey <<<"$KEY" -pubout 2>/dev/null)" ]]; then
  echo "ERROR: tls.key does not match tls.crt" >&2
  exit 1
fi

echo "About to export:" >&2
openssl x509 <<<"$CRT" -noout -subject -issuer -dates -serial 2>/dev/null | sed 's/^/  /' >&2

if (( ! DRY_RUN )) && op item get "$TITLE" --vault "$VAULT" >/dev/null 2>&1; then
  cat >&2 <<EOF

ERROR: item "$TITLE" already exists in vault "$VAULT". Refusing to overwrite.

Overwriting would replace the lab's root CA. If that is genuinely what you want
— a CA rotation — every client trusting the old root must be updated, and every
certificate it signed will be reissued. Delete the item deliberately first:
  op item delete "$TITLE" --vault "$VAULT"
EOF
  exit 1
fi

export CA_CRT="$CRT" CA_KEY="$KEY"
build_json() {
  jq -n --arg title "$TITLE" '
    {
      title: $title,
      category: "SECURE_NOTE",
      fields: [
        {id: "tls-crt", type: "STRING",    label: "tls-crt", value: env.CA_CRT},
        {id: "tls-key", type: "CONCEALED", label: "tls-key", value: env.CA_KEY}
      ]
    }'
}

if (( DRY_RUN )); then
  echo >&2
  echo "Would create item \"$TITLE\" in vault \"$VAULT\":" >&2
  build_json | jq '.fields |= map(if .type=="CONCEALED" then .value="***redacted***" else .value=(.value|split("\n")[0] + " ...") end)'
  exit 0
fi

build_json | op item create --vault "$VAULT" -

cat <<EOF

Exported to op://$VAULT/$TITLE

Verify before merging the ExternalSecret change — a bad export is only
discovered when a cluster cannot issue certificates:

  diff <(op read 'op://$VAULT/$TITLE/tls-crt') \\
       <(oc get secret $SECRET -n $NAMESPACE -o jsonpath='{.data.tls\.crt}' | base64 -d)
EOF
