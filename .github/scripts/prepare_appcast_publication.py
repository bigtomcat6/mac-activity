#!/usr/bin/env python3
import argparse
import re
import sys
import xml.etree.ElementTree as ET
from xml.parsers import expat
from pathlib import Path
from urllib.parse import urlsplit


INTERNAL_METADATA_COMMENT_PATTERN = re.compile(
    r"^<!--\s*MacActivity(?:ReleaseTag|BundleBuild|ReleaseRunId|Prerelease):.*?-->\r?\n?",
    re.MULTILINE,
)


def public_version(tag):
    return tag.removeprefix("v")


def update_appcast_release_version(appcast, tag):
    try:
        document = ET.fromstring(appcast)
    except ET.ParseError as error:
        raise ValueError(f"invalid appcast XML: {error}") from error

    items = document.findall("./channel/item")
    release_path = f"/releases/download/{tag}/"
    matches = [
        index for index, item in enumerate(items)
        if any(
            release_path in urlsplit(enclosure.get("url", "")).path
            for enclosure in item.findall("enclosure")
        )
    ]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one appcast item for {tag}, found {len(matches)}")

    item_index = matches[0]
    item = items[item_index]
    sparkle_namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    for field in ("title", f"{{{sparkle_namespace}}}shortVersionString"):
        fields = item.findall(field)
        if len(fields) != 1 or len(fields[0]):
            raise ValueError(f"expected exactly one text {field} for {tag}")
        fields[0].text = public_version(tag)

    # Locate actual XML elements, not strings in descriptions or comments. Only
    # reserialize the selected item; preserve the rest of the feed byte-for-byte.
    encoded = appcast.encode("utf-8")
    spans = []
    stack = []
    item_start = None
    parser = expat.ParserCreate()

    def start_element(name, attributes):
        nonlocal item_start
        stack.append(name)
        if stack == ["rss", "channel", "item"]:
            item_start = parser.CurrentByteIndex

    def end_element(name):
        if stack == ["rss", "channel", "item"]:
            end = encoded.index(b">", parser.CurrentByteIndex) + 1
            spans.append((item_start, end))
        stack.pop()

    parser.StartElementHandler = start_element
    parser.EndElementHandler = end_element
    parser.Parse(encoded, True)
    if len(spans) != len(items):
        raise ValueError("unsupported appcast item structure")
    start, end = spans[item_index]
    ET.register_namespace("sparkle", sparkle_namespace)
    item.tail = None
    replacement = ET.tostring(item, encoding="utf-8")
    return (encoded[:start] + replacement + encoded[end:]).decode("utf-8")


def sanitize_release_notes(notes):
    return INTERNAL_METADATA_COMMENT_PATTERN.sub("", notes)


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
