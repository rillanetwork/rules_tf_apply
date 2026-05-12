#!/usr/bin/env bash

# Generic terraform runner. Forwards all arguments to `terraform -chdir=$TF_DIR`,
# with best-effort symlinking of .terraform, .terraform.lock.hcl, and plan.tfplan
# from the bazel-tf output directory back into the module source directory.
#
# Usage: bazel run //path:my_module.tf -- <subcommand> [flags...]
# Examples:
#   bazel run //path:my_module.tf -- validate
#   bazel run //path:my_module.tf -- state list
#   bazel run //path:my_module.tf -- output
#   bazel run //path:my_module.tf -- destroy -auto-approve

set -euo pipefail

TF_BIN_PATH="${PWD}/%TF_BIN_PATH%"
TF_DIR="%TF_DIR%"
TF_PLUGINS_DIR="${PWD}/%TF_PLUGINS_DIR%"

if [ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    echo "BUILD_WORKSPACE_DIRECTORY is not set. Please set it before running this script."
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "Usage: bazel run <target> -- <terraform-subcommand> [flags...]" >&2
    echo "Examples:" >&2
    echo "  bazel run <target> -- validate" >&2
    echo "  bazel run <target> -- state list" >&2
    echo "  bazel run <target> -- destroy -auto-approve" >&2
    exit 2
fi

OUT_DIR="$BUILD_WORKSPACE_DIRECTORY/bazel-tf/$TF_DIR"

# Best-effort symlink the inited state back into the module dir. We don't
# require these to exist — pre-init commands like `fmt` and `validate` work
# without them, and terraform itself emits a clear error for commands that
# need init.
if [ -d "$OUT_DIR/.terraform" ]; then
    test -e "$TF_DIR/.terraform" && rm -rf "$TF_DIR/.terraform"
    ln -sfn "$OUT_DIR/.terraform" "$TF_DIR/.terraform"
fi
if [ -f "$OUT_DIR/.terraform.lock.hcl" ]; then
    test -e "$TF_DIR/.terraform.lock.hcl" && rm -rf "$TF_DIR/.terraform.lock.hcl"
    ln -sfn "$OUT_DIR/.terraform.lock.hcl" "$TF_DIR/.terraform.lock.hcl"
fi
if [ -f "$OUT_DIR/plan.tfplan" ]; then
    test -e "$TF_DIR/plan.tfplan" && rm -rf "$TF_DIR/plan.tfplan"
    ln -sfn "$OUT_DIR/plan.tfplan" "$TF_DIR/plan.tfplan"
fi

exec "$TF_BIN_PATH" -chdir="$TF_DIR" "$@"
