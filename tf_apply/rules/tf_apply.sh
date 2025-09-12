#!/bin/sh

# Invokes `terraform apply` in the specified Terraform directory.
# It needs terraform plan to be run first and depends on the plan generated
# on the bazel-tf directory.

TF_BIN_PATH="${PWD}/%TF_BIN_PATH%"
TF_DIR="%TF_DIR%"
TF_PLUGINS_DIR="${PWD}/%TF_PLUGINS_DIR%"

if [ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    echo "BUILD_WORKSPACE_DIRECTORY is not set. Please set it before running this script."
    exit 1
fi

OUT_DIR="$BUILD_WORKSPACE_DIRECTORY/bazel-tf/$TF_DIR"

# Check .terraform directory and .terraform.lock.hcl file
if [ ! -d "$OUT_DIR/.terraform" ]; then
    echo ".terraform directory does not exist in $OUT_DIR please run 'terraform_plan' first."
    exit 1
fi

if [ ! -f "$OUT_DIR/.terraform.lock.hcl" ]; then
    echo ".terraform.lock.hcl file does not exist in $OUT_DIR please run 'terraform_plan' first."
    exit 1
fi

if [ ! -f "$OUT_DIR/plan.tfplan" ]; then
    echo "plan.tfplan file does not exist in $OUT_DIR please run 'terraform_plan' first."
    exit 1
fi

# symlink the .terraform directory from the output directory
# Ensure that any existing .terraform directory or .terraform.lock.hcl file is removed first
test -d "$TF_DIR/.terraform" && rm -rf "$TF_DIR/.terraform"
test -f "$TF_DIR/.terraform.lock.hcl" && rm -rf "$TF_DIR/.terraform.lock.hcl"
ln -sfn "$OUT_DIR/.terraform" "$TF_DIR/.terraform"
ln -sfn "$OUT_DIR/.terraform.lock.hcl" "$TF_DIR/.terraform.lock.hcl"
ln -sfn "$OUT_DIR/plan.tfplan" "$TF_DIR/plan.tfplan"

$TF_BIN_PATH -chdir="$TF_DIR" apply -input=false -auto-approve "plan.tfplan"
