import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("check_development_version.py")


def load_module():
    spec = importlib.util.spec_from_file_location("check_development_version", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CheckDevelopmentVersionTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_accepts_expected_development_marketing_version(self):
        errors = self.module.validate_development_version(
            "MARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 1\n"
        )

        self.assertEqual([], errors)

    def test_rejects_release_marketing_version(self):
        errors = self.module.validate_development_version(
            "MARKETING_VERSION = 26.0.0\nCURRENT_PROJECT_VERSION = 1\n"
        )

        self.assertEqual(
            ["MARKETING_VERSION must stay 0.1.0 during development; got 26.0.0"],
            errors,
        )

    def test_rejects_missing_marketing_version(self):
        errors = self.module.validate_development_version("CURRENT_PROJECT_VERSION = 1\n")

        self.assertEqual(["expected exactly one MARKETING_VERSION setting, found 0"], errors)

    def test_rejects_duplicate_marketing_version(self):
        errors = self.module.validate_development_version(
            "MARKETING_VERSION = 0.1.0\nMARKETING_VERSION = 0.1.0\n"
        )

        self.assertEqual(["expected exactly one MARKETING_VERSION setting, found 2"], errors)


if __name__ == "__main__":
    unittest.main()
