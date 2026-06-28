import json
import tempfile
import unittest
from pathlib import Path

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

    def test_write_shields_endpoint_badges_outputs_one_json_file_per_language(self):
        coverage = [
            update_localization_coverage.Coverage("en", "English", 137, 137, 2, 2),
            update_localization_coverage.Coverage("zh-Hans", "简体中文", 138, 139, 2, 2),
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            update_localization_coverage.write_shields_endpoint_badges(
                coverage,
                Path(temp_dir),
            )

            english = json.loads((Path(temp_dir) / "en.json").read_text())
            chinese = json.loads((Path(temp_dir) / "zh-Hans.json").read_text())

        self.assertEqual(
            {
                "schemaVersion": 1,
                "label": "l10n English",
                "message": "100%",
                "color": "brightgreen",
            },
            english,
        )
        self.assertEqual(
            {
                "schemaVersion": 1,
                "label": "l10n 简体中文",
                "message": "99%",
                "color": "yellow",
            },
            chinese,
        )


if __name__ == "__main__":
    unittest.main()
