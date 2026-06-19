import json
import struct
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
APP_ICON_SET = (
    REPO_ROOT
    / "Sources"
    / "MacActivityApp"
    / "Resources"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
)


def png_size(path):
    with path.open("rb") as image:
        if image.read(8) != b"\x89PNG\r\n\x1a\n":
            raise AssertionError(f"{path} is not a PNG")
        image.read(8)
        return struct.unpack(">II", image.read(8))


def expected_pixels_from_filename(filename):
    try:
        return int(filename.split("_")[-1].split("x")[0]) * (2 if "@2x" in filename else 1)
    except ValueError:
        return -1


class AppIconPolicyTests(unittest.TestCase):
    def test_project_uses_app_icon_asset_catalog_name(self):
        project = (REPO_ROOT / "project.yml").read_text(encoding="utf-8")

        self.assertIn("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon", project)

    def test_app_icon_asset_catalog_contains_complete_macos_sizes(self):
        contents = json.loads((APP_ICON_SET / "Contents.json").read_text(encoding="utf-8"))
        images = contents["images"]

        expected = {
            ("mac", "16x16", "1x", "icon_16x16.png", 16),
            ("mac", "16x16", "2x", "icon_16x16@2x.png", 32),
            ("mac", "32x32", "1x", "icon_32x32.png", 32),
            ("mac", "32x32", "2x", "icon_32x32@2x.png", 64),
            ("mac", "128x128", "1x", "icon_128x128.png", 128),
            ("mac", "128x128", "2x", "icon_128x128@2x.png", 256),
            ("mac", "256x256", "1x", "icon_256x256.png", 256),
            ("mac", "256x256", "2x", "icon_256x256@2x.png", 512),
            ("mac", "512x512", "1x", "icon_512x512.png", 512),
            ("mac", "512x512", "2x", "icon_512x512@2x.png", 1024),
        }

        actual = {
            (
                image["idiom"],
                image["size"],
                image["scale"],
                image["filename"],
                expected_pixels_from_filename(image["filename"]),
            )
            for image in images
        }

        self.assertEqual(actual, expected)

        for image in images:
            filename = image["filename"]
            expected_pixels = expected_pixels_from_filename(filename)
            self.assertGreater(expected_pixels, 0)
            self.assertEqual(png_size(APP_ICON_SET / filename), (expected_pixels, expected_pixels))

    def test_app_icon_source_svg_is_kept_with_release_assets(self):
        source = REPO_ROOT / "assets" / "app-icon" / "mac-activity-icon-simple.svg"

        self.assertTrue(source.exists())


if __name__ == "__main__":
    unittest.main()
