#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path


EXPECTED_MARKETING_VERSION = "0.1.0"
MARKETING_VERSION_KEY = "MARKETING_VERSION"


def setting_values(text, key):
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*([^#/\s]+)")
    values = []
    for line in text.splitlines():
        match = pattern.match(line)
        if match:
            values.append(match.group(1))
    return values


def validate_development_version(text, expected=EXPECTED_MARKETING_VERSION):
    values = setting_values(text, MARKETING_VERSION_KEY)
    if len(values) != 1:
        return [f"expected exactly one {MARKETING_VERSION_KEY} setting, found {len(values)}"]

    actual = values[0]
    if actual != expected:
        return [
            f"{MARKETING_VERSION_KEY} must stay {expected} during development; got {actual}"
        ]

    return []


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Validate that the checked-in development marketing version is stable."
    )
    parser.add_argument(
        "--xcconfig",
        default="Configuration/Shared.xcconfig",
        help="Path to the shared xcconfig file.",
    )
    parser.add_argument(
        "--expected",
        default=EXPECTED_MARKETING_VERSION,
        help="Expected development MARKETING_VERSION.",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        text = Path(args.xcconfig).read_text(encoding="utf-8")
    except OSError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    errors = validate_development_version(text, expected=args.expected)
    for error in errors:
        print(f"::error::{error}", file=sys.stderr)

    if errors:
        return 1

    print(f"Development {MARKETING_VERSION_KEY} is {args.expected}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
