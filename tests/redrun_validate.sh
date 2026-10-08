#!/usr/bin/env bash
# Red-run the validator: each case breaks the tree in one specific way and the
# validator must FAIL. Then the untouched tree must PASS. A validator that cannot
# fail is not a gate. Runs against a copy so the working tree is never touched.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; failn=0
run_case() {  # name, shell snippet applied inside the copy, expected (FAIL|PASS)
  local name=$1 mut=$2 want=$3
  local W; W=$(mktemp -d)
  cp -r "$SRC"/. "$W"/ && rm -rf "$W/.git" && git -C "$W" init -q && git -C "$W" add -A >/dev/null
  (cd "$W" && eval "$mut")
  local got; got=$(cd "$W" && bash scripts/validate.sh 2>&1 | tail -1 | sed 's/VALIDATE: //')
  if [ "$got" = "$want" ]; then echo "PASS  $name -> $got"; pass=$((pass+1)); else echo "FAIL  $name -> got $got, wanted $want"; failn=$((failn+1)); fi
  rm -rf "$W"
}
run_case "control: untouched tree"            "true"                                                                                  PASS
run_case "unknown field rejected"             "sed -i 's/replicas: 1/replicas: 1\n  replicaz: 2/' apps/base/hello-signed/deployment.yaml" FAIL
run_case "broken yaml"                        "echo '  - : [' >> apps/base/hello-signed/service.yaml"                                   FAIL
run_case ":latest rejected"                   "sed -i 's/newTag: .*/newTag: latest/' apps/dev/kustomization.yaml"                       FAIL
run_case "prd not digest-pinned rejected"     "sed -i '/digest:/d' apps/prd/kustomization.yaml; sed -i 's/name: ghcr.io\\/betv3\\/hello-signed/name: ghcr.io\\/betv3\\/hello-signed\\n    newTag: v1.0.0/' apps/prd/kustomization.yaml" FAIL
run_case "prune: false rejected"              "sed -i 's/prune: true/prune: false/' clusters/dev/apps.yaml"                             FAIL
run_case "wait removed rejected"              "sed -i '/wait: true/d' clusters/prd/infra.yaml"                                          FAIL
run_case "em dash in README rejected"         "printf 'a \xe2\x80\x94 b\n' >> README.md"                                                FAIL
echo; echo "$pass passed, $failn failed"
[ $failn = 0 ]
