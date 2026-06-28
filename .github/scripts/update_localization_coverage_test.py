import unittest

import update_localization_coverage


class UpdateLocalizationCoverageTests(unittest.TestCase):
    def test_renders_one_encoded_badge_per_language(self):
        coverage = [
            update_localization_coverage.Coverage("en", "English", 137, 137, 2, 2),
            update_localization_coverage.Coverage("zh-Hans", "简体中文", 138, 139, 2, 2),
        ]

        badges = update_localization_coverage.render_coverage_badges(coverage)

        self.assertIn(
            "https://img.shields.io/badge/l10n%20English-100%25-2ea44f",
            badges,
        )
        self.assertIn(
            "https://img.shields.io/badge/l10n%20%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-99%25-dfb317",
            badges,
        )
        self.assertIn('href="#localization"', badges)

    def test_update_readme_adds_badge_block_before_localization_table(self):
        readme = (
            "<p align=\"center\">\n"
            "  <img src=\"icon.svg\" alt=\"icon\">\n"
            "</p>\n"
            "\n"
            "## Localization\n"
            "\n"
            "<!-- localization-coverage:start -->\n"
            "old table\n"
            "<!-- localization-coverage:end -->\n"
        )

        updated = update_localization_coverage.update_readme(
            readme,
            table="new table",
            badges="<p align=\"center\">badges</p>",
        )

        self.assertIn("<!-- localization-badges:start -->\n<p align=\"center\">badges</p>\n<!-- localization-badges:end -->", updated)
        self.assertLess(updated.index("localization-badges:start"), updated.index("## Localization"))
        self.assertIn("<!-- localization-coverage:start -->\nnew table\n<!-- localization-coverage:end -->", updated)


if __name__ == "__main__":
    unittest.main()
