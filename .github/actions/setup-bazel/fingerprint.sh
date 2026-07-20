#!/usr/bin/env bash

set -euo pipefail

# Emit `key=value` metadata lines consumed both as GITHUB_OUTPUT step outputs
# and persisted into .bazel-cache-fingerprint for shutdown-bazel to replay.
# Output shape is suitable for `tee` into both sinks.
#
#   platform          <os>-<arch>, Node.js convention (linux-x64, darwin-arm64)
#   version           .bazelversion content (the Bazel release bazelisk dispatches to)
#   hash              sha256 over a canonical JSON subset of MODULE.bazel.lock
#                     that only captures repository-resolution-affecting fields,
#                     so cosmetic edits don't churn the cache
#   bazelisk_version  $BAZELISK_VERSION env (the launcher release tag)
#   bazelisk_path     platform-specific directory Bazelisk uses for downloaded
#                     Bazel releases (mirrors Go's os.UserCacheDir())
#
# Reads from CWD:
#   MODULE.bazel.lock
#   .bazelversion
#
# Reads from env:
#   BAZELISK_VERSION  required, propagates the action input

_self="$(basename "$0")"
err() { printf '::error::%s: %s\n' "$_self" "$*" >&2; }

[[ -n ${BAZELISK_VERSION:-} ]] || {
    err "BAZELISK_VERSION env var not set"
    exit 1
}

lock_file="MODULE.bazel.lock"
version_file=".bazelversion"

[[ -f $lock_file ]] || {
    err "$lock_file not found"
    exit 1
}
[[ -f $version_file ]] || {
    err "$version_file not found"
    exit 1
}

version=$(tr -d '[:space:]' <"$version_file")
[[ -n $version ]] || {
    err "$version_file is empty"
    exit 1
}

# Bazelisk's downloads dir mirrors Go's os.UserCacheDir(): platform-specific per OS,
# no arch component. Computed alongside `platform=` since both derive from uname.
case "$(uname -s)" in
Linux*)
    os=linux
    bazelisk_path="$HOME/.cache/bazelisk"
    ;;
Darwin*)
    os=darwin
    bazelisk_path="$HOME/Library/Caches/bazelisk"
    ;;
MINGW* | CYGWIN* | MSYS*)
    os=win32
    bazelisk_path="$HOME/AppData/Local/bazelisk"
    ;;
*)
    err "unknown uname -s: $(uname -s)"
    exit 1
    ;;
esac

case "$(uname -m)" in
x86_64 | amd64) arch=x64 ;;
aarch64 | arm64) arch=arm64 ;;
*)
    err "unknown uname -m: $(uname -m)"
    exit 1
    ;;
esac

fingerprint=$(jq -cS '
  {
    lockFileVersion: (.lockFileVersion // error(".lockFileVersion missing or null")),
    registryFileHashes: (.registryFileHashes // {}),
    selectedYankedVersions: (.selectedYankedVersions // {}),
    moduleExtensions: ((.moduleExtensions // {})
      | to_entries
      | map(
          .key as $ext
          | {
              key: $ext,
              value: (
                .value
                | to_entries
                | map(
                    .key as $sub
                    | {
                        key: $sub,
                        value: {
                          bzlTransitiveDigest: (
                            .value.bzlTransitiveDigest
                            // error("\($ext) -> \($sub): bzlTransitiveDigest missing or null")
                          ),
                          usagesDigest: (
                            .value.usagesDigest
                            // error("\($ext) -> \($sub): usagesDigest missing or null")
                          )
                        }
                      }
                  )
                | from_entries
              )
            }
        )
      | from_entries
    ),
    facts: (.facts // {})
  }
' "$lock_file" | sha256sum | cut -d ' ' -f 1)

printf 'platform=%s-%s\n' "$os" "$arch"
printf 'fingerprint=%s\n' "$fingerprint"
printf 'bazel_version=%s\n' "$version"
printf 'bazelisk_version=%s\n' "$BAZELISK_VERSION"
printf 'bazelisk_path=%s\n' "$bazelisk_path"
