import re
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
        self.assertNotIn("required-ci:", workflow)

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
        self.assertNotIn("\n    name:", tests_section)

        coverage_section = workflow.split("\n  coverage:", 1)[1].split("\n  lint:", 1)[0]
        self.assertIn("needs: [tests, swiftpm-tests]", coverage_section)

        lint_section = workflow.split("\n  lint:", 1)[1].split("\n  ci-summary:", 1)[0]
        self.assertIn("needs: [tests]", lint_section)

        summary_section = workflow.split("\n  ci-summary:", 1)[1]
        self.assertIn("needs: [swiftpm-tests, xcode-tests, tests, coverage, lint]", summary_section)
        self.assertIn("GITHUB_STEP_SUMMARY", summary_section)
        self.assertIn("# CI Dashboard", summary_section)
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
