#!/usr/bin/env python3
import argparse
import os
import re
import sys
from pathlib import Path


APP_NAME = "Mac Activity"
ALLOWED_CHANNELS = ("alpha", "beta", "rc", "release")
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")
BUILD_PATTERN = re.compile(r"^[1-9]\d*$")


def validate(channel, version, prerelease, build):
    if channel not in ALLOWED_CHANNELS:
        raise ValueError(f"channel must be one of: {', '.join(ALLOWED_CHANNELS)}")
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("version must use MAJOR.MINOR.PATCH, for example 1.2.3")
    if not BUILD_PATTERN.fullmatch(build):
        raise ValueError("build must be a positive integer")
    if channel == "release":
        if prerelease not in (None, ""):
            raise ValueError("prerelease must be empty for release channel")
    elif not prerelease or not BUILD_PATTERN.fullmatch(prerelease):
        raise ValueError("prerelease must be a positive integer")


def build_metadata(channel, version, prerelease, build):
    validate(channel, version, prerelease, build)

    if channel == "release":
        suffix = ""
        prerelease = "false"
        prerelease_number = ""
        latest = "true"
    else:
        suffix = f"-{channel}.{prerelease}"
        prerelease_number = prerelease
        prerelease = "true"
        latest = "false"

    tag = f"v{version}{suffix}"
    release_title = tag.removeprefix("v")
    return {
        "app_name": APP_NAME,
        "channel": channel,
        "version": version,
        "build": build,
        "prerelease_number": prerelease_number,
        "tag": tag,
        "title": release_title,
        "prerelease": prerelease,
        "latest": latest,
        "artifact_stem": f"MacActivity-{tag}",
    }


def replace_setting(text, key, value):
    pattern = re.compile(rf"^({re.escape(key)}\s*=\s*).*$", re.MULTILINE)
    updated, count = pattern.subn(rf"\g<1>{value}", text)
    if count != 1:
        raise ValueError(f"expected exactly one {key} setting")
    return updated


def update_xcconfig(text, version, build, release_tag):
    updated = replace_setting(text, "MARKETING_VERSION", version)
    updated = replace_setting(updated, "CURRENT_PROJECT_VERSION", build)
    return replace_setting(updated, "MAC_ACTIVITY_RELEASE_TAG", release_tag)


def write_github_output(metadata, output_path):
    with Path(output_path).open("a", encoding="utf-8") as output:
        for key, value in metadata.items():
            output.write(f"{key}={value}\n")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Prepare MacActivity release metadata and update Shared.xcconfig."
    )
    parser.add_argument("--channel", choices=ALLOWED_CHANNELS, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--prerelease")
    parser.add_argument("--build", required=True)
    parser.add_argument("--xcconfig", required=True)
    parser.add_argument(
        "--output",
        default=os.environ.get("GITHUB_OUTPUT"),
        help="GitHub Actions output file. Defaults to GITHUB_OUTPUT when set.",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        metadata = build_metadata(args.channel, args.version, args.prerelease, args.build)
        xcconfig_path = Path(args.xcconfig)
        updated = update_xcconfig(
            xcconfig_path.read_text(encoding="utf-8"),
            args.version,
            args.build,
            metadata["tag"],
        )
        xcconfig_path.write_text(updated, encoding="utf-8")
        if args.output:
            write_github_output(metadata, args.output)
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    print(f"Prepared {metadata['title']} ({metadata['tag']}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
