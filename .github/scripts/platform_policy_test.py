import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
REQUIREMENT_DOCS = ("README.md", "docs/user-guide.md", "docs/development.md")
XCODE_TARGETS = {
    "Mac Activity", "MacActivityCore", "MacActivityCoreTests", "MacActivityAppTests",
    "MacActivityBatteryControl", "MacActivityBatteryControlTests",
}


def read(relative_path):
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


class PlatformPolicyTests(unittest.TestCase):
    def test_swiftpm_packages_target_macos_26(self):
        for manifest in ("Package.swift", "Tools/AudioNativeValidation/Package.swift"):
            with self.subTest(manifest=manifest):
                self.assertEqual(re.findall(r"\.macOS\(\.v(\d+)\)", read(manifest)), ["26"])

    def test_xcodegen_spec_targets_macos_26_arm64_only(self):
        spec = read("project.yml")
        self.assertIn('deploymentTarget:\n    macOS: "26.0"', spec)
        targets = spec.split("\ntargets:\n", 1)[1].split("\nschemes:", 1)[0]
        names = re.findall(r'^  (?:"([^"]+)"|([^ :]+)):$', targets, re.M)
        self.assertEqual({quoted or plain for quoted, plain in names}, XCODE_TARGETS)
        self.assertEqual(re.findall(r'deploymentTarget: "([\d.]+)"', targets), ["26.0"] * len(XCODE_TARGETS))
        self.assertEqual(re.findall(r'MACOSX_DEPLOYMENT_TARGET: "([\d.]+)"', spec), ["26.0"])
        self.assertEqual(re.findall(r"(?m)^\s+ARCHS: (\S+)$", spec), ["arm64"])

    def test_generated_project_matches_spec(self):
        project = read("MacActivity.xcodeproj/project.pbxproj")
        self.assertEqual(set(re.findall(r"MACOSX_DEPLOYMENT_TARGET = ([\d.]+);", project)), {"26.0"})
        self.assertEqual(set(re.findall(r"\bARCHS = ([^;]+);", project)), {"arm64"})
        native_targets = project.split("/* Begin PBXNativeTarget section */", 1)[1].split("/* End PBXNativeTarget section */", 1)[0]
        names = re.findall(r'^\s*name = (?:"([^"]+)"|([^;]+));$', native_targets, re.M)
        self.assertEqual({quoted or plain for quoted, plain in names}, XCODE_TARGETS)

    def test_shared_xcconfig_targets_macos_26(self):
        self.assertRegex(read("Configuration/Shared.xcconfig"), r"(?m)^MACOSX_DEPLOYMENT_TARGET = 26\.0$")

    def test_app_minimum_system_version_follows_deployment_target(self):
        self.assertRegex(
            read("Configuration/MacActivity-Info.plist"),
            r"<key>LSMinimumSystemVersion</key>\s*<string>\$\(MACOSX_DEPLOYMENT_TARGET\)</string>",
        )

    def test_local_release_script_builds_arm64_only(self):
        script = read("scripts/install-local-release.command")
        self.assertIn('-destination "platform=macOS,arch=arm64"', script)
        self.assertNotIn("MAC_ACTIVITY_ARCH", script)
        self.assertNotIn("uname -m", script)

    def test_requirements_docs_name_macos_26_apple_silicon_and_xcode_26(self):
        readme = read("README.md")
        self.assertIn(
            '<img src="https://img.shields.io/badge/macOS-26.0%2B-000000?logo=apple&logoColor=white"'
            ' alt="macOS 26.0+">',
            readme,
        )
        self.assertIn("- macOS 26.0+ on Apple silicon (arm64)\n", readme)
        self.assertIn("- Xcode 26 or newer with the Swift 6.2 toolchain\n", readme)
        self.assertIn("- macOS 26.0 or newer on a Mac with Apple silicon.\n", read("docs/user-guide.md"))
        self.assertIn(
            "- macOS 26.0 or newer on a Mac with Apple silicon.\n"
            "- Xcode 26 or newer with the Swift 6.2 toolchain.\n",
            read("docs/development.md"),
        )
        for doc in REQUIREMENT_DOCS:
            with self.subTest(doc=doc):
                self.assertNotRegex(read(doc), r"macOS 13|macOS-13|Xcode 16")


if __name__ == "__main__":
    unittest.main()
