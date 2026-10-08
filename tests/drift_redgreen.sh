#!/usr/bin/env bash
# Drift test: GitOps is a hypothesis until something edits the cluster behind git's back
# and git wins. Three cases, each measured:
#   1. kubectl scale the app to 3 -> Flux must put it back to 1 (git says 1)
#   2. kubectl delete the Service     -> Flux must recreate it
#   3. an object added to git appears; removed from git it is PRUNED (prune: true).
#      Negative control: an object carrying Flux's labels that Flux never applied is NOT
#      pruned, because prune works from the Kustomization inventory, not from labels.
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

echo "== 3. prune: add an object via git, then remove it via git; Flux must delete it from the cluster"
echo "   (Flux prunes from its inventory, NOT from labels: an object that merely carries Flux's"
echo "    labels but was never applied by Flux is left alone. Tested below as the negative control.)"
kubectl -n $NS create cm pretender --from-literal=k=v --dry-run=client -o yaml \
  | kubectl label --local -f - kustomize.toolkit.fluxcd.io/name=apps kustomize.toolkit.fluxcd.io/namespace=flux-system -o yaml \
  | kubectl apply -f - >/dev/null
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: prune-probe\n  namespace: %s\ndata:\n  k: v\n' $NS > apps/base/hello-signed/prune-probe.yaml
sed -i 's/  - service.yaml/  - service.yaml\n  - prune-probe.yaml/' apps/base/hello-signed/kustomization.yaml
git add -A && git -c user.name='Elvis Ramirez' -c user.email='elvisramirez999@gmail.com' commit -q -m "test: add prune-probe ConfigMap" && git push -q
flux reconcile kustomization apps --with-source >/dev/null 2>&1 &
wait_for "ConfigMap added via git appears" 180 bash -c "kubectl -n $NS get cm prune-probe -o name 2>/dev/null | grep -q . && echo ok"
git rm -q apps/base/hello-signed/prune-probe.yaml && sed -i '/prune-probe.yaml/d' apps/base/hello-signed/kustomization.yaml
git add -A && git -c user.name='Elvis Ramirez' -c user.email='elvisramirez999@gmail.com' commit -q -m "test: remove prune-probe ConfigMap" && git push -q
flux reconcile kustomization apps --with-source >/dev/null 2>&1 &
wait_for "ConfigMap removed from git is pruned" 180 bash -c "kubectl -n $NS get cm prune-probe 2>&1 | grep -q NotFound && echo ok"
if kubectl -n $NS get cm pretender -o name >/dev/null 2>&1; then echo "PASS  pretender (Flux labels, never applied by Flux) left alone: prune is inventory-based"; else echo "FAIL  pretender was deleted"; rc=1; fi
kubectl -n $NS delete cm pretender --wait=false >/dev/null 2>&1

echo "== final state"
flux get kustomization apps 2>&1 | tail -1
kubectl -n $NS get deploy,svc --no-headers
[ $rc = 0 ] && echo "DRIFT TEST: PASS" || echo "DRIFT TEST: FAIL"; exit $rc
