#!/usr/bin/env bash
# check-chart-pin.sh — the chart source of every cluster must be pinned to a
# release tag (NFR-ARC-3, NFR-MNT-1, D-13, D-27, beekeepingit ADR-0018
# 2026-08-31 addendum, TiagoJVO/beekeepingit#611).
#
# WHAT: for each clusters/<env>/flux-system.yaml, the GitRepository named
# `beekeepingit` (the Helm CHART source) must have `spec.ref` consisting of
# exactly one key, `tag`, with a non-empty value. `branch`, `semver`, `commit`
# or `name` — alone or alongside a tag — fail. A cluster may opt out by
# declaring it on the object itself:
#   metadata.annotations["gitops.beekeepingit/chart-ref-policy"]: track-main
# in which case `spec.ref` must be exactly `branch: main`. Any other value of
# that annotation fails. Examining zero files is a failure, not a vacuous pass.
#
# AND, for every file that really lives at <root>/clusters/<env>/flux-system.yaml,
# apps/<env>/beekeepingit-helmrelease.yaml must exist and its
# `spec.chart.spec.sourceRef` must be {kind: GitRepository, name: beekeepingit}
# (a `namespace` alongside is ignored). Without this, a PR could add a second
# GitRepository on `branch: main` and repoint the HelmRelease at it — the pin
# on `beekeepingit` would still pass while no longer pinning anything. The
# fixtures under scripts/fixtures/ are standalone files with no apps/ sibling,
# so this second assertion is skipped for them; scripts/check-chart-pin-test.sh
# proves it on a throwaway copy of the real tree via `--root`.
#
# WHY: Flux takes the umbrella chart from a *git* source, and for a git source
# the `ref` is the ONLY thing pinning chart content (`chart.spec.version` is
# ignored). A chart ref on `main` means every merge re-renders the chart onto
# that cluster ungated — exactly the unreviewed deploy path the ADR-0018 addendum
# closed for staging/prod by pinning the ref to the release tag that
# release-deploy.yml's promotion PR bumps. This check makes that pin a CI
# invariant instead of a convention (#611). It COMPLEMENTS, and does not replace,
# the release-time guard in the code repo: release-deploy.yml refuses to promote
# unless the cluster file has exactly one non-comment `tag:` line — that guard
# runs only at release time, this one on every PR here.
#
# RUN LOCALLY (needs mikefarah yq v4 on PATH):
#   bash scripts/check-chart-pin.sh                       # every clusters/*/flux-system.yaml
#   bash scripts/check-chart-pin.sh clusters/dev/flux-system.yaml   # one or more files
#   bash scripts/check-chart-pin.sh --root <dir>          # treat <dir> as the repo root
#   bash scripts/check-chart-pin-test.sh                  # the fixture suite
# `--root <dir>` (or CHART_PIN_ROOT=<dir>) overrides the repo root the default
# file set and the apps/<env>/ lookup are resolved from; the test runner uses it
# to point the check at a temporary tree. Exit status: 0 all pass, 1 any
# failure, 2 yq missing or bad usage. Under GITHUB_ACTIONS each failure is also
# emitted as a `::error file=...::` workflow annotation.
set -euo pipefail

annotation='gitops.beekeepingit/chart-ref-policy'
chart_source='beekeepingit'

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="${CHART_PIN_ROOT:-$(cd "$script_dir/.." && pwd)}"

files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ]; then
        echo "✗ [chart-pin] --root needs a directory" >&2
        exit 2
      fi
      repo_root="$2"
      shift 2
      ;;
    --root=*)
      repo_root="${1#--root=}"
      shift
      ;;
    *)
      files+=("$1")
      shift
      ;;
  esac
done

if ! resolved_root="$(cd "$repo_root" 2>/dev/null && pwd)"; then
  echo "✗ [chart-pin] root directory does not exist: $repo_root" >&2
  exit 2
fi
repo_root="$resolved_root"

if ! command -v yq >/dev/null 2>&1; then
  echo "✗ [chart-pin] yq (mikefarah, v4) is required but was not found on PATH — https://github.com/mikefarah/yq" >&2
  exit 2
fi

fail() { # <file> <reason>
  echo "✗ [chart-pin] $1: $2" >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error file=$1::$2"
  fi
}

pass() { # <file> <message>
  echo "› [chart-pin] $1: $2"
}

# Explicit arguments are taken as given (relative to the caller's cwd); the
# default set is resolved from the repo root and printed repo-relative so the
# `::error file=` annotations point at the right path.
prefix=""
if [ "${#files[@]}" -eq 0 ]; then
  prefix="$repo_root/"
  for f in "$repo_root"/clusters/*/flux-system.yaml; do
    [ -e "$f" ] || continue
    files+=("${f#"$prefix"}")
  done
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "✗ [chart-pin] no clusters/*/flux-system.yaml found under $repo_root — refusing a vacuous pass" >&2
  exit 1
fi

