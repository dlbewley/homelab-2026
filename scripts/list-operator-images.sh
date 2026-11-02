#!/usr/bin/env bash
# Lists every image the operators a cluster subscribes to will pull, read from
# the catalogs rather than from a cluster, so it works before anything is
# installed - e.g. to size or build a mirror for a disconnected install.
#
# Subscriptions come from the rendered kustomize output of every component in
# clusters/<cluster>/operators.yaml, plus the GitOps operator in bootstrap/.
# Rendered, not read from base/: an overlay can change the channel, as
# ovn-recon's hub overlay does.
#
# Each Subscription's source maps to a catalog image: the four default Red Hat
# sources to their index image at the OpenShift minor, anything else to the
# CatalogSource of that name rendered from the same components. Only the
# package's own directory is copied out of the catalog with podman, so an
# index with thousands of bundles costs one pull, not a full render.
#
# By default it reports the channel HEAD - the bundle a fresh Subscription
# installs today. -a reports every bundle in the channel instead, which is
# what a mirror needs if clusters will upgrade through older versions.
#
# Each bundle contributes its bundle image (OLM unpacks it to install) and its
# relatedImages (the operator plus every operand it deploys). -i also lists
# the catalog images, since a disconnected cluster needs those mirrored too.
#
# Usage: scripts/list-operator-images.sh [-c cluster] [-v 4.22] [-a] [-i]
#   -c  directory under clusters/ to read (default: hub)
#   -v  OpenShift minor the Red Hat catalogs are tagged for
#       (default: the logged-in cluster's)
#   -a  every bundle in the channel, not just the head
#   -i  unique image list only, one per line
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

cluster=hub ocp="" every=false images_only=false
while getopts 'c:v:aih' opt; do
  case $opt in
    c) cluster=$OPTARG ;;
    v) ocp=$OPTARG ;;
    a) every=true ;;
    i) images_only=true ;;
    *) sed -n '/^# Usage:/,/^set /{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 2 ;;
  esac
done

appset="$repo_root/clusters/$cluster/operators.yaml"
[[ -f $appset ]] || { echo "No $appset" >&2; exit 1; }

if [[ -z $ocp ]]; then
  ocp=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null \
          | cut -d. -f1,2 || true)
  [[ -n $ocp ]] || { echo "Not logged in to a cluster; pass -v <minor>, e.g. -v 4.22" >&2; exit 1; }
fi

work=$(mktemp -d)
trap 'podman rm -f $(cat "$work"/cids 2>/dev/null) >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

# Render every component once; both Subscriptions and CatalogSources come from it.
{
  yq -r '.spec.generators[0].list.elements[].path' "$appset" | while IFS= read -r path; do
    oc kustomize "$repo_root/$path"
    echo '---'
  done
  cat "$repo_root/bootstrap/openshift-gitops.yaml"
} > "$work/rendered.yaml"

yq -r 'select(.kind=="CatalogSource") | [.metadata.name, .spec.image] | @tsv' \
  "$work/rendered.yaml" > "$work/catalogs.tsv"

catalog_image() {
  case $1 in
    redhat-operators)    echo "registry.redhat.io/redhat/redhat-operator-index:v$ocp" ;;
    certified-operators) echo "registry.redhat.io/redhat/certified-operator-index:v$ocp" ;;
    community-operators) echo "registry.redhat.io/redhat/community-operator-index:v$ocp" ;;
    redhat-marketplace)  echo "registry.redhat.io/redhat/redhat-marketplace-index:v$ocp" ;;
    *) awk -F'\t' -v s="$1" '$1==s {print $2; exit}' "$work/catalogs.tsv" ;;
  esac
}

# One container per catalog image, created (never started) so its files can
# be copied out. Pulled once per run so a moved tag is picked up.
declare -A cid_for configs_for
catalog_container() {
  local img=$1
  if [[ -z ${cid_for[$img]:-} ]]; then
    echo "Pulling $img" >&2
    podman pull -q "$img" >/dev/null
    configs_for[$img]=$(podman image inspect "$img" \
      --format '{{index .Labels "operators.operatorframework.io.index.configs.v1"}}')
    cid_for[$img]=$(podman create "$img")
    echo "${cid_for[$img]}" >> "$work/cids"
  fi
}

# File-based catalogs are JSON or YAML, one object per document; flatten
# either into a stream jq can slurp.
fbc_json() {
  find "$1" -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) | while IFS= read -r f; do
    case $f in
      *.json) jq -c . "$f" ;;
      *)      yq -o=json -I=0 '.' "$f" ;;
    esac
  done
}

problems=0
: > "$work/rows.tsv"
: > "$work/catalog-images.txt"
while IFS=$'\t' read -r pkg channel source; do
  [[ -n $pkg ]] || continue   # yq emits a blank line per non-matching document
  img=$(catalog_image "$source")
  if [[ -z $img ]]; then
    echo "$pkg: no CatalogSource named '$source' in the rendered components" >&2
    problems=1; continue
  fi
  echo "$img" >> "$work/catalog-images.txt"
  catalog_container "$img"

  dir="$work/fbc/$pkg"
  mkdir -p "$dir"
  if ! podman cp "${cid_for[$img]}:${configs_for[$img]:-/configs}/$pkg/." "$dir" 2>/dev/null; then
    echo "$pkg: NOT IN CATALOG $img" >&2
    problems=1; continue
  fi
  fbc_json "$dir" | jq -c 'select(. != null)' > "$dir.jsonl"

  if ! jq -e --arg c "$channel" 'select(.schema=="olm.channel" and .name==$c)' "$dir.jsonl" >/dev/null; then
    echo "$pkg: CHANNEL '$channel' NOT FOUND in $img" >&2
    problems=1; continue
  fi

  # The head is the one entry nothing else in the channel replaces or skips.
  jq -rs --arg pkg "$pkg" --arg c "$channel" --argjson every "$every" '
    (map(select(.schema=="olm.channel" and .name==$c)) | first) as $ch
    | ($ch.entries | map(.name)) as $names
    | ([$ch.entries[] | (.replaces // empty), (.skips // [])[]]) as $older
    | (if $every then $names else $names - $older end) as $want
    | .[] | select(.schema=="olm.bundle" and (.name as $n | $want | index($n)))
    | .name as $b
    | ([.image] + [.relatedImages[]?.image]) | unique[]
    | [$pkg, $c, $b, .] | @tsv' "$dir.jsonl" >> "$work/rows.tsv"
done < <(yq -r 'select(.kind=="Subscription") | [.spec.name, .spec.channel, .spec.source] | @tsv' \
           "$work/rendered.yaml")

if $images_only; then
  { cut -f4 "$work/rows.tsv"; cat "$work/catalog-images.txt"; } | sort -u
else
  { printf 'PACKAGE\tCHANNEL\tBUNDLE\tIMAGE\n'; sort "$work/rows.tsv"; } | column -t -s $'\t'
  echo
  echo "$(cut -f4 "$work/rows.tsv" | sort -u | wc -l | tr -d ' ') unique images from" \
       "$(cut -f1 "$work/rows.tsv" | sort -u | wc -l | tr -d ' ') packages," \
       "OpenShift $ocp catalogs." >&2
fi
exit $problems
