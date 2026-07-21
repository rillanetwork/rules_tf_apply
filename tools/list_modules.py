#!/usr/bin/env python3
"""List all terraform root modules as a JSON matrix for CI consumers.

Each entry:
  {"package": "...", "module_package": "...", "name": "...",
   "skip": bool, "affected": bool}

This tool is cloud-neutral by design: it emits only module identity plus the
skip/affected classification that every consumer needs. Consumers that key CI
off deployment topology (e.g. an AWS account per module) decorate these rows
with their own fields from their own path convention — the ruleset does not
own any tenant's cloud/account layout.

Modules tagged with ``deploy:manual`` on their ``tf_plan`` target are flagged
as skip=true so CI does not attempt to plan/apply them.

``affected`` is true when the module's transitive bazel deps include a file
changed between ``BASE_REF`` (env, e.g. ``origin/main``) and ``HEAD``. When
``BASE_REF`` is unset, every module is treated as affected so consumers that
don't care about change detection see the full list.

A package may declare several ``tf_root_module`` targets (e.g. one BUILD file
per account/region holding every root deployed there), so all classification
here — skip, module_package, affected — is keyed by the ``.plan`` target
label, never by package. Signals that are only package-precise (a changed
BUILD file, a deleted path) expand to every plan target in that package.

Positional arg ``query_path`` (default ``//terraform/...``) scopes the module
query so each repo can point at its own tree.
"""

import json
import os
import subprocess
import sys
from pathlib import Path


def list_plan_targets(query_path: str) -> list[str]:
    result = subprocess.run(
        ["bazel", "query", f"kind(tf_plan, {query_path})"],
        capture_output=True,
        text=True,
        check=True,
    )
    return sorted({t for t in result.stdout.splitlines() if t.endswith(".plan")})


def list_manual_targets(query_path: str) -> set[str]:
    """Return plan target labels tagged deploy:manual.

    Keyed by label, not package: a CI-deployed root and a manual root can
    share a package, and a package-level skip would suppress the wrong one.
    """
    result = subprocess.run(
        ["bazel", "query", f'attr(tags, "deploy:manual", kind(tf_plan, {query_path}))'],
        capture_output=True,
        text=True,
        check=True,
    )
    return {t for t in result.stdout.splitlines() if t.endswith(".plan")}


def module_packages(query_path: str) -> dict[str, str]:
    """Map each tf_plan target label to the package of its `module`.

    A ``tf_root_module`` can point ``module =`` at a reusable module in a
    different package (one shared module instantiated by several thin roots,
    each injecting its own region/labels/backend via tfvars). rules_tf_apply
    renders the terraform working directory at that *module* package — so CI
    must chdir there to read the plan, not at the root's own package. For the
    common ``module = ":self"`` case the two are identical, so consumers can
    treat this as a no-op for every conventional module.

    Keyed by target label: two thin roots in one package can point at
    different shared stacks, so a package-keyed map would silently collapse
    to whichever root the query emitted last.
    """
    result = subprocess.run(
        ["bazel", "query", f"kind(tf_plan, {query_path})", "--output", "streamed_jsonproto"],
        capture_output=True,
        text=True,
        check=True,
    )
    mapping: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        rule = json.loads(line)["rule"]
        name = rule["name"]
        if not name.endswith(".plan"):
            continue
        for attr in rule.get("attribute", []):
            if attr["name"] == "module":
                mapping[name] = attr["stringValue"].removeprefix("//").split(":")[0]
                break
    return mapping


