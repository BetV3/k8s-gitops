#!/usr/bin/env bash
# Validate every overlay. Used by CI and runnable locally.
#   kustomize build  -> kubeconform strict against the pinned k8s version
#   policy checks    -> prune/wait on Flux Kustomizations, no :latest, prd pinned by digest
set -uo pipefail
cd "$(dirname "$0")/.."
K8S_VERSION="${K8S_VERSION:-1.36.0}"
RC=0
fail() { echo "FAIL: $*"; RC=1; }

echo "== kustomize build + kubeconform (k8s $K8S_VERSION, strict)"
for d in infra/dev infra/stg infra/prd apps/dev apps/stg apps/prd; do
  out=$(kubectl kustomize "$d" 2>&1) || { fail "$d does not build: $(echo "$out" | head -3)"; continue; }
  kubeconform -strict -kubernetes-version "$K8S_VERSION" -summary \
       -schema-location default \
       -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
       - <<<"$out" > /tmp/kc.$$ 2>&1
  kc_rc=$?
  if [ $kc_rc -ne 0 ] || grep -qE 'Invalid: [1-9]|Errors: [1-9]' /tmp/kc.$$; then
    fail "$d: $(grep -vE '^Summary' /tmp/kc.$$ | head -3)"
  else
    echo "  ok  $d  $(grep Summary /tmp/kc.$$)"
  fi
done
rm -f /tmp/kc.$$

echo "== Flux Kustomizations in clusters/: prune + wait required"
for f in clusters/*/*.yaml; do
  grep -q 'kind: Kustomization' "$f" || continue
  grep -q 'prune: true' "$f" || fail "$f: prune is not true"
  grep -q 'wait: true'  "$f" || fail "$f: wait is not true"
  echo "  ok  $f"
done
for e in clusters/*/; do
  kubeconform -strict -kubernetes-version "$K8S_VERSION" \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$e"*.yaml >/dev/null 2>&1 || fail "$e Flux manifests fail schema validation"
done

echo "== image policy"
for d in apps/dev apps/stg apps/prd infra/dev infra/stg infra/prd; do
  imgs=$(kubectl kustomize "$d" 2>/dev/null | grep -E '^\s*-?\s*image:' | sed -E 's/.*image:\s*//; s/\s*#.*//' | tr -d '"')
  for i in $imgs; do
    case "$i" in
      *:latest|*:latest@*) fail "$d uses :latest ($i)";;
      *@sha256:*) ;;
      *:*) [ "$d" = apps/prd ] && fail "apps/prd image not pinned by digest ($i)";;
      *) fail "$d untagged image ($i)";;
    esac
  done
  echo "  checked $d: $(echo "$imgs" | wc -w) image(s)"
done

echo "== prose: no em dashes"
if git ls-files '*.md' | xargs grep -lP '[\x{2014}\x{2013}]' 2>/dev/null | grep .; then fail "em dash in markdown"; fi

[ $RC = 0 ] && echo "VALIDATE: PASS" || echo "VALIDATE: FAIL"
exit $RC
