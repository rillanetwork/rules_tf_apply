import argparse
import json
import multiprocessing as mp
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Literal, NamedTuple, Optional, Union, assert_never, final

TFAction = Literal["init", "plan", "apply"]
ArgsType = NamedTuple("ArgsType", [("query_path", str), ("actions", list[TFAction])])


@final
class TFError(Exception):
    def __init__(self, action: TFAction, target: str, stderr: str):
        self.action = action
        self.target = target
        self.stderr = stderr
        super().__init__(action, target, stderr)


@final
class TFSuccess:
    def __init__(self, action: TFAction, target: str, stdout: str):
        self.action = action
        self.target = target
        self.stdout = stdout


TFResult = Union[TFSuccess, TFError]


def find_workspace_root() -> Path:
    """Find the bazel workspace root using BUILD_WORKSPACE_DIRECTORY env var."""
    workspace_dir = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if not workspace_dir:
        raise EnvironmentError(
            "BUILD_WORKSPACE_DIRECTORY environment variable is not set."
        )

    return Path(workspace_dir)


def query_terraform_init_targets(query_path: str, workspace_root: Path) -> list[str]:
    query = f'kind("tf_init", {query_path})'

    result = subprocess.run(
        ["bazel", "query", query], capture_output=True, text=True, cwd=workspace_root
    )

    if result.returncode != 0:
        print("Error running bazel query:", result.stderr)
        return []

    return result.stdout.strip().split("\n")


def extract_terraform_error_summary(stderr: str) -> str:
    """Extract relevant error lines from terraform stderr output."""

    # Error lines in terraform starts with a ╷ line and followed by │ lines
    # These could have ASCII color codes, so we just look for the patterns.
    # ╷
    # │ Error:
    error_lines = []
    capture = False

    for line in stderr.splitlines():
        if "╷" in line and not capture:
            capture = True
            continue
        if capture:
            error_lines.append(line)

    return "\n".join(error_lines)


def extract_terraform_success_summary(stdout: str) -> str:
    """Extract summary lines from terraform stdout output."""

    summary_lines = []
    for line in stdout.splitlines():
        # Strip ANSI codes for pattern matching
        if "Plan:" in line or "Apply complete!" in line:
            summary_lines.append(line)

    return "\n".join(summary_lines)


def plan_artifact_filename(target: str) -> str:
    """Map a bazel target label to its plan-artifact JSON filename.

    ``//terraform/dev:gateway_service`` -> ``terraform--dev--gateway_service.json``
    """
    label = target.removeprefix("//").replace(":", "/")
    return label.replace("/", "--") + ".json"


def module_entry(target: str) -> dict[str, object]:
    """Describe a planned root module for ``modules.json``.

    ``//terraform/dev:gateway_service`` ->
    ``{"package": "terraform/dev", "name": "gateway_service",
       "skip": False, "affected": True}``

    ``skip``/``affected`` are constant: webrtc-sim has no deploy:manual or
    change-detection concepts, but the consuming reporting actions read these
    keys, so we emit them.
    """
    package, _, name = target.removeprefix("//").partition(":")
    return {"package": package, "name": name, "skip": False, "affected": True}