def changed_files(base_ref: str) -> list[str]:
    # Two-dot diff (not three-dot): we don't require the merge-base to be
    # reachable, which lets the workflow get away with a shallow fetch of
    # just the base ref. Over-reporting (when base has advanced since branch
    # point) is harmless — extra modules in the affected set just widens the
    # warning slightly; under-reporting would silently hide work.
    result = subprocess.run(
        ["git", "diff", "--name-only", base_ref, "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def file_to_label(path: str) -> str | None:
    """Map an existing filesystem path to its bazel label.

    Walks up from the file's directory until a BUILD.bazel/BUILD is found.
    Returns None when the file no longer exists on disk — deletions are
    handled separately in :func:`affected_packages`, since a deleted path
    has no resolvable label (`bazel query` would exit 7) and the natural
    parent-walk would mis-attribute it to whichever surviving ancestor
    package has a BUILD file (often the repo root).

    Also returns None when the only enclosing BUILD is the repo root. The
    root package declares no ``tf_module`` (its BUILD has only tf_format /
    buildifier / alias), so a stray file like ``terraform/aws/root/README.md``
    — which lands in package "" purely by parent-walk — is *not* a declared
    target there. ``tf_module`` globs ``**/*``, so files inside a real module
    package (even nested ones) are declared and resolve fine; only files with
    no ``tf_module`` ancestor fall through to root. Such a label exits 7 and
    fails the *entire* ``rdeps`` query, and the file isn't a dep of any module
    anyway, so skip it.
    """
    p = Path(path)
    if not p.is_file():
        return None
    for cur in [p.parent, *p.parent.parents]:
        if (cur / "BUILD.bazel").is_file() or (cur / "BUILD").is_file():
            if str(cur) == ".":
                return None
            rel = p.relative_to(cur)
            return f"//{cur}:{rel}"
    return None


def deleted_file_package(path: str, root_packages: set[str]) -> str | None:
    """For a deleted file, return the nearest surviving root_package ancestor.

    A deletion inside a still-existing root module (e.g. removing one
    ``.tf`` file from a package whose ``BUILD.bazel`` survives) must still
    mark that package affected — terraform's plan output changes when a
    resource definition disappears. We can't route this through ``rdeps``
    because (a) the deleted file has no resolvable label, and (b) the
    package's ``BUILD.bazel`` isn't itself a dep of the ``tf_root_module``
    rule (which globs ``.tf`` files, not the BUILD file).

    When the deletion's enclosing root package is *also* gone (full
    package teardown), returns None — nothing in the current bazel graph
    can depend on a removed package, so rdeps would yield nothing.
    """
    p = Path(path)
    for cur in [p.parent, *p.parent.parents]:
        pkg = "" if str(cur) == "." else str(cur)
        if pkg in root_packages:
            return pkg
    return None


def affected_targets(base_ref: str, plan_targets: list[str]) -> set[str]:
    """Return the set of plan target labels affected by changes since base_ref.

    With no base_ref, returns the full plan_targets set ("all affected"). The
    returned set always names ``.plan`` targets — extra labels from rdeps
    (intermediate :deps/:module targets, shared child modules) are filtered
    out via the plan_targets intersection. Package-precise signals (changed
    BUILD files, deletions) expand to every plan target in their package.
    """
    plan_target_set = set(plan_targets)
    if not base_ref or not plan_targets:
        return plan_target_set

    pkg_targets: dict[str, set[str]] = {}
    for t in plan_targets:
        pkg_targets.setdefault(t.removeprefix("//").split(":")[0], set()).add(t)
    root_packages = set(pkg_targets)

    # Repo-root files (MODULE.bazel, etc.) aren't deps of any tf_module in
    # bazel's graph, so they're invisible to rdeps. We accept under-reporting
    # for provider-version bumps and toolchain changes here — a notable
    # but deliberate scope cut.
    tf_files = [f for f in changed_files(base_ref) if f.startswith("terraform/")]
    if not tf_files:
        return set()

    # Deletions can't go through `bazel query` — the deleted label no
    # longer resolves. Short-circuit them to their enclosing root
    # package directly. Existing/modified files still flow through
    # rdeps so that shared child modules propagate to all dependents.
    affected: set[str] = set()
    existing_files: list[str] = []
    for f in tf_files:
        if Path(f).is_file():
            existing_files.append(f)
            # A "thin" root package (tf_root_module wrapping a shared stack)
            # carries all of its config — tfvars, backend, module ref — in
            # BUILD.bazel and has no local .tf. The BUILD file isn't a dep of
            # the .plan target, so rdeps can't see it; short-circuit a changed
            # BUILD straight to its package, as we do for deletions below.
            if Path(f).name in ("BUILD.bazel", "BUILD"):
                pkg = str(Path(f).parent)
                affected.update(pkg_targets.get(pkg, set()))
        else:
            pkg = deleted_file_package(f, root_packages)
            if pkg is not None:
                affected.update(pkg_targets[pkg])

    file_labels = [lbl for lbl in (file_to_label(f) for f in existing_files) if lbl]
    if not file_labels:
        return affected

    universe = " ".join(plan_targets)
    changed = " ".join(file_labels)
    query = f"rdeps(set({universe}), set({changed}))"
    result = subprocess.run(
        ["bazel", "query", query],
        capture_output=True,
        text=True,
        check=True,
    )

    for line in result.stdout.splitlines():
        if line in plan_target_set:
            affected.add(line)
    return affected


def parse_target(target: str, manual_targets: set[str], affected: set[str], mod_packages: dict[str, str]) -> dict:
    label = target.removeprefix("//")
    package, target_name = label.split(":")
    name = target_name.removesuffix(".plan")

    return {
        "package": package,
        # Package whose bazel-tf working dir holds the rendered terraform; equals
        # `package` unless the tf_root_module points module= at a shared module
        # elsewhere (thin injected roots). CI chdirs here to read the plan.
        "module_package": mod_packages.get(target, package),
        "name": name,
        "skip": target in manual_targets,
        "affected": target in affected,
    }


def main():
    # `bazel run` executes from an ephemeral runfiles dir, so the bazel query
    # and git subprocesses below (which use relative paths and expect to be at
    # the workspace root) must be anchored there. BUILD_WORKSPACE_DIRECTORY is
    # set by `bazel run`; when absent (direct script invocation / tests) we
    # stay in the current dir, matching this tool's plain-script origin.
    workspace_dir = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if workspace_dir:
        os.chdir(workspace_dir)

    query_path = sys.argv[1] if len(sys.argv) > 1 else "//terraform/..."
    targets = list_plan_targets(query_path)
    manual_targets = list_manual_targets(query_path)
    base_ref = os.environ.get("BASE_REF", "")
    # The rdeps universe is the plan targets themselves: a thin tf_root_module
    # package only emits dotted targets (:name.plan, .tf, …) and no bare :name,
    # so stripping `.plan` would yield an undeclared label and abort the query.
    affected = affected_targets(base_ref, targets)
    mod_packages = module_packages(query_path)
    modules = [parse_target(t, manual_targets, affected, mod_packages) for t in targets]
    print(json.dumps(modules))


if __name__ == "__main__":
    main()
