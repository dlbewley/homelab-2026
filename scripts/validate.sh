#!/usr/bin/env bash
# Repo validation that needs no cluster. Run locally before pushing; CI runs the
# same script, so a green run here means a green run there.
#
#   1. every directory containing a kustomization.yaml builds
#   2. no manifest is present-but-unreferenced
#
# Check 2 exists because kustomize renders an unreferenced file as nothing at
# all and exits 0. A manifest you think is deployed but silently is not is the
# same failure mode as an empty manifest — both look healthy in ArgoCD.
# Deliberate exceptions live in scripts/allowed-orphans.txt.
#
# NOT covered here, because both need a live cluster:
#   - server-side apply dry-run, which is what catches CRD schema errors such
#     as a field removed in a newer operator release
#   - scripts/verify-channels.sh, which compares pinned channels and
#     OperatorGroup install modes against the catalog
# Run those by hand against a cluster before trusting a change to operator CRs.
#
# Usage: scripts/validate.sh
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# Prefer standalone kustomize; fall back to whichever CLI embeds it.
if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build "$1"; }
elif command -v oc >/dev/null 2>&1; then
  build() { oc kustomize "$1"; }
elif command -v kubectl >/dev/null 2>&1; then
  build() { kubectl kustomize "$1"; }
else
  echo "Need one of: kustomize, oc, kubectl" >&2
  exit 1
fi

fail=0

echo "== kustomize build =="
while IFS= read -r dir; do
  if err=$(build "$dir" 2>&1 >/dev/null); then
    printf '  ok    %s\n' "$dir"
  else
    printf '  FAIL  %s\n    %s\n' "$dir" "${err//$'\n'/$'\n'    }"
    fail=1
  fi
done < <(find . -name kustomization.yaml -not -path './.git/*' -exec dirname {} \; | sed 's|^\./||' | sort)

echo
echo "== orphaned manifests =="
allow="$repo_root/scripts/allowed-orphans.txt"
listed=0
while IFS= read -r f; do
  dir=$(dirname "$f")
  base=$(basename "$f")
  [[ -f "$dir/kustomization.yaml" ]] || continue

  # Referenced as a resource/patch/component entry, or as a generator input.
  # Comments are stripped first: a commented-out `# - foo.yaml` is precisely the
  # staged-but-inactive case this check exists to surface, so matching it would
  # defeat the check.
  kust=$(sed 's/#.*$//' "$dir/kustomization.yaml")
  if grep -qE "^[[:space:]]*-[[:space:]]+\.?/?${base}[[:space:]]*$" <<<"$kust" \
     || grep -qE "[[:space:]]${base}([[:space:]]|$)" <<<"$kust"; then
    continue
  fi

  if [[ -f "$allow" ]] && grep -qxF "$f" <(grep -vE '^\s*(#|$)' "$allow"); then
    printf '  allowed  %s\n' "$f"
    listed=1
    continue
  fi

  printf '  ORPHAN   %s\n' "$f"
  listed=1
  fail=1
done < <(find . \( -path ./.git -o -path ./.beads \) -prune -o \
           -name '*.yaml' ! -name 'kustomization.yaml' -print \
         | sed 's|^\./||' | grep -E '^(components|manifests)/' | sort)

(( listed )) || echo "  none"

echo
if (( fail )); then
  echo "FAILED. An ORPHAN is either a file to wire into its kustomization.yaml,"
  echo "a file to delete, or a deliberate exception to record in"
  echo "scripts/allowed-orphans.txt with a reason."
  exit 1
fi
echo "PASSED"
