import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from run import copy_plan_json_artifact, module_entry, plan_artifact_filename


class PlanArtifactFilenameTest(unittest.TestCase):
    def test_maps_label_with_slashes_and_colon(self):
        self.assertEqual(
            plan_artifact_filename("//terraform/dev:gateway_service"),
            "terraform--dev--gateway_service.json",
        )

    def test_maps_nested_package(self):
        self.assertEqual(
            plan_artifact_filename("//terraform/stacks/api:api-stores"),
            "terraform--stacks--api--api-stores.json",
        )


class ModuleEntryTest(unittest.TestCase):
    def test_shape(self):
        self.assertEqual(
            module_entry("//terraform/dev:gateway_service"),
            {
                "package": "terraform/dev",
                "name": "gateway_service",
                "skip": False,
                "affected": True,
            },
        )

    def test_skip_and_affected_are_constant(self):
        entry = module_entry("//terraform/dev:api")
        self.assertFalse(entry["skip"])
        self.assertTrue(entry["affected"])


class CopyPlanJsonArtifactTest(unittest.TestCase):
    def test_copies_emitted_file_under_contract_name(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            module_dir = root / "bazel-tf" / "terraform" / "stacks" / "local"
            module_dir.mkdir(parents=True)
            (module_dir / "plan.tfplan.json").write_text('{"format_version":"1.2"}')
            artifacts = root / "artifacts"
            artifacts.mkdir()

            copy_plan_json_artifact(
                artifacts,
                "//terraform/local:local",
                root,
                module_pkg="terraform/stacks/local",
            )

            out = artifacts / "terraform--local--local.json"
            self.assertEqual(out.read_text(), '{"format_version":"1.2"}')

    def test_missing_emitted_file_warns_and_skips(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            stderr = io.StringIO()

            with contextlib.redirect_stderr(stderr):
                copy_plan_json_artifact(
                    artifacts,
                    "//terraform/local:local",
                    root,
                    module_pkg="terraform/stacks/local",
                )

            self.assertFalse((artifacts / "terraform--local--local.json").exists())
            self.assertIn("[WARN]", stderr.getvalue())

    def test_unresolved_module_warns_and_skips(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            stderr = io.StringIO()

            with contextlib.redirect_stderr(stderr):
                copy_plan_json_artifact(
                    artifacts, "//terraform/local:local", root, module_pkg=None
                )

            self.assertFalse((artifacts / "terraform--local--local.json").exists())
            self.assertIn("[WARN]", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
