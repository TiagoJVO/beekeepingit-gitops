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
| `scripts/`                                                    | `check-chart-pin.sh` + fixtures: CI guard that the chart source is pinned (beekeepingit#611)          |

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

That promotion PR bumps the chart source's `ref.tag` in `clusters/<env>/flux-system.yaml` as well as
the image tags — for a git source, that `ref` is the only thing pinning chart content, so
staging/prod only ever render the chart of a published release. `dev` is the deliberate exception:
its chart source tracks `main` (the post-merge pre-release loop) and declares it with the
`gitops.beekeepingit/chart-ref-policy: track-main` annotation. `gitops-ci.yml`'s `chart-pin` job
enforces this on every PR — and also that `apps/<env>/beekeepingit-helmrelease.yaml` sources its
chart from that pinned `beekeepingit` GitRepository, so repointing the HelmRelease at a second,
unpinned source cannot bypass the pin; run it locally with `bash scripts/check-chart-pin.sh` (needs
`yq` v4).

**`notify-deploy.yml`** ([ADR-0018 addendum](https://github.com/TiagoJVO/beekeepingit/blob/main/docs/adr/0018-release-triggered-deploy-pipeline.md#addendum-2026-07-21-separate-the-approval-gate-environment-from-the-deploy-record-environment))
fires on that merge and records the real deploy on `beekeepingit`'s
[Deployments page](https://github.com/TiagoJVO/beekeepingit/deployments) under the plain
`staging`/`production` environment — distinct from the `staging-gate`/`production-gate` entries
that mark a release as merely _approved to publish_. Needs a `DEPLOY_NOTIFY_TOKEN` repo secret: a
fine-grained PAT scoped to `TiagoJVO/beekeepingit` only, with **Deployments: Read and write**
permission (nothing else — it cannot push code or open PRs there).

## Operating it

```sh
flux get sources git              # GitRepository fetch status (both sources)
flux get kustomizations -A        # sync + health per Kustomization
flux get helmreleases -A          # sync + health per HelmRelease (umbrella chart)
flux reconcile kustomization beekeepingit-dev --with-source   # force an immediate sync
```

Reconciliation is **polling-only** (no webhook receiver). Drift (a manual `kubectl`/`helm` change)
is reverted on the next reconcile (`prune: true` + Helm's drift detection).
