import unittest

import plan_release


class PlanReleaseTests(unittest.TestCase):
    def test_plans_requested_alpha_version(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version="2026.0.0",
            build="1",
            existing_tags=[],
            existing_releases=[],
            release_year=2026,
        )

        self.assertEqual(plan["version"], "2026.0.0")
        self.assertEqual(plan["build"], "1")
        self.assertEqual(plan["tag"], "v2026.0.0-alpha.1")
        self.assertEqual(plan["conflicts"], [])

    def test_detects_existing_tag_conflict(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version="2026.0.0",
            build="1",
            existing_tags=["v2026.0.0-alpha.1"],
            existing_releases=[],
            release_year=2026,
        )

        self.assertIn("tag already exists: v2026.0.0-alpha.1", plan["conflicts"])

    def test_detects_existing_draft_release_conflict(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version="2026.0.0",
            build="1",
            existing_tags=[],
            existing_releases=[
                {"tagName": "v2026.0.0-alpha.1", "isDraft": True},
            ],
            release_year=2026,
        )

        self.assertIn(
            "draft release already exists: v2026.0.0-alpha.1",
            plan["conflicts"],
        )

    def test_detects_existing_published_release_conflict(self):
        plan = plan_release.plan_release(
            channel="release",
            version="2026.0.0",
            build="12",
            existing_tags=[],
            existing_releases=[
                {"tag_name": "v2026.0.0", "draft": False},
            ],
            release_year=2026,
        )

        self.assertIn("release already exists: v2026.0.0", plan["conflicts"])

    def test_suggests_first_alpha_when_version_is_missing(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version=None,
            build=None,
            existing_tags=[],
            existing_releases=[],
            release_year=2026,
        )

        self.assertEqual(plan["suggested_version"], "2026.0.0")
        self.assertEqual(plan["suggested_build"], "1")
        self.assertEqual(plan["suggested_tag"], "v2026.0.0-alpha.1")

    def test_suggests_next_alpha_build_for_existing_series(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version=None,
            build=None,
            existing_tags=[
                "v2026.0.0-alpha.1",
                "v2026.0.0-alpha.2",
            ],
            existing_releases=[],
            release_year=2026,
        )

        self.assertEqual(plan["suggested_version"], "2026.0.0")
        self.assertEqual(plan["suggested_build"], "3")
        self.assertEqual(plan["suggested_tag"], "v2026.0.0-alpha.3")

    def test_suggests_next_alpha_build_from_existing_releases(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version=None,
            build=None,
            existing_tags=[],
            existing_releases=[
                {"tag_name": "v2026.0.0-alpha.1", "draft": True},
            ],
            release_year=2026,
        )

        self.assertEqual(plan["suggested_version"], "2026.0.0")
        self.assertEqual(plan["suggested_build"], "2")
        self.assertEqual(plan["suggested_tag"], "v2026.0.0-alpha.2")

    def test_flattens_paginated_release_payload(self):
        releases = plan_release.normalize_releases_payload(
            [
                [{"tag_name": "v2026.0.0-alpha.1"}],
                [{"tag_name": "v2026.0.0-alpha.2"}],
            ]
        )

        self.assertEqual(
            releases,
            [
                {"tag_name": "v2026.0.0-alpha.1"},
                {"tag_name": "v2026.0.0-alpha.2"},
            ],
        )


if __name__ == "__main__":
    unittest.main()
