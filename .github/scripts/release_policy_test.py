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


if __name__ == "__main__":
    unittest.main()
