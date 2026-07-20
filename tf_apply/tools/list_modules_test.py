import unittest

import list_modules


class ParseTargetTest(unittest.TestCase):
    def test_emits_only_cloud_neutral_fields(self):
        row = list_modules.parse_target(
            "//terraform/dev:gateway_service",
            manual_packages=set(),
            affected={"terraform/dev"},
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

    def test_skip_from_manual_packages(self):
        row = list_modules.parse_target(
            "//terraform/dev:manual_stack",
            manual_packages={"terraform/dev"},
            affected=set(),
            mod_packages={},
        )
        self.assertTrue(row["skip"])
        self.assertFalse(row["affected"])

    def test_module_package_override(self):
        row = list_modules.parse_target(
            "//terraform/local:local",
            manual_packages=set(),
            affected=set(),
            mod_packages={"terraform/local": "terraform/stacks/local"},
        )
        self.assertEqual(row["module_package"], "terraform/stacks/local")


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


if __name__ == "__main__":
    unittest.main()
