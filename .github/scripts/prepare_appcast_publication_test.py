import unittest
import xml.etree.ElementTree as ET

import prepare_appcast_publication


class PrepareAppcastPublicationTests(unittest.TestCase):
    @staticmethod
    def item(tag, extra=""):
        return (
            f'<item><title>Original {tag}</title>{extra}'
            '<sparkle:version>42</sparkle:version>'
            '<sparkle:shortVersionString>26.0.0</sparkle:shortVersionString>'
            f'<enclosure url="https://example.invalid/releases/download/{tag}/app.zip" '
            'sparkle:edSignature="unchanged-signature" length="123"/></item>'
        )

    @staticmethod
    def feed(*items):
        return (
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            '<channel><title>Feed</title>' + "".join(items) + '</channel></rss>'
        )

    def test_updates_only_second_or_third_target_and_preserves_other_items(self):
        tags = ["v26.0.0-beta.3", "v26.0.0-beta.2", "v26.0.0-beta.1"]
        for target in tags[1:]:
            with self.subTest(target=target):
                originals = [self.item(tag) for tag in tags]
                updated = prepare_appcast_publication.update_appcast_release_version(
                    self.feed(*originals), target
                )
                items = ET.fromstring(updated).findall("./channel/item")
                for tag, original, item in zip(tags, originals, items):
                    if tag != target:
                        self.assertIn(original, updated)
                    self.assertEqual(
                        item.findtext("title"),
                        target.removeprefix("v") if tag == target else f"Original {tag}",
                    )
                    self.assertEqual(item.findtext("{http://www.andymatuschak.org/xml-namespaces/sparkle}version"), "42")
                    self.assertEqual(item.find("enclosure").get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"), "unchanged-signature")

    def test_ignores_urls_and_item_text_inside_descriptions(self):
        target = "v26.0.0-beta.1"
        first = self.item("v26.0.0-beta.2", f'<description><![CDATA[Notes: <item>/releases/download/{target}/</item>]]></description>')
        updated = prepare_appcast_publication.update_appcast_release_version(
            self.feed(first, self.item(target)), target
        )
        self.assertIn(first, updated)
        self.assertEqual(ET.fromstring(updated).findall("./channel/item")[1].findtext("title"), "26.0.0-beta.1")

    def test_utf8_offsets_and_nonstandard_namespace_prefix(self):
        target = "v26.0.0-beta.1"
        appcast = self.feed(self.item(target)).replace("Feed", "Caf\u00e9").replace("sparkle:", "updater:")
        appcast = appcast.replace("xmlns:sparkle=", "xmlns:updater=")
        updated = prepare_appcast_publication.update_appcast_release_version(appcast, target)
        self.assertIn("Caf\u00e9", updated)
        self.assertEqual(ET.fromstring(updated).find("./channel/item/title").text, "26.0.0-beta.1")

    def test_missing_ambiguous_or_malformed_target_is_rejected(self):
        target = "v26.0.0-beta.1"
        invalid = [
            self.feed(self.item("v26.0.0-beta.10")),
            self.feed(self.item(target), self.item(target)),
            self.feed(self.item(target).replace("<title>", "<description>").replace("</title>", "</description>")),
            self.feed(self.item(target, "<title>duplicate</title>")),
            "<rss><channel>",
        ]
        for appcast in invalid:
            with self.subTest(appcast=appcast):
                with self.assertRaises(ValueError):
                    prepare_appcast_publication.update_appcast_release_version(appcast, target)

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
            "<!-- MacActivityReleaseRunId: 28485055775 -->\n"
            "<!-- MacActivityPrerelease: 2 -->\n"
            "## Features\n"
        )

        self.assertEqual(
            prepare_appcast_publication.sanitize_release_notes(notes),
            "## Features\n",
        )


if __name__ == "__main__":
    unittest.main()
