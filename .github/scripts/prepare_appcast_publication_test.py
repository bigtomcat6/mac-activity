import unittest

import prepare_appcast_publication


class PrepareAppcastPublicationTests(unittest.TestCase):
    def test_updates_public_version_for_matching_appcast_item(self):
        appcast = (
            '<?xml version="1.0" standalone="yes"?>\n'
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
            "  <channel>\n"
            "    <item>\n"
            "      <title>26.0.0</title>\n"
            "      <sparkle:version>3</sparkle:version>\n"
            "      <sparkle:shortVersionString>26.0.0</sparkle:shortVersionString>\n"
            '      <enclosure url="https://github.com/bigtomcat6/mac-activity/releases/download/v26.0.0-beta.2/MacActivity-v26.0.0-beta.2.zip"/>\n'
            "    </item>\n"
            "    <item>\n"
            "      <title>26.0.0</title>\n"
            "      <sparkle:version>2</sparkle:version>\n"
            "      <sparkle:shortVersionString>26.0.0</sparkle:shortVersionString>\n"
            '      <enclosure url="https://github.com/bigtomcat6/mac-activity/releases/download/v26.0.0-beta.1/MacActivity-v26.0.0-beta.1.zip"/>\n'
            "    </item>\n"
            "  </channel>\n"
            "</rss>\n"
        )

        updated = prepare_appcast_publication.update_appcast_release_version(
            appcast,
            "v26.0.0-beta.2",
        )

        self.assertIn("<title>26.0.0-beta.2</title>", updated)
        self.assertIn(
            "<sparkle:shortVersionString>26.0.0-beta.2</sparkle:shortVersionString>",
            updated,
        )
        self.assertEqual(
            updated.count("<sparkle:shortVersionString>26.0.0</sparkle:shortVersionString>"),
            1,
        )

    def test_sanitizes_internal_release_note_metadata_comments(self):
        notes = (
            "<!-- MacActivityReleaseTag: v26.0.0-beta.2 -->\n"
            "<!-- MacActivityBundleBuild: 3 -->\n"
            "<!-- MacActivityPrerelease: 2 -->\n"
            "## Features\n"
        )

        self.assertEqual(
            prepare_appcast_publication.sanitize_release_notes(notes),
            "## Features\n",
        )


if __name__ == "__main__":
    unittest.main()
