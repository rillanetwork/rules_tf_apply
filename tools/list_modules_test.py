import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import list_modules


class ParseTargetTest(unittest.TestCase):
    def test_emits_only_cloud_neutral_fields(self):
        row = list_modules.parse_target(
            "//terraform/dev:gateway_service",
            manual_targets=set(),
            affected={"//terraform/dev:gateway_service"},
            mod_packages={},
        )
        self.assertEqual(
            set(row.keys()),
            {"package", "module_package", "name", "skip", "affected"},
        )
        self.assertEqual(row["package"], "terraform/dev")
        self.assertEqual(row["name"], "gateway_service")
        self.assertEqual(row["module_package"], "terraform/dev")
        self.assertFalse(row["skip"])
        self.assertTrue(row["affected"])

    def test_skip_from_manual_targets(self):
        row = list_modules.parse_target(
            "//terraform/dev:manual_stack",
            manual_targets={"//terraform/dev:manual_stack"},
            affected=set(),
            mod_packages={},
        )
        self.assertTrue(row["skip"])
        self.assertFalse(row["affected"])

    def test_module_package_override(self):
        row = list_modules.parse_target(
            "//terraform/local:local",
            manual_targets=set(),
            affected=set(),
            mod_packages={"//terraform/local:local": "terraform/stacks/local"},
        )
        self.assertEqual(row["module_package"], "terraform/stacks/local")

    def test_multi_root_package_mixed_skip(self):
        # Two roots in one package: deploy:manual on one must not suppress
        # its CI-deployed sibling.
        manual = {"//terraform/aws/audit/global:guardduty.plan"}
        manual_row = list_modules.parse_target(
            "//terraform/aws/audit/global:guardduty.plan",
            manual_targets=manual,
            affected=set(),
            mod_packages={},
        )
        ci_row = list_modules.parse_target(
            "//terraform/aws/audit/global:lambda-error-alerts.plan",
            manual_targets=manual,
            affected=set(),
            mod_packages={},
        )
        self.assertTrue(manual_row["skip"])
        self.assertFalse(ci_row["skip"])

    def test_multi_root_package_distinct_module_packages(self):
        # Two thin roots in one package pointing at different shared stacks
        # must each resolve their own module_package (a package-keyed map
        # would collapse to one of them).
        mod_packages = {
            "//terraform/aws/audit/global:guardduty.plan": "terraform/aws/stacks/guardduty",
            "//terraform/aws/audit/global:lambda-error-alerts.plan": "terraform/aws/stacks/lambda-error-alerts",
        }
        rows = {
            t: list_modules.parse_target(
                t, manual_targets=set(), affected=set(), mod_packages=mod_packages
            )
            for t in mod_packages
        }
        self.assertEqual(
            rows["//terraform/aws/audit/global:guardduty.plan"]["module_package"],
            "terraform/aws/stacks/guardduty",
        )
        self.assertEqual(
            rows["//terraform/aws/audit/global:lambda-error-alerts.plan"]["module_package"],
            "terraform/aws/stacks/lambda-error-alerts",
        )


class DeletedFilePackageTest(unittest.TestCase):
    def test_returns_nearest_surviving_root(self):
        pkg = list_modules.deleted_file_package(
            "terraform/dev/gone.tf", {"terraform/dev"}
        )
        self.assertEqual(pkg, "terraform/dev")

    def test_none_when_package_gone(self):
        pkg = list_modules.deleted_file_package(
            "terraform/removed/gone.tf", {"terraform/dev"}
        )
        self.assertIsNone(pkg)


class AffectedTargetsTest(unittest.TestCase):
    PLAN_TARGETS = [
        "//terraform/aws/audit/global:guardduty.plan",
        "//terraform/aws/audit/global:lambda-error-alerts.plan",
        "//terraform/dev:api.plan",
    ]

    def test_no_base_ref_returns_all(self):
        self.assertEqual(
            list_modules.affected_targets("", self.PLAN_TARGETS),
            set(self.PLAN_TARGETS),
        )

    def test_changed_build_file_expands_to_all_roots_in_package(self):
        # A changed BUILD file is only package-precise (it isn't a dep of any
        # .plan target), so every root declared in it must be marked affected.
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            list_modules,
            "changed_files",
            return_value=["terraform/aws/audit/global/BUILD.bazel"],
        ), mock.patch.object(
            # The changed BUILD file also flows into the rdeps universe (it
            # resolves to a label); stub the bazel query so the test doesn't
            # need a workspace — the rdeps path contributes nothing here.
            list_modules.subprocess,
            "run",
            return_value=mock.Mock(stdout=""),
        ):
            cwd = os.getcwd()
            os.chdir(tmp)
            try:
                build = Path("terraform/aws/audit/global/BUILD.bazel")
                build.parent.mkdir(parents=True)
                build.touch()
                affected = list_modules.affected_targets("origin/main", self.PLAN_TARGETS)
            finally:
                os.chdir(cwd)
        self.assertEqual(
            affected,
            {
                "//terraform/aws/audit/global:guardduty.plan",
                "//terraform/aws/audit/global:lambda-error-alerts.plan",
            },
        )

    def test_deletion_expands_to_all_roots_in_package(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            list_modules,
            "changed_files",
            return_value=["terraform/aws/audit/global/gone.tf"],
        ):
            cwd = os.getcwd()
            os.chdir(tmp)
            try:
                # The deleted file's package survives but the file is absent,
                # so it routes through deleted_file_package, not rdeps.
                Path("terraform/aws/audit/global").mkdir(parents=True)
                affected = list_modules.affected_targets("origin/main", self.PLAN_TARGETS)
            finally:
                os.chdir(cwd)
        self.assertEqual(
            affected,
            {
                "//terraform/aws/audit/global:guardduty.plan",
                "//terraform/aws/audit/global:lambda-error-alerts.plan",
            },
        )


if __name__ == "__main__":
    unittest.main()
