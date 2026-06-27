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
            prerelease="1",
            build="1",
            existing_tags=[],
            existing_releases=[],
            release_year=26,
        )

        self.assertEqual(plan["version"], "26.0.0")
        self.assertEqual(plan["prerelease"], "1")
        self.assertEqual(plan["build"], "1")
        self.assertEqual(plan["tag"], "v26.0.0-alpha.1")
        self.assertEqual(plan["conflicts"], [])

    def test_detects_existing_tag_conflict(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version="26.0.0",
            prerelease="1",
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
            prerelease="1",
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
            prerelease=None,
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
            prerelease=None,
            build=None,
            existing_tags=[],
            existing_releases=[],
            release_year=26,
        )

        self.assertEqual(plan["suggested_version"], "26.0.0")
        self.assertEqual(plan["suggested_prerelease"], "1")
        self.assertEqual(plan["suggested_build"], "1")
        self.assertEqual(plan["suggested_tag"], "v26.0.0-alpha.1")

    def test_suggests_next_alpha_prerelease_and_build_for_existing_series(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version=None,
            prerelease=None,
            build=None,
            existing_tags=[
                "v26.0.0-alpha.1",
                "v26.0.0-alpha.2",
            ],
            existing_releases=[],
            release_year=26,
        )

        self.assertEqual(plan["suggested_version"], "26.0.0")
        self.assertEqual(plan["suggested_prerelease"], "3")
        self.assertEqual(plan["suggested_build"], "3")
        self.assertEqual(plan["suggested_tag"], "v26.0.0-alpha.3")

    def test_suggests_next_beta_prerelease_after_existing_alpha_and_beta_builds(self):
        plan = plan_release.plan_release(
            channel="beta",
            version=None,
            prerelease=None,
            build=None,
            existing_tags=[
                "v26.0.0-alpha.1",
                "v26.0.0-alpha.2",
                "v26.0.0-beta.1",
            ],
            existing_releases=[],
            release_year=26,
        )

        self.assertEqual(plan["suggested_version"], "26.0.0")
        self.assertEqual(plan["suggested_prerelease"], "2")
        self.assertEqual(plan["suggested_build"], "3")
        self.assertEqual(plan["suggested_tag"], "v26.0.0-beta.2")

    def test_suggests_next_build_from_release_body_metadata(self):
        plan = plan_release.plan_release(
            channel="beta",
            version=None,
            prerelease=None,
            build=None,
            existing_tags=[
                "v26.0.0-alpha.1",
                "v26.0.0-alpha.2",
                "v26.0.0-beta.1",
                "v26.0.0-beta.2",
            ],
            existing_releases=[
                {
                    "tag_name": "v26.0.0-beta.2",
                    "body": "<!-- MacActivityBundleBuild: 3 -->",
                },
            ],
            release_year=26,
        )

        self.assertEqual(plan["suggested_version"], "26.0.0")
        self.assertEqual(plan["suggested_prerelease"], "3")
        self.assertEqual(plan["suggested_build"], "4")
        self.assertEqual(plan["suggested_tag"], "v26.0.0-beta.3")

    def test_suggests_release_build_after_existing_prerelease_bundle_builds(self):
        plan = plan_release.plan_release(
            channel="release",
            version=None,
            prerelease=None,
            build=None,
            existing_tags=[
                "v26.0.0-alpha.1",
                "v26.0.0-alpha.2",
                "v26.0.0-beta.2",
            ],
            existing_releases=[
                {
                    "tag_name": "v26.0.0-beta.2",
                    "body": "<!-- MacActivityBundleBuild: 3 -->",
                },
            ],
            release_year=26,
        )

        self.assertEqual(plan["suggested_version"], "26.0.0")
        self.assertIsNone(plan["suggested_prerelease"])
        self.assertEqual(plan["suggested_build"], "4")
        self.assertEqual(plan["suggested_tag"], "v26.0.0")

    def test_detects_build_that_would_not_advance_sparkle_version(self):
        plan = plan_release.plan_release(
            channel="beta",
            version="26.0.0",
            prerelease="2",
            build="1",
            existing_tags=[
                "v26.0.0-alpha.1",
                "v26.0.0-alpha.2",
            ],
            existing_releases=[],
            release_year=26,
        )

        self.assertIn(
            "build 1 must be greater than existing build 2 for 26.0.0",
            plan["conflicts"],
        )

    def test_accepts_same_train_beta_two_when_bundle_build_advances(self):
        plan = plan_release.plan_release(
            channel="beta",
            version="26.0.0",
            prerelease="2",
            build="3",
            existing_tags=[
                "v26.0.0-alpha.1",
                "v26.0.0-alpha.2",
                "v26.0.0-beta.1",
            ],
            existing_releases=[],
            release_year=26,
        )

        self.assertEqual(plan["tag"], "v26.0.0-beta.2")
        self.assertEqual(plan["build"], "3")
        self.assertEqual(plan["conflicts"], [])

    def test_rejects_missing_prerelease_for_prerelease_channel(self):
        with self.assertRaisesRegex(ValueError, "prerelease must be a positive integer"):
            plan_release.plan_release(
                channel="beta",
                version="26.0.0",
                prerelease=None,
                build="3",
                existing_tags=[],
                existing_releases=[],
                release_year=26,
            )

    def test_suggests_next_alpha_build_from_existing_releases(self):
        plan = plan_release.plan_release(
            channel="alpha",
            version=None,
            prerelease=None,
            build=None,
            existing_tags=[],
            existing_releases=[
                {"tag_name": "v26.0.0-alpha.1", "draft": True},
            ],
            release_year=26,
        )

        self.assertEqual(plan["suggested_version"], "26.0.0")
        self.assertEqual(plan["suggested_prerelease"], "2")
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
