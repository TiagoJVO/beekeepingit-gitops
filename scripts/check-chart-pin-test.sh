#!/usr/bin/env bash
# Fixture-driven test for scripts/check-chart-pin.sh (NFR-ARC-3, NFR-MNT-1, D-13,
# D-27, beekeepingit ADR-0018 2026-08-31 addendum, TiagoJVO/beekeepingit#611).
#
# Two parts:
#   1. Runs the check against every fixture under scripts/fixtures/ — each one a
#      full 3-document clusters/<env>/flux-system.yaml look-alike kept OUTSIDE
#      clusters/ so Flux and the kubeconform job never see it — and asserts BOTH
#      the exit status AND that the output carries the expected reason. Exit
#      status alone is not enough: the check also exits 1 for "file not found"
#      and "could not evaluate", so a missing or unparseable red fixture would
#      otherwise pass vacuously. Those two phrases fail the runner outright.
#   2. Copies clusters/staging + apps/staging into a temporary repo-shaped tree
#      and runs the check with `--root` pointed at it, to prove the HelmRelease
#      sourceRef assertion (which only fires on real clusters/<env>/ files, so
#      no standalone fixture can reach it): green as-is, red once the
#      HelmRelease is repointed at a differently-named GitRepository, red once
#      the HelmRelease file is missing.
# This is how CI proves, on every run, that the check goes green on a pinned
# tag and red on a `branch:` chart ref or a sourceRef bypass, not just that it
# happens to pass on today's real cluster files.
#
# Run locally (needs mikefarah yq v4 on PATH, same as the check itself):
#   bash scripts/check-chart-pin-test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
check="$script_dir/check-chart-pin.sh"
fixtures="$script_dir/fixtures"

failures=0
total=0

# run_case <label> <want-exit> <want-substring> <check args...>
# GITHUB_ACTIONS is blanked so the expected-red cases do not surface as
# `::error` annotations on the PR — only the real cluster files should.
run_case() {
  local label="$1" want="$2" reason="$3"
  shift 3
  total=$((total + 1))
  local out got
  set +e
  out="$(GITHUB_ACTIONS='' bash "$check" "$@" 2>&1)"
  got=$?
  set -e
  local problem=""
  if [ "$got" -ne "$want" ]; then
    problem="expected exit $want, got $got"
  elif [[ "$out" == *"file not found"* ]] || [[ "$out" == *"could not evaluate"* ]]; then
    problem="the check never reached the assertion (missing or unparseable input)"
  elif [[ "$out" != *"$reason"* ]]; then
    problem="expected the output to contain \"$reason\""
  fi
  if [ -z "$problem" ]; then
    echo "✓ $label (exit $got, \"$reason\")"
  else
    echo "✗ $label: $problem"
    printf '%s\n' "$out" | sed 's/^/    /'
    failures=$((failures + 1))
  fi
}

# fixture | expected exit | substring the output must contain
cases='
pinned-tag.yaml                 | 0 | pinned to tag v9.9.9
ref-branch.yaml                 | 1 | must be exactly {tag:
tag-plus-branch.yaml            | 1 | must be exactly {tag:
empty-tag.yaml                  | 1 | is empty
exempt-track-main.yaml          | 0 | exempt by its own declaration
exempt-but-tag-plus-branch.yaml | 1 | requires spec.ref to be exactly {branch: main}
exempt-but-branch-not-main.yaml | 1 | requires spec.ref to be exactly {branch: main}
unknown-policy.yaml             | 1 | unknown value
'

while IFS='|' read -r name want reason; do
  name="${name// /}"
  want="${want// /}"
  reason="${reason#"${reason%%[! ]*}"}"
  reason="${reason%"${reason##*[! ]}"}"
  [ -n "$name" ] || continue
  if [ ! -f "$fixtures/$name" ]; then
    echo "✗ $name: fixture $fixtures/$name does not exist"
    total=$((total + 1))
    failures=$((failures + 1))
    continue
  fi
  run_case "$name" "$want" "$reason" "$fixtures/$name"
done <<EOT
$cases
EOT

if [ "$total" -eq 0 ]; then
  echo "✗ no fixtures listed — refusing a vacuous pass" >&2
  exit 1
fi

# --- sourceRef assertion, on a throwaway copy of the real staging tree -------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/clusters/staging" "$tmp/apps/staging"
cp "$repo_root/clusters/staging/flux-system.yaml" "$tmp/clusters/staging/flux-system.yaml"
cp "$repo_root/apps/staging/beekeepingit-helmrelease.yaml" "$tmp/apps/staging/beekeepingit-helmrelease.yaml"

run_case "tmp-tree: staging copied as-is" 0 "sources its chart from it" --root "$tmp"

# A second GitRepository on `branch: main` plus a repointed HelmRelease is the
# bypass this assertion exists for — the pin on `beekeepingit` still passes.
yq -i '.spec.chart.spec.sourceRef.name = "beekeepingit-unpinned"' "$tmp/apps/staging/beekeepingit-helmrelease.yaml"
run_case "tmp-tree: HelmRelease repointed at another GitRepository" 1 "sourceRef must be {kind: GitRepository, name: beekeepingit}" --root "$tmp"

rm "$tmp/apps/staging/beekeepingit-helmrelease.yaml"
run_case "tmp-tree: HelmRelease file missing" 1 "beekeepingit-helmrelease.yaml is missing" --root "$tmp"

if [ "$failures" -ne 0 ]; then
  echo "✗ [chart-pin-test] $failures of $total case(s) failed" >&2
  exit 1
fi
echo "› [chart-pin-test] all $total case(s) behaved as expected"
