import unittest

import update_localization_coverage


class UpdateLocalizationCoverageTests(unittest.TestCase):
    def test_incomplete_coverage_detects_missing_baseline_keys(self):
        coverage = [
            update_localization_coverage.Coverage("en", "English", 137, 137, 2, 2),
            update_localization_coverage.Coverage("zh-Hans", "简体中文", 138, 139, 2, 2),
        ]

        incomplete = update_localization_coverage.incomplete_coverage(coverage)

        self.assertEqual(["zh-Hans"], [row.language_identifier for row in incomplete])

    def test_render_coverage_table_reports_language_counts(self):
        coverage = [
            update_localization_coverage.Coverage("en", "English", 137, 137, 2, 2),
            update_localization_coverage.Coverage("zh-Hans", "简体中文", 138, 139, 2, 2),
        ]

        table = update_localization_coverage.render_coverage_table(coverage)

        self.assertIn("| English | 100% (137/137) | 100% (2/2) | 100% (139/139) |", table)
        self.assertIn("| 简体中文 | 99% (138/139) | 100% (2/2) | 99% (140/141) |", table)


if __name__ == "__main__":
    unittest.main()
