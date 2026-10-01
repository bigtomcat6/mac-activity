"""Run only with an explicitly supplied DebugDiskCleanup executable.

Every destructive invocation is confined to newly created temporary fixtures.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get("MACACTIVITY_DEBUG_DISK_CLEANUP"), "set MACACTIVITY_DEBUG_DISK_CLEANUP to run CLI integration tests")
class DiskCleanupSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macactivity-security-", dir="/private/tmp")
        self.addCleanup(self.temp.cleanup)
        self.container = Path(self.temp.name)
        self.fixture = self.container / "macactivity-fixture"
        self.outside = self.container / "outside"
        self.outside.mkdir()
        for category in [".Trash", "Library/Caches", "Library/Logs"]:
            (self.fixture / category).mkdir(parents=True, exist_ok=True)
        self.sentinel = self.outside / "old.log"
        self.sentinel.write_bytes(b"sentinel" * 1024)
        os.utime(self.sentinel, (1, 1))

    def run_cleanup(self, *arguments, fixture=None):
        result = subprocess.run(
            [os.environ["MACACTIVITY_DEBUG_DISK_CLEANUP"], "--fixture-root", str(fixture or self.fixture), "--json", *arguments],
            capture_output=True, text=True, timeout=30, check=False,
        )
        return result, json.loads(result.stdout) if result.returncode == 0 else None

    def test_all_category_root_symlinks_preserve_outside_files(self):
        for category, name in [(".Trash", "trash"), ("Library/Caches", "userCaches"), ("Library/Logs", "userLogs")]:
            with self.subTest(category=category):
                root = self.fixture / category
                root.rmdir()
                root.symlink_to(self.outside, target_is_directory=True)
                result, report = self.run_cleanup("--clean", "--confirm", "--categories", name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(report["cleanResult"]["classification"].startswith("failed"))
                self.assertTrue(self.sentinel.exists())
                root.unlink()
                root.mkdir()

    def test_library_symlink_and_fixture_symlink_are_rejected(self):
        (self.fixture / "Library/Caches").rmdir()
        (self.fixture / "Library/Logs").rmdir()
        (self.fixture / "Library").rmdir()
        (self.outside / "Caches").mkdir()
        target = self.outside / "Caches/old.log"
        target.write_bytes(b"outside" * 1024)
        os.utime(target, (1, 1))
        (self.fixture / "Library").symlink_to(self.outside, target_is_directory=True)
        _, report = self.run_cleanup("--clean", "--confirm", "--categories", "userCaches")
        self.assertTrue(report["cleanResult"]["classification"].startswith("failed"))
        self.assertTrue(target.exists())
        alias = self.container / "macactivity-alias"
        alias.symlink_to(self.fixture, target_is_directory=True)
        _, report = self.run_cleanup("--clean", "--confirm", "--categories", "trash", fixture=alias)
        self.assertTrue(report["cleanResult"]["classification"].startswith("failed"))

    def test_confirmation_dry_run_and_tmp_alias_preserve_normal_behavior(self):
        candidate = self.fixture / "Library/Caches/old.cache"
        candidate.write_bytes(b"old" * 4096)
        os.utime(candidate, (1, 1))
        result, _ = self.run_cleanup("--clean", "--categories", "userCaches")
        self.assertEqual(result.returncode, 2)
        for mode in [("--scan",), ("--clean", "--dry-run")]:
            _, report = self.run_cleanup(*mode, "--categories", "userCaches")
            self.assertIsNone(report.get("cleanResult"))
            self.assertTrue(candidate.exists())
        alias = Path(str(self.fixture).replace("/private/tmp/", "/tmp/", 1))
        result, report = self.run_cleanup("--clean", "--confirm", "--categories", "userCaches", fixture=alias)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["cleanResult"]["classification"], "cleaned")
        self.assertEqual(report["cleanResult"]["itemCount"], 1)
        self.assertFalse(candidate.exists())
        self.assertTrue(self.sentinel.exists())


if __name__ == "__main__":
    unittest.main()
