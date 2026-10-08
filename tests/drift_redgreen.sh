#!/usr/bin/env bash
# Drift test: GitOps is a hypothesis until something edits the cluster behind git's back
# and git wins. Three cases, each measured:
#   1. kubectl scale the app to 3 -> Flux must put it back to 1 (git says 1)
#   2. kubectl delete the Service     -> Flux must recreate it
#   3. a manual Deployment in a Flux-owned namespace, labelled as if Flux owned it,
#      must be PRUNED (prune: true), while an unlabelled one is left alone (not Flux's)
# Reports the time to repair for each. Interval on dev is 1m, so expect <= ~70 s.
set -uo pipefail
export PATH=$HOME/bin:$PATH
NS=hello-signed
rc=0
t() { date +%s; }
wait_for() {  # desc, timeout_s, cmd that must print "ok"
  local d=$1 to=$2; shift 2; local s=$(t)
  for i in $(seq 1 $to); do [ "$("$@" 2>/dev/null)" = ok ] && { echo "PASS  $d repaired in $(( $(t) - s ))s"; return 0; }; sleep 1; done
  echo "FAIL  $d not repaired within ${to}s"; rc=1; return 1
}

echo "== 1. scale drift"
kubectl -n $NS scale deploy hello-signed --replicas=3 >/dev/null
echo "  replicas now: $(kubectl -n $NS get deploy hello-signed -o jsonpath='{.spec.replicas}') (git says 1)"
flux reconcile kustomization apps --with-source >/dev/null 2>&1 &
wait_for "scale 3 -> 1" 120 bash -c "[ \"\$(kubectl -n $NS get deploy hello-signed -o jsonpath='{.spec.replicas}')\" = 1 ] && echo ok"

echo "== 2. delete drift"
kubectl -n $NS delete svc hello-signed --wait=true >/dev/null
echo "  service deleted: $(kubectl -n $NS get svc hello-signed 2>&1 | grep -c NotFound) (1 = gone)"
flux reconcile kustomization apps --with-source >/dev/null 2>&1 &
wait_for "deleted Service recreated" 120 bash -c "kubectl -n $NS get svc hello-signed -o name 2>/dev/null | grep -q . && echo ok"

echo "== 3. prune: an object that claims to be Flux-managed but is not in git"
kubectl -n $NS create deploy rogue --image=ghcr.io/betv3/hello-signed:v1.0.0 --dry-run=client -o yaml \
  | kubectl label --local -f - kustomize.toolkit.fluxcd.io/name=apps kustomize.toolkit.fluxcd.io/namespace=flux-system -o yaml \
  | kubectl apply -f - >/dev/null
kubectl -n $NS create deploy bystander --image=ghcr.io/betv3/hello-signed:v1.0.0 >/dev/null
echo "  rogue (labelled as Flux's) and bystander (unlabelled) created"
flux reconcile kustomization apps --with-source >/dev/null 2>&1 &
wait_for "rogue pruned" 120 bash -c "kubectl -n $NS get deploy rogue 2>&1 | grep -q NotFound && echo ok"
if kubectl -n $NS get deploy bystander -o name >/dev/null 2>&1; then echo "PASS  bystander (not Flux's) left alone"; else echo "FAIL  bystander was deleted"; rc=1; fi
kubectl -n $NS delete deploy bystander --wait=false >/dev/null 2>&1

echo "== final state"
flux get kustomization apps 2>&1 | tail -1
kubectl -n $NS get deploy,svc --no-headers
[ $rc = 0 ] && echo "DRIFT TEST: PASS" || echo "DRIFT TEST: FAIL"; exit $rc