# One yq pass per file, emitting five lines: <doc count>, <sorted ref keys
# joined by ",">, <tag value>, <branch value>, <annotation value>. Comments are
# stripped so a `# ...` above the ref key can never leak into the values.
query="[select(.kind == \"GitRepository\" and .metadata.name == \"$chart_source\")]
  | ((.[0].spec.ref // {}) | keys | sort | join(\",\")) as \$k
  | (.[0].spec.ref.tag // \"\") as \$t
  | (.[0].spec.ref.branch // \"\") as \$b
  | (.[0].metadata.annotations[\"$annotation\"] // \"\") as \$p
  | [length, \$k, \$t, \$b, \$p] | .[] | ... comments=\"\""

# One yq pass per HelmRelease file, emitting three lines: <HelmRelease doc
# count>, <sourceRef.kind>, <sourceRef.name>.
hr_query='[select(.kind == "HelmRelease")]
  | [length, (.[0].spec.chart.spec.sourceRef.kind // ""), (.[0].spec.chart.spec.sourceRef.name // "")]
  | .[] | ... comments=""'

failed=0
for file in "${files[@]}"; do
  path="$prefix$file"
  if [ ! -f "$path" ]; then
    fail "$file" "file not found"
    failed=1
    continue
  fi
  if ! out="$(yq eval-all "$query" "$path" 2>&1)"; then
    fail "$file" "yq could not evaluate the file: ${out//$'\n'/ }"
    failed=1
    continue
  fi
  mapfile -t got <<< "$out"
  count="${got[0]:-0}"
  keys="${got[1]:-}"
  tag="${got[2]:-}"
  branch="${got[3]:-}"
  policy="${got[4]:-}"

  if [ "$count" != "1" ]; then
    fail "$file" "expected exactly one GitRepository named '$chart_source' (the chart source), found $count"
    failed=1
    continue
  fi

  case "$policy" in
    "")
      if [ "$keys" != "tag" ]; then
        fail "$file" "chart source '$chart_source' spec.ref must be exactly {tag: <release>} — got keys [${keys:-none}]. A git-source ref is the only chart pin (ADR-0018 addendum, #611); if this cluster really must track main, declare it: metadata.annotations[\"$annotation\"]: track-main"
        failed=1
        continue
      fi
      if [ -z "$tag" ]; then
        fail "$file" "chart source '$chart_source' spec.ref.tag is empty — pin it to a release tag"
        failed=1
        continue
      fi
      message="chart source pinned to tag $tag"
      ;;
    track-main)
      if [ "$keys" != "branch" ] || [ "$branch" != "main" ]; then
        fail "$file" "annotation $annotation=track-main requires spec.ref to be exactly {branch: main} — got keys [${keys:-none}]${branch:+, branch=$branch}"
        failed=1
        continue
      fi
      message="chart source tracks branch main — exempt by its own declaration ($annotation=track-main)"
      ;;
    *)
      fail "$file" "unknown value '$policy' for annotation $annotation — the only recognised value is track-main (or remove the annotation and pin a tag)"
      failed=1
      continue
      ;;
  esac

  # The sourceRef assertion applies only to a file that really sits at
  # <root>/clusters/<env>/flux-system.yaml — that is where an apps/<env>/
  # sibling is guaranteed. Fixtures (scripts/fixtures/*.yaml) and any other
  # explicitly named file skip it.
  env=""
  abs="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
  case "$abs" in
    "$repo_root"/clusters/*/flux-system.yaml)
      env="${abs#"$repo_root"/clusters/}"
      env="${env%/flux-system.yaml}"
      [[ "$env" == */* ]] && env=""
      ;;
  esac
  if [ -n "$env" ]; then
    hr="apps/$env/beekeepingit-helmrelease.yaml"
    hr_path="$repo_root/$hr"
    if [ ! -f "$hr_path" ]; then
      fail "$file" "$hr is missing — the chart pin only holds if that HelmRelease sources its chart from GitRepository '$chart_source'"
      failed=1
      continue
    fi
    if ! hr_out="$(yq eval-all "$hr_query" "$hr_path" 2>&1)"; then
      fail "$hr" "yq could not evaluate the file: ${hr_out//$'\n'/ }"
      failed=1
      continue
    fi
    mapfile -t hr_got <<< "$hr_out"
    hr_count="${hr_got[0]:-0}"
    hr_kind="${hr_got[1]:-}"
    hr_name="${hr_got[2]:-}"
    if [ "$hr_count" != "1" ]; then
      fail "$hr" "expected exactly one HelmRelease, found $hr_count"
      failed=1
      continue
    fi
    if [ "$hr_kind" != "GitRepository" ] || [ "$hr_name" != "$chart_source" ]; then
      fail "$hr" "spec.chart.spec.sourceRef must be {kind: GitRepository, name: $chart_source} — got {kind: ${hr_kind:-none}, name: ${hr_name:-none}}. Sourcing the chart from anything else bypasses the pin in $file (#611)"
      failed=1
      continue
    fi
    message="$message; $hr sources its chart from it"
  fi

  pass "$file" "$message"
done

exit "$failed"
