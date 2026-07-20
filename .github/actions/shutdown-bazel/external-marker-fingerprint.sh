#!/usr/bin/env bash

set -euo pipefail

# Stable sha256 of `external/@*.marker` first-lines under Bazel's output_base.
# Drives the markerhash component of the save key so `reproducible = True`
# rule changes outside MODULE.bazel.lock still invalidate the cache.
#
# First-line vs full-content: the first line of each marker is Bazel's
# canonical repo-rule-input key, deterministic given the same MODULE.bazel.lock
# and workspace files. Later lines capture transitive state that depends on
# bazel's materialization order, which is what caused cross-commit
# churn during the TypeScript port. Hashing only first lines tolerates
# materialization-order changes while still invalidating on real rule input
# changes.
#
# Usage: external-marker-fingerprint.sh [output_base]
#
# Stdout: sha256 of the included markers' first lines, or a sentinel for
# the empty case.

_self="$(basename "$0")"
log() { printf '[%s] %s\n' "$_self" "$*" >&2; }

empty_marker='0000000000000000000000000000000000000000000000000000000000000000'
output_base="${1:-}"

if [[ -z $output_base ]]; then
    output_base=$(bazel info output_base 2>/dev/null || true)
fi

if [[ -z $output_base || ! -d "$output_base/external" ]]; then
    log "marker count: 0 (no output_base/external)"
    echo "$empty_marker"
    exit 0
fi

# Excluded markers capture per-runner state, not repository content:
#   *local_config*    host autoconfigure (shell/Swift install layout)
#   *rules_oci*       OCI manifests with registry response state
#   *aws_py_lambda*   aspect_rules_aws platform-specific Lambda images
is_excluded() {
    case "$1" in
    *local_config* | *rules_oci* | *aws_py_lambda*) return 0 ;;
    esac
    return 1
}

markers=()
excluded_count=0
while IFS= read -r -d '' f; do
    name="${f##*/}"
    if is_excluded "$name"; then
        excluded_count=$((excluded_count + 1))
        continue
    fi
    markers+=("$f")
done < <(find "$output_base/external" -maxdepth 1 -name '@*.marker' -type f -print0 | LC_ALL=C sort -z)

if ((${#markers[@]} == 0)); then
    log "marker count: 0 (excluded: $excluded_count)"
    echo "$empty_marker"
    exit 0
fi

firstline_sha=$(for m in "${markers[@]}"; do head -n 1 "$m" 2>/dev/null || true; done | sha256sum | cut -d ' ' -f 1)

log "marker count: ${#markers[@]} (excluded: $excluded_count)"
log "firstline-sha256: $firstline_sha"

# Distinguish empty external/ (sha256 of all-empty-first-lines) from a real
# digest. sha256 of N empty first lines (each represented as just "\n") is
# its own fingerprint; the truly-empty case is handled by the empty-markers
# branch above, but we also guard against marker files all being zero-byte.
if [[ $firstline_sha == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]]; then
    echo "$empty_marker"
else
    echo "$firstline_sha"
fi
