import re
import struct
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class ReleasePolicyTests(unittest.TestCase):
    def test_release_workflow_does_not_expose_draft_input(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()

        workflow_dispatch = workflow.split("permissions:", 1)[0]

        self.assertNotIn("\n      draft:", workflow_dispatch)

    def test_release_workflow_always_creates_draft_releases(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()
        release_step = workflow.split("- name: Create GitHub Release", 1)[1]

        self.assertIn("--draft", release_step)
        self.assertNotIn("DRAFT:", release_step)
        self.assertNotRegex(release_step, re.compile(r"if \[\[ \"\$\{DRAFT\}\""))

    def test_release_workflow_runs_conflict_preflight_before_metadata(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()

        self.assertLess(
            workflow.index("plan_release.py"),
            workflow.index("prepare_release_metadata.py"),
        )

    def test_release_workflow_requires_main_before_ci_and_packaging(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()

        self.assertIn("preflight:", workflow)
        self.assertIn('GITHUB_REF_NAME}" != "main"', workflow)
        self.assertIn("needs: [preflight]", workflow)
        self.assertIn("needs: [preflight, ci]", workflow)

    def test_release_workflow_requires_developer_id_for_github_release_assets(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()
        preflight_section = workflow.split("\n  preflight:", 1)[1].split("\n  ci:", 1)[0]

        self.assertIn("Require Developer ID for GitHub Release assets", preflight_section)
        self.assertIn("inputs.create_github_release", preflight_section)
        self.assertIn("inputs.signing != 'developer-id'", preflight_section)
        self.assertIn("GitHub Release assets must use signing=developer-id.", preflight_section)

    def test_release_ci_job_inherits_secrets_for_reusable_checks(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()
        ci_section = workflow.split("\n  ci:", 1)[1].split("\n  package:", 1)[0]

        self.assertIn("uses: ./.github/workflows/ci-checks.yml", ci_section)
        self.assertIn("secrets: inherit", ci_section)

    def test_release_package_checks_project_drift_even_when_ci_is_skipped(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()
        package_section = workflow.split("\n  package:", 1)[1]

        self.assertIn("Verify generated Xcode project is current", package_section)
        self.assertIn("xcodegen generate --quiet", package_section)
        self.assertIn("git diff --exit-code -- MacActivity.xcodeproj", package_section)

    def test_release_workflow_uses_release_signing_environment(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()
        package_section = workflow.split("\n  package:", 1)[1]

        self.assertIn("environment:", package_section)
        self.assertIn("name: release-signing", package_section)
        self.assertIn("deployment: false", package_section)

    def test_release_workflow_packages_symbols_and_release_notes(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()

        self.assertIn(".dmg", workflow)
        self.assertIn("-dSYM.zip", workflow)
        self.assertIn("-SHA256SUMS.txt", workflow)
        self.assertIn("Generate release notes", workflow)
        self.assertIn("generate_release_notes.py", workflow)
        self.assertIn('DSYM_PATH: ${{ steps.package.outputs.dsym_path }}', workflow)
        self.assertIn('CHECKSUMS_PATH: ${{ steps.package.outputs.checksums_path }}', workflow)
        self.assertIn('--notes "$(cat "${NOTES_PATH}")"', workflow)
        self.assertNotIn("--generate-notes", workflow)

    def test_release_workflow_uses_styled_dmg_script_and_repository_background(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()
        package_section = workflow.split("- name: Package release artifacts", 1)[1]

        self.assertIn(".github/scripts/create_dmg.sh", package_section)
        self.assertIn('--volume-name "${{ steps.release.outputs.app_name }} ${{ steps.release.outputs.title }}"', package_section)
        self.assertIn("assets/dmg/background.png", package_section)
        self.assertNotIn("-srcfolder \"${app}\"", package_section)

    def test_styled_dmg_uses_compact_cropped_background_layout(self):
        script = (REPO_ROOT / ".github" / "scripts" / "create_dmg.sh").read_text()
        background = REPO_ROOT / "assets" / "dmg" / "background.png"

        with background.open("rb") as image:
            self.assertEqual(image.read(8), b"\x89PNG\r\n\x1a\n")
            image.read(8)
            width, height = struct.unpack(">II", image.read(8))

        self.assertEqual((width, height), (627, 560))
        self.assertIn("WINDOW_WIDTH=627", script)
        self.assertIn("WINDOW_HEIGHT=560", script)
        self.assertIn("APP_Y=290", script)
        self.assertIn("APPLICATIONS_Y=290", script)

    def test_release_workflow_supports_developer_id_notarization(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()

        self.assertIn("- developer-id", workflow)
        self.assertIn("Import Developer ID certificate", workflow)
        self.assertIn("DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64", workflow)
        self.assertIn("Notarize Developer ID app", workflow)
        self.assertIn("xcrun notarytool submit", workflow)
        self.assertIn("xcrun stapler staple", workflow)
        self.assertIn("spctl --assess --type execute", workflow)
        self.assertIn("Final releases must use signing=developer-id", workflow)

    def test_create_release_skill_uses_developer_id_for_draft_release(self):
        skill = (REPO_ROOT / ".agents" / "skills" / "create-release" / "SKILL.md").read_text()
        phase_2 = skill.split("## Phase 2: Draft GitHub Release", 1)[1].split("## Distribution Notes", 1)[0]

        self.assertIn("-f signing=developer-id", phase_2)
        self.assertNotIn("-f signing=local", phase_2)
        self.assertIn("GitHub Release assets must use `signing=developer-id`", skill)

    def test_release_workflows_doc_uses_developer_id_for_draft_release(self):
        doc = (REPO_ROOT / ".github" / "release-workflows.md").read_text()
        draft_release_section = doc.split("After that dry run passes", 1)[1]

        self.assertIn("-f signing=developer-id", draft_release_section)
        self.assertNotIn("-f signing=local", draft_release_section)
        self.assertIn("GitHub Release assets must use `signing=developer-id`", doc)

    def test_release_workflow_never_pushes_version_commits(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text()

        self.assertNotIn("commit_version_change", workflow)
        self.assertNotIn("Commit version change", workflow)
        self.assertNotIn("git push origin", workflow)

    def test_pull_request_ci_checks_development_version(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "ci-checks.yml").read_text()

        self.assertIn("Check development version", workflow)
        self.assertIn(".github/scripts/check_development_version.py", workflow)
        self.assertLess(
            workflow.index("Check development version"),
            workflow.index("Run SwiftPM tests with coverage"),
        )

    def test_ci_workflow_uses_reusable_ci_checks(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "ci.yml").read_text()

        self.assertIn("name: Run CI Checks", workflow)
        self.assertIn("uses: ./.github/workflows/ci-checks.yml", workflow)
        self.assertIn("suite: full", workflow)
        self.assertIn("secrets: inherit", workflow)
        self.assertNotIn("required-ci:", workflow)

    def test_reusable_ci_uploads_swiftpm_coverage_to_codecov(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "ci-checks.yml").read_text()

        self.assertIn("CODECOV_TOKEN:", workflow)
        self.assertIn("Upload SwiftPM coverage to Codecov", workflow)
        self.assertIn("uses: codecov/codecov-action@v7", workflow)
        self.assertIn("coverage/swiftpm-codecov.json", workflow)
        self.assertIn("xcrun llvm-cov export", workflow)
        self.assertIn("coverage/swiftpm.lcov", workflow)
        self.assertIn("files: coverage/swiftpm.lcov", workflow)
        self.assertIn("flags: swiftpm", workflow)
        self.assertIn("override_branch: ${{ github.head_ref || github.ref_name }}", workflow)
        self.assertIn("override_pr: ${{ github.event.number }}", workflow)
        self.assertIn("disable_search: true", workflow)
        self.assertIn("fail_ci_if_error: true", workflow)
        self.assertIn("token: ${{ secrets.CODECOV_TOKEN }}", workflow)
        self.assertLess(
            workflow.index("Upload SwiftPM coverage"),
            workflow.index("Upload SwiftPM coverage to Codecov"),
        )

    def test_ci_checks_runs_tests_in_parallel_then_reports_advisory_jobs(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "ci-checks.yml").read_text()

        self.assertIn("swiftpm-tests:", workflow)
        self.assertIn("xcode-tests:", workflow)
        self.assertIn("tests:", workflow)
        self.assertIn("coverage:", workflow)
        self.assertIn("lint:", workflow)
        self.assertIn("ci-summary:", workflow)

        tests_section = workflow.split("\n  tests:", 1)[1].split("\n  coverage:", 1)[0]
        self.assertIn("needs: [swiftpm-tests, xcode-tests]", tests_section)
        self.assertIn("name: Tests", tests_section)

        coverage_section = workflow.split("\n  coverage:", 1)[1].split("\n  lint:", 1)[0]
        self.assertIn("needs: [tests, swiftpm-tests]", coverage_section)

        lint_section = workflow.split("\n  lint:", 1)[1].split("\n  ci-summary:", 1)[0]
        self.assertIn("needs: [tests]", lint_section)

        summary_section = workflow.split("\n  ci-summary:", 1)[1]
        self.assertIn("needs: [swiftpm-tests, xcode-tests, tests, coverage, lint]", summary_section)
        self.assertIn("GITHUB_STEP_SUMMARY", summary_section)
        self.assertIn("# Summary", summary_section)
        self.assertIn("🧪", summary_section)
        self.assertIn("📈", summary_section)
        self.assertIn("🧹", summary_section)
        self.assertIn("Tests:", summary_section)
        self.assertIn("Coverage:", summary_section)
        self.assertIn("Lint:", summary_section)
        self.assertNotIn("| Check | Result | Details |", summary_section)

    def test_ci_checks_removes_unused_runner_homebrew_taps_before_installing_tools(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "ci-checks.yml").read_text()

        xcode_section = workflow.split("\n  xcode-tests:", 1)[1].split("\n  tests:", 1)[0]
        self.assertIn("Remove unused runner Homebrew taps", xcode_section)
        self.assertIn("aws/tap", xcode_section)
        self.assertIn("azure/bicep", xcode_section)
        self.assertLess(
            xcode_section.index("Remove unused runner Homebrew taps"),
            xcode_section.index("brew install xcodegen"),
        )

        lint_section = workflow.split("\n  lint:", 1)[1].split("\n  ci-summary:", 1)[0]
        self.assertIn("Remove unused runner Homebrew taps", lint_section)
        self.assertIn("aws/tap", lint_section)
        self.assertIn("azure/bicep", lint_section)
        self.assertLess(
            lint_section.index("Remove unused runner Homebrew taps"),
            lint_section.index("brew install swiftlint"),
        )

    def test_create_release_skill_requires_two_phase_release(self):
        skill = (
            REPO_ROOT / ".agents" / "skills" / "create-release" / "SKILL.md"
        ).read_text()

        self.assertIn("Phase 0: Version plan", skill)
        self.assertIn("plan_release.py", skill)
        self.assertIn("Phase 1: Clean dry run", skill)
        self.assertIn("Do not create a GitHub Release", skill)
        self.assertIn("Stop and ask", skill)
        self.assertIn("Phase 2: Draft GitHub Release", skill)
        self.assertNotIn("commit_version_change", skill)

    def test_create_release_skill_keeps_source_version_as_development_placeholder(self):
        skill = (
            REPO_ROOT / ".agents" / "skills" / "create-release" / "SKILL.md"
        ).read_text()

        self.assertIn("checked-in `MARKETING_VERSION` stays `0.1.0`", skill)
        self.assertIn("Release versions are injected only in the runner workspace", skill)
        self.assertNotIn("source version committed", skill)
        self.assertNotIn("make a normal PR for\n`Configuration/Shared.xcconfig`", skill)


if __name__ == "__main__":
    unittest.main()
