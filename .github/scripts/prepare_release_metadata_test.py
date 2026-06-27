import unittest

import prepare_release_metadata


class PrepareReleaseMetadataTests(unittest.TestCase):
    def test_builds_release_metadata_for_final_release(self):
        metadata = prepare_release_metadata.build_metadata(
            channel="release",
            version="1.2.3",
            prerelease=None,
            build="45",
        )

        self.assertEqual(metadata["tag"], "v1.2.3")
        self.assertEqual(metadata["title"], "1.2.3")
        self.assertEqual(metadata["prerelease"], "false")
        self.assertEqual(metadata["latest"], "true")
        self.assertEqual(metadata["artifact_stem"], "MacActivity-v1.2.3")

    def test_builds_release_metadata_for_beta(self):
        metadata = prepare_release_metadata.build_metadata(
            channel="beta",
            version="1.2.3",
            prerelease="4",
            build="45",
        )

        self.assertEqual(metadata["tag"], "v1.2.3-beta.4")
        self.assertEqual(metadata["title"], "1.2.3-beta.4")
        self.assertEqual(metadata["prerelease_number"], "4")
        self.assertEqual(metadata["build"], "45")
        self.assertEqual(metadata["prerelease"], "true")
        self.assertEqual(metadata["latest"], "false")
        self.assertEqual(metadata["artifact_stem"], "MacActivity-v1.2.3-beta.4")

    def test_updates_shared_xcconfig_versions(self):
        updated = prepare_release_metadata.update_xcconfig(
            (
                "MARKETING_VERSION = 0.1.0\n"
                "CURRENT_PROJECT_VERSION = 1\n"
                "MAC_ACTIVITY_RELEASE_TAG = v0.1.0\n"
            ),
            version="1.2.3",
            build="45",
            release_tag="v1.2.3-beta.45",
        )

        self.assertEqual(
            updated,
            (
                "MARKETING_VERSION = 1.2.3\n"
                "CURRENT_PROJECT_VERSION = 45\n"
                "MAC_ACTIVITY_RELEASE_TAG = v1.2.3-beta.45\n"
            ),
        )

    def test_rejects_invalid_version(self):
        with self.assertRaises(ValueError):
            prepare_release_metadata.build_metadata(
                channel="rc",
                version="1.2",
                prerelease="1",
                build="45",
            )

    def test_rejects_missing_prerelease_for_prerelease_channel(self):
        with self.assertRaises(ValueError):
            prepare_release_metadata.build_metadata(
                channel="beta",
                version="1.2.3",
                prerelease=None,
                build="45",
            )

    def test_rejects_prerelease_for_final_release(self):
        with self.assertRaises(ValueError):
            prepare_release_metadata.build_metadata(
                channel="release",
                version="1.2.3",
                prerelease="1",
                build="45",
            )


if __name__ == "__main__":
    unittest.main()
