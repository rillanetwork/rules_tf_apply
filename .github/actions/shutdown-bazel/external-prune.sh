#!/usr/bin/env bash

set -euo pipefail

# Drop oversized `~/.cache/bazel-repo/contents/<hash>/<UUID>/` extractions
# before save. Heavy extractions re-fetch from still-cached raw archives
# next run, keeping macOS+Linux saves under GHA's 10 GB per-repo budget.
#
# Env:
#   MAX_MB    threshold in MB (required, non-negative integer)
#   CONTENTS  contents/ directory (default: $HOME/.cache/bazel-repo/contents)
#
# Stdout: None. Progress is emitted to stderr.

_self="$(basename "$0")"
err() { printf '::error::%s: %s\n' "$_self" "$*" >&2; }
log() { printf '[%s] %s\n' "$_self" "$*" >&2; }

: "${MAX_MB:?MAX_MB must be set}"
contents="${CONTENTS:-$HOME/.cache/bazel-repo/contents}"

if [[ ! $MAX_MB =~ ^[0-9]+$ ]]; then
    err "MAX_MB ${MAX_MB@Q} must be a non-negative integer"
    exit 1
fi

if [[ ! -d $contents ]]; then
    log "no contents/ directory to prune"
    exit 0
fi

max_kb=$((MAX_MB * 1024))
log "threshold: ${MAX_MB}M (${max_kb}K)"
log "pre-prune contents/ size: $(du -sh "$contents" | cut -f1)"

# Sweep orphan `.recorded_inputs` records whose paired UUID dir is missing.
# Leaving them makes Bazel believe a stale UUID is still valid.
orphans=0
while IFS= read -r -d '' record; do
    uuid_dir="${record%.recorded_inputs}"
    if [[ ! -d $uuid_dir ]]; then
        rm -f -- "$record"
        orphans=$((orphans + 1))
    fi
done < <(find "$contents" -mindepth 2 -maxdepth 2 -type f -name '*.recorded_inputs' -print0)
log "removed ${orphans} orphan .recorded_inputs records"

# Bazel GC moves stale extractions to _trash, useless in a saved cache.
if [[ -d "$contents/_trash" ]]; then
    trash_size=$(du -sh "$contents/_trash" | cut -f1)
    rm -rf -- "$contents/_trash"
    log "removed contents/_trash (${trash_size})"
fi

# Pair each oversized `<hash>/<UUID>/` with its sibling `<UUID>.recorded_inputs`,
# removing one without the other points Bazel at a missing path next build.
pruned=0
kept=0
while IFS=$'\t' read -r size_kb dir; do
    if ((size_kb > max_kb)); then
        rm -rf -- "$dir" "${dir}.recorded_inputs"
        log "$(printf 'pruned %6sM  %s' "$((size_kb / 1024))" "$dir")"
        pruned=$((pruned + 1))
    else
        kept=$((kept + 1))
    fi
done < <(
    find "$contents" -mindepth 2 -maxdepth 2 -type d -exec du -sk {} + 2>/dev/null |
        sort -rn
)
log "pruned ${pruned} extractions, kept ${kept}"
log "post-prune contents/ size: $(du -sh "$contents" 2>/dev/null | cut -f1 || echo 0)"
