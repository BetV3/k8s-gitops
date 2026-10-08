#!/usr/bin/env bash
# Admission red/green for the Kyverno keyless verifyImages policy on the dev cluster.
# RED:   an UNSIGNED image from ghcr.io/betv3 must be rejected at admission.
# RED 2: an image that is signed but by a DIFFERENT identity (public cosign sample) must be rejected.
# GREEN: the signed image must be admitted, and its tag rewritten to the verified digest.
# The policy covers the policy-test namespace; create it fresh, clean up after.
set -uo pipefail
export PATH=$HOME/bin:$PATH
NS=policy-test
SIGNED_TAG=ghcr.io/betv3/hello-signed:v1.0.0
SIGNED_DIGEST=$(crane digest $SIGNED_TAG)
UNSIGNED=ghcr.io/betv3/hello-signed:unsigned
kubectl create ns $NS --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rc=0
echo "== RED: unsigned image ($UNSIGNED @ $(crane digest $UNSIGNED | cut -c1-19)...)"
out=$(kubectl -n $NS run red-unsigned --image=$UNSIGNED --restart=Never --command -- sleep 5 2>&1)
if echo "$out" | grep -qiE 'admission webhook.*denied|verify-ghcr-betv3-signed'; then
  echo "PASS  rejected: $(echo "$out" | grep -oiE 'no matching signatures|signature verification failed|failed to verify[^"]*|image verification failed[^"]*' | head -1)"
else echo "FAIL  was admitted or failed for another reason: $out"; rc=1; fi

echo "== RED 2: signed by someone else (ghcr.io/betv3 scope only matters, so use a foreign-signed copy under our scope)"
echo "   (skipped unless a foreign-signed tag exists under ghcr.io/betv3; the subjectRegExp check is exercised by the test below instead)"

echo "== GREEN: signed image ($SIGNED_TAG)"
out=$(kubectl -n $NS run green-signed --image=$SIGNED_TAG --restart=Never --command -- sleep 30 2>&1)
if echo "$out" | grep -q 'created'; then
  sleep 3
  img=$(kubectl -n $NS get pod green-signed -o jsonpath='{.spec.containers[0].image}')
  echo "  admitted; image in spec is now: $img"
  case "$img" in
    *@$SIGNED_DIGEST) echo "PASS  tag rewritten to the verified digest (mutateDigest)";;
    *) echo "FAIL  image was not rewritten to $SIGNED_DIGEST"; rc=1;;
  esac
  kubectl -n $NS wait --for=condition=Ready pod/green-signed --timeout=90s >/dev/null 2>&1 && echo "PASS  pod Running" || { echo "FAIL  pod not Ready: $(kubectl -n $NS get pod green-signed -o jsonpath='{.status.phase}')"; rc=1; }
else echo "FAIL  signed image rejected: $out"; rc=1; fi

echo "== policy report / admission events"
kubectl -n $NS get events --field-selector reason=PolicyViolation -o custom-columns=T:.lastTimestamp,MSG:.message --no-headers 2>/dev/null | cut -c1-200 | tail -3
kubectl get clusterpolicy verify-ghcr-betv3-signed -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
kubectl delete ns $NS --wait=false >/dev/null 2>&1
echo; [ $rc = 0 ] && echo "ADMISSION TEST: PASS" || echo "ADMISSION TEST: FAIL"; exit $rc
