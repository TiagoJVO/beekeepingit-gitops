# beekeepingit-gitops

Flux GitOps manifests for **[BeekeepingIT](https://github.com/TiagoJVO/beekeepingit)** — the
`HelmRelease` / `GitRepository` / `Kustomization` objects and per-environment overrides that Flux
reconciles onto each cluster.

Split out of `beekeepingit`'s `infra/gitops/` per **D-27 / ADR-0018** (release-triggered, PR-based
deploy). The Helm **chart** itself still lives in the code repo
([`infra/helm/beekeepingit/`](https://github.com/TiagoJVO/beekeepingit/tree/main/infra/helm/beekeepingit));
Flux sources the chart from there and these manifests from here — a normal, supported split.

## Two sources per cluster

Each `clusters/<env>/flux-system.yaml` declares **two** `GitRepository` objects:

| GitRepository         | Points at                       | Used by                                                      |
| --------------------- | ------------------------------- | ------------------------------------------------------------ |
| `beekeepingit-gitops` | this repo                       | the bootstrap `Kustomization` + `apps/<env>` `Kustomization` |
| `beekeepingit`        | `TiagoJVO/beekeepingit` (chart) | the umbrella `HelmRelease`'s `chart.spec.sourceRef`          |

## Layout

| Path                                                          | What it is                                                                                            |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `clusters/<env>/flux-system.yaml`                             | the two `GitRepository` sources + the self-referential `Kustomization` (reconciles `clusters/<env>/`) |
| `clusters/<env>/apps.yaml`                                    | `Kustomization` pointing Flux at `apps/<env>/`                                                        |
| `clusters/{staging,prod}/cert-manager-issuer.yaml`            | the Let's Encrypt `ClusterIssuer` for that cluster                                                    |
| `apps/<env>/beekeepingit-helmrelease.yaml`                    | the umbrella-chart `HelmRelease` (values mirror the code repo's `environments/<env>.yaml`)            |
| `apps/<env>/{authentik,minio,observability}-helmrelease.yaml` | standalone upstream-chart `HelmRelease`s (ADR-0012/0013/0016)                                         |

`dev` runs on the local k3d cluster; `staging` on Scaleway Kapsule (D-26/ADR-0017); `prod` is inert
scaffolding (deferred per D-26).

## Prerequisites

Flux controllers are installed **imperatively** (not tracked in Git). Flux is **read-only** here —
it reconciles from Git, it does not write to it (D-27/ADR-0018 replaced image-automation, so the
image-reflector/image-automation controllers are not installed):

```sh
flux install
flux check
```

## One-time bootstrap

Wire a cluster to track this repo (idempotent — safe to re-run):

```sh
kubectl apply -f clusters/<env>/
```

After that, everything under this repo — including `clusters/<env>/flux-system.yaml` itself — is
reconciled automatically. Re-run only if the bootstrap objects change in a way Flux can't reconcile
on its own (e.g. renaming a `GitRepository`).

## How a deploy happens

Per **[ADR-0018](https://github.com/TiagoJVO/beekeepingit/blob/main/docs/adr/0018-release-triggered-deploy-pipeline.md)**:
a published Release in the code repo makes CI publish the version's images and open a **tag-bump PR
against this repo**; a human merges it and Flux reconciles. No standing git-write credential; Flux
never writes to Git. Roll back by `git revert`-ing the tag-bump PR here.

## Operating it

```sh
flux get sources git              # GitRepository fetch status (both sources)
flux get kustomizations -A        # sync + health per Kustomization
flux get helmreleases -A          # sync + health per HelmRelease (umbrella chart)
flux reconcile kustomization beekeepingit-dev --with-source   # force an immediate sync
```

Reconciliation is **polling-only** (no webhook receiver). Drift (a manual `kubectl`/`helm` change)
is reverted on the next reconcile (`prune: true` + Helm's drift detection).
