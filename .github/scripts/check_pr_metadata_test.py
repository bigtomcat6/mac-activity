import tempfile
import unittest
from pathlib import Path

import check_pr_metadata


VALID_BODY = """## Summary

Add a focused PR workflow.

## How to test

Run the PR metadata check locally.

## Release impact

- Type: Internal
- Release note: None

## Checklist

- [x] I have seen this code, I have run this code, and I take responsibility for this code.
"""


class PullRequestMetadataTests(unittest.TestCase):
    def test_accepts_valid_title_and_body(self):
        errors = check_pr_metadata.validate_pr(
            "ci(release): Add PR quality checks",
            VALID_BODY,
        )

        self.assertEqual(errors, [])

    def test_rejects_title_that_does_not_follow_convention(self):
        errors = check_pr_metadata.validate_pr(
            "Add PR quality checks.",
            VALID_BODY,
        )

        self.assertIn("title must match '<type>(<scope>): <Summary>'", errors[0])

    def test_rejects_body_missing_required_sections(self):
        errors = check_pr_metadata.validate_pr(
            "ci(release): Add PR quality checks",
            "## Summary\n\nOnly summary.",
        )

        self.assertIn("body is missing required section: ## How to test", errors)
        self.assertIn("body is missing required section: ## Release impact", errors)
        self.assertIn("body is missing required section: ## Checklist", errors)

    def test_reads_pull_request_metadata_from_github_event(self):
        event = """{
          "pull_request": {
            "title": "docs: Update PR workflow",
            "body": "## Summary\\n\\nDocument it.\\n\\n## How to test\\n\\nRead it.\\n\\n## Release impact\\n\\n- Type: Internal\\n- Release note: None\\n\\n## Checklist\\n\\n- [x] I have seen this code, I have run this code, and I take responsibility for this code.\\n"
          }
        }"""
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            event_path.write_text(event)

            title, body = check_pr_metadata.read_event(event_path)

        self.assertEqual(title, "docs: Update PR workflow")
        self.assertIn("## Release impact", body)


if __name__ == "__main__":
    unittest.main()
