# k8s-gitops

Desired state for three RKE2 clusters (dev, stg, prd) on a vSphere lab, reconciled by Flux.
Nothing reaches a cluster without a commit on `main`, and `main` does not accept a commit that
fails `scripts/validate.sh`.

```
clusters/<env>/   Flux Kustomizations for that cluster: infra -> policies -> apps (dependsOn)
infra/base/       cluster services: kube-state-metrics, Kyverno (upstream manifest vendored)
policies/base/    Kyverno ClusterPolicies, applied before any app
apps/base/        workloads
apps/<env>/       per-env overlay; images pinned by digest
scripts/          the validator CI runs
tests/            red-run harnesses: each proves a gate can FAIL before it is trusted
```

## What is enforced, and the file that proves it

| Claim | Proof |
|---|---|
| Every overlay is schema-validated, strict, against the cluster's Kubernetes version | `scripts/validate.sh` (kustomize build then kubeconform `-strict`) |
| The validator rejects an unknown field, broken YAML, `:latest`, an un-pinned prd image, `prune: false`, a missing `wait: true`, and an em dash in prose | `tests/redrun_validate.sh`, 8 cases, each must FAIL; runs in CI on every push |
| Only images signed by a BetV3 GitHub Actions workflow can run in covered namespaces | `policies/base/verify-ghcr-signed.yaml` (keyless, Fulcio + Rekor, `Enforce`) |
| An unsigned image is rejected at admission; a signed one is admitted and rewritten to its digest | `tests/admission_redgreen.sh` |
| Drift is repaired: `kubectl scale` reverted in 3 s, a deleted Service recreated in 4 s, an object removed from git pruned in one interval | `tests/drift_redgreen.sh`, measured on dev 2026-10-08 |
| Prune is inventory-based, not label-based: an object carrying Flux's labels that Flux never applied is left alone | same test, negative control |

## Two things the tests found that the design did not predict

1. **Chained 1-minute intervals starve the last link.** With infra, policies and apps all at
   `interval: 1m`, every infra reconcile flipped it to Unknown for about a second while 76
   Kyverno objects were server-side applied; policies then saw "dependency not ready" and
   backed off 30 s; apps behind it waited again. The drift test caught it: a deleted Service
   was not recreated in 120 s. Fix: infra and policies at 10 m, apps at 1 m.
2. **A deletion during a `wait: true` health check is not repaired until the check times out.**
   Flux waits on the inventory it just applied; it does not re-apply mid-wait. Measured:
   "health check failed after 3m0s: Service status NotFound", recreated by the next run.
   Worst-case repair is `timeout + interval`, and the test now waits for an idle
   Kustomization so its numbers are the idle-cluster figures.

## The signed image

`ghcr.io/betv3/hello-signed` is built, signed and attested by
[BetV3/hello-signed](https://github.com/BetV3/hello-signed). Verify from anywhere, no credentials:

```
cosign verify \
  --certificate-identity-regexp '^https://github.com/BetV3/hello-signed/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/betv3/hello-signed@sha256:29115da7706d9c09243bb25a221d9ddeaaeb50b8285b25e0ee4972197fbc1ae5
```

Identity in the certificate: `https://github.com/BetV3/hello-signed/.github/workflows/release.yml@refs/tags/v1.0.0`.
Rekor log index 3150687989. The SPDX attestation lists 69 packages.
`ghcr.io/betv3/hello-signed:unsigned` is a deliberately unsigned copy of the base image, kept so
the admission test has something to reject.

## Bootstrap

```
flux bootstrap github --owner BetV3 --repository k8s-gitops --branch main \
  --path clusters/<env> --personal --read-write-key=false
```

Each cluster gets its own read-only deploy key on this repo. Flux cannot push.

## Why this exists

Two of the three production control planes were joined by hand without the VIP in their
certificate SANs and nobody noticed for nine days. Write-up:
https://eramirez.dev/blog/monitor-that-never-used-the-vip/. Node-level RKE2 config still lives
outside Kubernetes, so it is not here yet; everything that runs inside the clusters is.