def resolve_module_pkg(target: str, workspace_root: Path) -> Optional[str]:
    """Return the package of the root module's underlying ``module``.

    ``//terraform/local:local`` -> ``terraform/stacks/local`` (via
    ``labels(module, {target}.plan)``). That package keys the output dir
    ``bazel-tf/<pkg>/`` where rules_tf_apply (>= v0.2.1) writes
    ``plan.tfplan.json``. Returns ``None`` if the query fails — the caller
    treats that as best-effort skip.
    """
    result = subprocess.run(
        ["bazel", "query", f"labels(module, {target}.plan)"],
        capture_output=True,
        text=True,
        cwd=workspace_root,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    label = result.stdout.strip().splitlines()[0]  # e.g. //terraform/stacks/local:local
    return label.removeprefix("//").partition(":")[0]


def copy_plan_json_artifact(
    plan_artifacts_dir: Path,
    target: str,
    workspace_root: Path,
    module_pkg: Optional[str],
) -> None:
    """Best-effort: copy the plan step's ``plan.tfplan.json`` into the artifacts dir.

    rules_tf_apply (>= v0.2.1), for modules built with ``output_json = True``,
    writes ``plan.tfplan.json`` into ``bazel-tf/<module_pkg>/`` during the
    ``.plan`` step. Copy it to ``plan_artifacts_dir`` under the contract name
    ``plan_artifact_filename(target)`` (e.g. ``terraform--local--local.json``).

    Emission is best-effort reporting — plan/apply success is the real signal —
    so an unresolved module (``module_pkg is None``) or a missing emitted file
    must be warned to stderr (include ``[WARN]``) and skipped, never raised.
    """
    if module_pkg is None:
        print(
            f"[WARN] Could not resolve module for {target}; skipping plan JSON",
            file=sys.stderr,
        )
        return

    src = workspace_root / "bazel-tf" / module_pkg / "plan.tfplan.json"
    if not src.exists():
        print(f"[WARN] No plan JSON emitted for {target} at {src}", file=sys.stderr)
        return

    shutil.copyfile(src, plan_artifacts_dir / plan_artifact_filename(target))


def write_plan_error_artifact(
    plan_artifacts_dir: Path, target: str, stderr: str
) -> None:
    """Write an error envelope for a failed plan.

    Mirrors core-infra's terraform-plan.yml: failed plans surface as
    ":x: plan failed" sections in the PR comment.
    """
    out_path = plan_artifacts_dir / plan_artifact_filename(target)
    envelope = {"error": extract_terraform_error_summary(stderr)}
    out_path.write_text(json.dumps(envelope))


def run_terraform_init(target: str, workspace_root: Path) -> TFResult:
    result = subprocess.run(
        ["bazel", "run", f"{target}.init"],
        capture_output=True,
        text=True,
        cwd=workspace_root,
    )

    if result.returncode != 0:
        return TFError("init", target=target, stderr=result.stderr)
    else:
        return TFSuccess("init", target, stdout=result.stdout)


def run_terraform_plan(
    target: str, workspace_root: Path, extra_var_file: Optional[str]
) -> TFResult:
    args: list[str] = ["bazel", "run", f"{target}.plan"]
    if extra_var_file:
        args.extend(["--", "-var-file", extra_var_file])

    result = subprocess.run(
        args,
        capture_output=True,
        text=True,
        cwd=workspace_root,
    )

    if result.returncode != 0:
        return TFError("plan", target=target, stderr=result.stderr)
    else:
        return TFSuccess(
            "plan",
            target=target,
            stdout=result.stdout,
        )


def run_terraform_apply(target: str, workspace_root: Path) -> TFResult:
    result = subprocess.run(
        ["bazel", "run", f"{target}.apply"],
        capture_output=True,
        text=True,
        cwd=workspace_root,
    )

    if result.returncode != 0:
        return TFError("apply", target=target, stderr=result.stderr)
    else:
        return TFSuccess("apply", target, stdout=result.stdout)


def run_terraform_action(
    action: TFAction,
    target: str,
    workspace_root: Path,
    extra_var_file: Optional[str],
) -> TFSuccess:
    if action == "init":
        result = run_terraform_init(target, workspace_root)
    elif action == "plan":
        result = run_terraform_plan(target, workspace_root, extra_var_file)
    elif action == "apply":
        result = run_terraform_apply(target, workspace_root)
    else:
        assert_never(action)

    # Immediately log full errors upon completion for fast feedback. We'll log
    # summaries at the end.
    if isinstance(result, TFError):
        print(
            f"""[ERROR] === {result.target}.{result.action} ===,
{result.stderr}""",
            file=sys.stderr,
        )

        raise result

    print(f"""[SUCCESS] === {result.target}.{result.action} ===
{result.stdout}""")

    return result


def run_terraform_actions(
    actions: list[TFAction],
    target: str,
    workspace_root: Path,
    extra_var_file: Optional[str],
    plan_artifacts_dir: Optional[Path],
) -> list[TFSuccess]:
    results: list[TFSuccess] = []
    for action in actions:
        try:
            result = run_terraform_action(
                action, target, workspace_root, extra_var_file
            )
        except TFError as e:
            # Emit an error envelope for a failed plan before propagating, so
            # the reporting actions still get an artifact for this module.
            if action == "plan" and plan_artifacts_dir is not None:
                write_plan_error_artifact(plan_artifacts_dir, target, e.stderr)
            raise

        results.append(result)

        # Copy the plan JSON emitted by the plan step after a successful plan.
        if action == "plan" and plan_artifacts_dir is not None:
            module_pkg = resolve_module_pkg(target, workspace_root)
            copy_plan_json_artifact(
                plan_artifacts_dir, target, workspace_root, module_pkg
            )

    return results


def main():
    parser = argparse.ArgumentParser(
        description="Run Terraform actions on bazel tf_root_module targets."
    )

    parser.add_argument("query_path", type=str, help="The bazel query path to search.")
    parser.add_argument(
        "actions",
        nargs="+",
        help="The terraform actions to perform.",
        choices=["init", "plan", "apply"],
    )
    parser.add_argument(
        "--extra_var_file",
        type=str,
        help="The extra var file to use for terraform plan.",
        default=None,
    )
    parser.add_argument(
        "--plan_artifacts_dir",
        type=str,
        help=(
            "If set (and 'plan' is among the actions), copy each module's "
            "plan JSON (emitted by the plan step as bazel-tf/<module>/"
            "plan.tfplan.json) to this directory as <package>--<name>.json "
            "(failed plans get an error envelope), plus a modules.json "
            "describing the planned matrix. Relative paths are resolved against "
            "the workspace root. Best-effort reporting; a missing plan JSON "
            "does not fail the run."
        ),
        default=None,
    )

    args = parser.parse_args()

    workspace_root = find_workspace_root()

    query_path: str = args.query_path
    actions: str = args.actions
    extra_var_file: Optional[str] = args.extra_var_file

    # Artifact emission is opt-in and only meaningful when we plan.
    plan_artifacts_dir: Optional[Path] = None
    if args.plan_artifacts_dir and "plan" in actions:
        plan_artifacts_dir = Path(args.plan_artifacts_dir)
        if not plan_artifacts_dir.is_absolute():
            # bazel run executes from an ephemeral runfiles dir, so anchor
            # relative paths to the workspace root where CI can upload them.
            plan_artifacts_dir = workspace_root / plan_artifacts_dir
        plan_artifacts_dir.mkdir(parents=True, exist_ok=True)

    tf_init_targets = query_terraform_init_targets(query_path, workspace_root)
    tf_targets = [target.rsplit(".init", 1)[0] for target in tf_init_targets]

    if not tf_targets:
        print("No tf_init targets found.")
        exit(1)

    # Run Terraform init for each target in parallel using multiprocessing

    successful: list[TFSuccess] = []
    failed: list[TFError] = []

    with mp.Pool(processes=min(len(tf_targets), mp.cpu_count())) as pool:
        results = [
            pool.apply_async(
                run_terraform_actions,
                args=(
                    actions,
                    target,
                    workspace_root,
                    extra_var_file,
                    plan_artifacts_dir,
                ),
            )
            for target in tf_targets
        ]

        for async_result in results:
            try:
                res = async_result.get()
                successful.extend(res)

            except TFError as e:
                failed.append(e)

        if plan_artifacts_dir is not None:
            modules = [module_entry(target) for target in tf_targets]
            (plan_artifacts_dir / "modules.json").write_text(
                json.dumps(modules, indent=2)
            )

        print("\n\n=== SUMMARY ===\n")

        # Print summaries
        for success in successful:
            print(
                f"""[SUCCESS] === {success.target}.{success.action} ===
{extract_terraform_success_summary(success.stdout)}""",
            )

        for failure in failed:
            print(
                f"""[FAILED] === {failure.target}.{failure.action} ===
{extract_terraform_error_summary(failure.stderr)}""",
            )

        print("\n\n=== COMPLETED TARGETS ===\n")

        # Print result
        for success in successful:
            print("[SUCCESS]", f"{success.target}.{success.action}")

        for failure in failed:
            print("[FAILED]", f"{failure.target}.{failure.action}")

        if len(failed) > 0:
            print(f"{len(failed)} out of {len(tf_targets)} targets failed.")
            exit(1)

        print(f"All {len(tf_targets)} targets completed successfully.")


if __name__ == "__main__":
    main()
