import unittest

import generate_release_notes


class GenerateReleaseNotesTests(unittest.TestCase):
    def test_renders_labeled_sections_in_release_order(self):
        notes = generate_release_notes.render_release_notes(
            [
                generate_release_notes.PullRequest(
                    number=1,
                    title="feat: add DMG packaging",
                    labels=("feature",),
                ),
                generate_release_notes.PullRequest(
                    number=2,
                    title="fix(release): stop duplicate generated notes",
                    labels=("bugfix",),
                ),
                generate_release_notes.PullRequest(
                    number=3,
                    title="speed up metric sampling",
                    labels=("performance",),
                ),
            ]
        )

        self.assertEqual(
            notes,
            "## ✨ Features\n\n"
            "- Add DMG packaging. (#1)\n\n"
            "## 🐛 Bug Fixes\n\n"
            "- Stop duplicate generated notes. (#2)\n\n"
            "## ⚡ Performance\n\n"
            "- Speed up metric sampling. (#3)\n",
        )

    def test_unmatched_prs_go_to_other_changes(self):
        notes = generate_release_notes.render_release_notes(
            [
                generate_release_notes.PullRequest(
                    number=4,
                    title="ci: update release workflow",
                    labels=("ci",),
                ),
            ]
        )

        self.assertEqual(
            notes,
            "## Other Changes\n\n"
            "- Update release workflow. (#4)\n",
        )

    def test_multiple_release_labels_use_priority_order(self):
        section = generate_release_notes.section_for_labels(
            ("feature", "security", "breaking")
        )

        self.assertEqual(section, "## ⚠️ Breaking Changes")

    def test_release_prefixed_labels_are_supported(self):
        section = generate_release_notes.section_for_labels(("release: feature",))

        self.assertEqual(section, "## ✨ Features")

    def test_other_label_maps_to_other_changes(self):
        section = generate_release_notes.section_for_labels(("other",))

        self.assertEqual(section, "## Other Changes")

    def test_skip_release_notes_label_omits_ci_docs_and_test_only_pull_requests(self):
        notes = generate_release_notes.render_release_notes(
            [
                generate_release_notes.PullRequest(
                    number=5,
                    title="ci: update workflow runner",
                    labels=("skip-release-notes",),
                ),
                generate_release_notes.PullRequest(
                    number=6,
                    title="docs: update release checklist",
                    labels=("skip-release-notes",),
                ),
                generate_release_notes.PullRequest(
                    number=7,
                    title="test: cover release metadata parsing",
                    labels=("skip-release-notes",),
                ),
                generate_release_notes.PullRequest(
                    number=8,
                    title="feat: add release packaging",
                    labels=("feature",),
                ),
            ]
        )

        self.assertEqual(
            notes,
            "## ✨ Features\n\n"
            "- Add release packaging. (#8)\n",
        )

    def test_skip_release_notes_takes_priority_over_release_labels(self):
        notes = generate_release_notes.render_release_notes(
            [
                generate_release_notes.PullRequest(
                    number=6,
                    title="feat: internal workflow helper",
                    labels=("feature", "skip-release-notes"),
                ),
            ]
        )

        self.assertEqual(notes, "")

    def test_deduplicates_pull_requests_from_multiple_commits(self):
        pull_requests = generate_release_notes.unique_pull_requests(
            [
                {"number": 7, "title": "fix: repair release notes", "labels": []},
                {"number": 7, "title": "fix: repair release notes", "labels": []},
            ]
        )

        self.assertEqual(len(pull_requests), 1)
        self.assertEqual(pull_requests[0].number, 7)


if __name__ == "__main__":
    unittest.main()
