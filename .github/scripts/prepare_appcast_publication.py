#!/usr/bin/env python3
import argparse
import html
import re
import sys
from pathlib import Path


INTERNAL_METADATA_COMMENT_PATTERN = re.compile(
    r"^<!--\s*MacActivity(?:ReleaseTag|BundleBuild|ReleaseRunId|Prerelease):.*?-->\r?\n?",
    re.MULTILINE,
)


def public_version(tag):
    return tag.removeprefix("v")


def update_appcast_release_version(appcast, tag):
    escaped_tag = re.escape(f"/releases/download/{tag}/")
    item_pattern = re.compile(rf"<item>.*?{escaped_tag}.*?</item>", re.DOTALL)
    match = item_pattern.search(appcast)
    if not match:
        raise ValueError(f"could not find appcast item for {tag}")

    item = match.group(0)
    version = html.escape(public_version(tag), quote=False)
    item = replace_once(
        r"<title>[^<]*</title>",
        f"<title>{version}</title>",
        item,
        "title",
        tag,
    )
    item = replace_once(
        r"<sparkle:shortVersionString>[^<]*</sparkle:shortVersionString>",
        f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>",
        item,
        "sparkle:shortVersionString",
        tag,
    )
    return appcast[: match.start()] + item + appcast[match.end() :]


def sanitize_release_notes(notes):
    return INTERNAL_METADATA_COMMENT_PATTERN.sub("", notes)


def replace_once(pattern, replacement, text, field, tag):
    updated, count = re.subn(pattern, replacement, text, count=1)
    if count != 1:
        raise ValueError(f"could not update {field} for {tag}")
    return updated


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Prepare generated Sparkle appcast and release notes for public display."
    )
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--release-notes", required=True)
    parser.add_argument("--tag", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        appcast_path = Path(args.appcast)
        appcast_path.write_text(
            update_appcast_release_version(
                appcast_path.read_text(encoding="utf-8"),
                args.tag,
            ),
            encoding="utf-8",
        )

        notes_path = Path(args.release_notes)
        notes_path.write_text(
            sanitize_release_notes(notes_path.read_text(encoding="utf-8")),
            encoding="utf-8",
        )
    except OSError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
