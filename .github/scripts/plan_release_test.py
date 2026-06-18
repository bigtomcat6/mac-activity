import unittest

import plan_release


class PlanReleaseTests(unittest.TestCase):
    def test_default_release_year_uses_two_digit_current_year(self):
        args = plan_release.parse_args(["--channel", "alpha"])

        self.assertEqual(args.release_year, int(plan_release.dt.date.today().strftime("%y")))

    def test_plans_requested_alpha_version(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version="26.0.0",
            build="1",
            existing_tags=[],
            existing_releases=[],
            release_year=26,
        )

        self.assertEqual(plan["version"], "26.0.0")
        self.assertEqual(plan["build"], "1")
        self.assertEqual(plan["tag"], "v26.0.0-alpha.1")
        self.assertEqual(plan["conflicts"], [])

    def test_detects_existing_tag_conflict(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version="26.0.0",
            build="1",
            existing_tags=["v26.0.0-alpha.1"],
            existing_releases=[],
            release_year=26,
        )

        self.assertIn("tag already exists: v26.0.0-alpha.1", plan["conflicts"])

    def test_detects_existing_draft_release_conflict(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version="26.0.0",
            build="1",
            existing_tags=[],
            existing_releases=[
                {"tagName": "v26.0.0-alpha.1", "isDraft": True},
            ],
            release_year=26,
        )

        self.assertIn(
            "draft release already exists: v26.0.0-alpha.1",
            plan["conflicts"],
        )

    def test_detects_existing_published_release_conflict(self):
        plan = plan_release.plan_release(
            channel="release",
            version="26.0.0",
            build="12",
            existing_tags=[],
            existing_releases=[
                {"tag_name": "v26.0.0", "draft": False},
            ],
            release_year=26,
        )

        self.assertIn("release already exists: v26.0.0", plan["conflicts"])

    def test_suggests_first_alpha_when_version_is_missing(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version=None,
            build=None,
            existing_tags=[],
            existing_releases=[],
            release_year=26,
        )

        self.assertEqual(plan["suggested_version"], "26.0.0")
        self.assertEqual(plan["suggested_build"], "1")
        self.assertEqual(plan["suggested_tag"], "v26.0.0-alpha.1")

    def test_suggests_next_alpha_build_for_existing_series(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version=None,
            build=None,
            existing_tags=[
                "v26.0.0-alpha.1",
                "v26.0.0-alpha.2",
            ],
            existing_releases=[],
            release_year=26,
        )

        self.assertEqual(plan["suggested_version"], "26.0.0")
        self.assertEqual(plan["suggested_build"], "3")
        self.assertEqual(plan["suggested_tag"], "v26.0.0-alpha.3")

    def test_suggests_next_alpha_build_from_existing_releases(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version=None,
            build=None,
            existing_tags=[],
            existing_releases=[
                {"tag_name": "v26.0.0-alpha.1", "draft": True},
            ],
            release_year=26,
        )

        self.assertEqual(plan["suggested_version"], "26.0.0")
        self.assertEqual(plan["suggested_build"], "2")
        self.assertEqual(plan["suggested_tag"], "v26.0.0-alpha.2")

    def test_flattens_paginated_release_payload(self):
        releases = plan_release.normalize_releases_payload(
            [
                [{"tag_name": "v26.0.0-alpha.1"}],
                [{"tag_name": "v26.0.0-alpha.2"}],
            ]
        )

        self.assertEqual(
            releases,
            [
                {"tag_name": "v26.0.0-alpha.1"},
                {"tag_name": "v26.0.0-alpha.2"},
            ],
        )


if __name__ == "__main__":
    unittest.main()
