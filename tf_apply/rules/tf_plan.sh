#!/usr/bin/env bash

# Invokes `terraform plan` in the specified Terraform directory.
# The output plan file is symlinked to bazel-tf on the workspace root.

set -euo pipefail

TF_BIN_PATH="${PWD}/%TF_BIN_PATH%"
TF_DIR="%TF_DIR%"
TF_PLUGINS_DIR="${PWD}/%TF_PLUGINS_DIR%"

if [ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    echo "BUILD_WORKSPACE_DIRECTORY is not set. Please set it before running this script."
    exit 1
fi

# Accept additional terraform arguments passed via bazel -- syntax
if [ $# -gt 0 ]; then
    echo "Additional terraform arguments provided: $*"
fi

OUT_DIR="$BUILD_WORKSPACE_DIRECTORY/bazel-tf/$TF_DIR"

# Check .terraform directory and .terraform.lock.hcl file
if [ ! -d "$OUT_DIR/.terraform" ]; then
    echo ".terraform directory does not exist in $OUT_DIR please run 'terraform_init' first."
    exit 1
fi

if [ ! -f "$OUT_DIR/.terraform.lock.hcl" ]; then
    echo ".terraform.lock.hcl file does not exist in $OUT_DIR please run 'terraform_init' first."
    exit 1
fi

# symlink the .terraform directory from the output directory
# Ensure that any existing .terraform directory or .terraform.lock.hcl file is removed first
test -d "$TF_DIR/.terraform" && rm -rf "$TF_DIR/.terraform"
test -f "$TF_DIR/.terraform.lock.hcl" && rm -rf "$TF_DIR/.terraform.lock.hcl"
test -f "$TF_DIR/plan.tfplan" && rm -rf "$TF_DIR/plan.tfplan"

ln -sfn "$OUT_DIR/.terraform" "$TF_DIR/.terraform"
ln -sfn "$OUT_DIR/.terraform.lock.hcl" "$TF_DIR/.terraform.lock.hcl"

$TF_BIN_PATH -chdir="$TF_DIR" plan -input=false -out="plan.tfplan" "$@"

# symlink the plan output to the output directory
ln -sfn "$PWD/$TF_DIR/plan.tfplan" "$OUT_DIR/plan.tfplan"
