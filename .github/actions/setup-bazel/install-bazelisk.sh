#!/usr/bin/env bash

set -euo pipefail

# Download the bazelisk launcher binary from GitHub releases, place it on
# PATH for subsequent workflow steps. Idempotent: skips download if the
# launcher is already present at the expected path.
#
# Env:
#   BAZELISK_VERSION  version tag, e.g. v1.29.0 (required)
#   BAZELISK_BIN_DIR  install directory (default: $RUNNER_TEMP/bazelisk-bin)
#
# Side effects:
#   Writes the launcher binary as $BAZELISK_BIN_DIR/bazel (or bazel.exe on Windows).
#   Appends $BAZELISK_BIN_DIR to $GITHUB_PATH so later steps see it.

_self="$(basename "$0")"
err() { printf '::error::%s: %s\n' "$_self" "$*" >&2; }
log() { printf '[%s] %s\n' "$_self" "$*" >&2; }

: "${BAZELISK_VERSION:?BAZELISK_VERSION must be set}"

bin_dir="${BAZELISK_BIN_DIR:-${RUNNER_TEMP:-/tmp}/bazelisk-bin}"
mkdir -p "$bin_dir"

case "$(uname -s)" in
Linux*) os=linux ;;
Darwin*) os=darwin ;;
MINGW* | CYGWIN* | MSYS*) os=windows ;;
*)
    err "unknown uname -s: $(uname -s)"
    exit 1
    ;;
esac

case "$(uname -m)" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*)
    err "unknown uname -m: $(uname -m)"
    exit 1
    ;;
esac

bin_name="bazel"
asset="bazelisk-${os}-${arch}"
if [[ $os == windows ]]; then
    asset="${asset}.exe"
    bin_name="bazel.exe"
fi

dest="$bin_dir/$bin_name"

if [[ -x $dest ]]; then
    log "launcher already present at $dest"
else
    url="https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/${asset}"
    log "downloading $url"
    curl --fail --location --silent --show-error --output "$dest" "$url"
    chmod +x "$dest"
    log "installed launcher to $dest"
fi

if [[ -n ${GITHUB_PATH:-} ]]; then
    echo "$bin_dir" >>"$GITHUB_PATH"
fi
