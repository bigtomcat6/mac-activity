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

    def test_final_release_notes_use_previous_stable_tag(self):
        commands = []

        def run_command(command):
            commands.append(command)
            if command[:3] == ["git", "tag", "--merged"]:
                return "v25.1.0\nv26.0.0-beta.5\nv25.2.0\nv25.2.0-rc.1"
            raise AssertionError(f"unexpected command: {command}")

        previous_tag = generate_release_notes.find_previous_tag(
            "release-sha",
            current_tag="v26.0.0",
            run=run_command,
        )

        self.assertEqual(previous_tag, "v25.2.0")
        self.assertEqual(
            commands,
            [["git", "tag", "--merged", "release-sha"]],
        )

    def test_first_final_release_notes_include_entire_train(self):
        def run_command(command):
            if command[:3] == ["git", "tag", "--merged"]:
                return "v26.0.0-beta.5\nv26.0.0-alpha.1"
            raise AssertionError(f"unexpected command: {command}")

        previous_tag = generate_release_notes.find_previous_tag(
            "release-sha",
            current_tag="v26.0.0",
            run=run_command,
        )

        self.assertIsNone(previous_tag)

    def test_prerelease_notes_still_use_latest_reachable_tag(self):
        def run_command(command):
            if command == ["git", "describe", "--tags", "--abbrev=0", "release-sha"]:
                return "v26.0.0-beta.4"
            raise AssertionError(f"unexpected command: {command}")

        previous_tag = generate_release_notes.find_previous_tag(
            "release-sha",
            current_tag="v26.0.0-beta.5",
            run=run_command,
        )

        self.assertEqual(previous_tag, "v26.0.0-beta.4")

    def test_escapes_markdown_special_characters_in_pr_titles(self):
        notes = generate_release_notes.render_release_notes(
            [
                generate_release_notes.PullRequest(
                    number=9,
                    title="fix: close <img src=x onerror=alert(1)> and [run](javascript:alert(1))",
                    labels=("security",),
                ),
            ]
        )

        self.assertNotIn("<img", notes)
        self.assertNotIn("[run](javascript:", notes)
        self.assertIn(r"&lt;img src=x onerror=alert\(1\)&gt;", notes)
        self.assertIn(r"\[run\]\(javascript:alert\(1\)\)", notes)

    def test_escapes_leading_markdown_block_markers_in_pr_titles(self):
        notes = generate_release_notes.render_release_notes(
            [
                generate_release_notes.PullRequest(
                    number=10,
                    title="> quoted release note",
                    labels=("bugfix",),
                ),
            ]
        )

        self.assertIn("- &gt; quoted release note. (#10)", notes)


if __name__ == "__main__":
    unittest.main()
