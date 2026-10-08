# k8s-gitops

Desired state for three RKE2 clusters (dev, stg, prd) on a vSphere lab, reconciled by Flux.

```
clusters/<env>/   Flux Kustomizations for that cluster: infra, then apps (dependsOn)
infra/base/       cluster services shared by every env (monitoring exporters)
infra/<env>/      per-env overlay
apps/base/        workloads
apps/<env>/       per-env overlay; images pinned by digest here
```

Rules that CI enforces (`.github/workflows/validate.yml`), and that are red-run tested in `tests/`:

- every overlay builds with `kustomize build` and validates with `kubeconform` against the
  cluster's Kubernetes version, strict mode, unknown fields rejected
- `prune: true` and `wait: true` on every Flux Kustomization, so a deleted file deletes the
  object and "Ready" means the rollout finished, not that the apply was accepted
- no `:latest`, no untagged images, and `apps/prd` images must be pinned by digest

Promotion is a pull request that changes `apps/stg` or `apps/prd`. Nothing reaches a cluster
without a commit on `main`.

Bootstrapped with `flux bootstrap github --owner BetV3 --repository k8s-gitops --path clusters/<env>`.
Each cluster has its own read-only deploy key on this repo.

## Why this exists

Two of the three production control planes on these clusters were joined without the VIP in
their certificate SANs, and nobody noticed for nine days because the join config was typed by
hand on each node. Write-up: https://eramirez.dev/blog/monitor-that-never-used-the-vip/.
Cluster bootstrap config is not in this repo yet (RKE2 node config lives outside Kubernetes),
but everything that runs inside the clusters is, and the same CI gate applies to all of it.
