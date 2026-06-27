#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path


ALLOWED_CHANNELS = ("alpha", "beta", "rc", "release")
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")
POSITIVE_INTEGER_PATTERN = re.compile(r"^[1-9]\d*$")
TAG_PATTERN = re.compile(
    r"^v(?P<version>\d+\.\d+\.\d+)(?:-(?P<channel>alpha|beta|rc)\.(?P<prerelease>\d+))?$"
)
BUNDLE_BUILD_METADATA_PATTERN = re.compile(
    r"<!--\s*MacActivityBundleBuild:\s*(?P<build>[1-9]\d*)\s*-->"
)


def optional_value(value):
    return None if value is None or value == "" else value


def make_tag(channel, version, prerelease):
    validate_channel(channel)
    validate_version(version)
    if channel == "release":
        return f"v{version}"
    validate_positive_integer(prerelease, "prerelease")
    return f"v{version}-{channel}.{prerelease}"


def validate_channel(channel):
    if channel not in ALLOWED_CHANNELS:
        raise ValueError(f"channel must be one of: {', '.join(ALLOWED_CHANNELS)}")


def validate_version(version):
    if not version or not VERSION_PATTERN.fullmatch(version):
        raise ValueError("version must use MAJOR.MINOR.PATCH, for example 26.0.0")


def validate_positive_integer(value, name):
    if not value or not POSITIVE_INTEGER_PATTERN.fullmatch(str(value)):
        raise ValueError(f"{name} must be a positive integer")


def normalize_release(release):
    tag = release.get("tagName") or release.get("tag_name")
    is_draft = bool(release.get("isDraft") or release.get("draft"))
    return tag, is_draft


def normalize_releases_payload(payload):
    if payload and all(isinstance(page, list) for page in payload):
        return [release for page in payload for release in page]
    return payload


def parse_tag(tag):
    match = TAG_PATTERN.fullmatch(tag or "")
    if not match:
        return None
    return {
        "tag": tag,
        "version": match.group("version"),
        "channel": match.group("channel") or "release",
        "prerelease": match.group("prerelease"),
    }


def sort_version_key(version):
    return tuple(int(part) for part in version.split("."))


def release_tags(existing_releases):
    return [
        tag
        for release in existing_releases
        for tag, _ in [normalize_release(release)]
        if tag
    ]


def parsed_tags(existing_tags, existing_releases):
    known_tags = list(existing_tags) + release_tags(existing_releases)
    return [parsed for tag in known_tags if (parsed := parse_tag(tag))]


def release_body(release):
    return release.get("body") or release.get("bodyText") or ""


def release_bundle_build(release):
    match = BUNDLE_BUILD_METADATA_PATTERN.search(release_body(release))
    if not match:
        return None
    return int(match.group("build"))


def max_prerelease_for_version(channel, version, tags):
    return max(
        (
            int(tag["prerelease"])
            for tag in tags
            if tag["version"] == version
            and tag["channel"] == channel
            and tag["prerelease"]
        ),
        default=0,
    )


def max_bundle_build_for_version(version, tags, existing_releases):
    builds = []
    for tag in tags:
        if tag["version"] == version and tag["prerelease"]:
            builds.append(int(tag["prerelease"]))

    for release in existing_releases:
        tag, _ = normalize_release(release)
        parsed = parse_tag(tag)
        if not parsed or parsed["version"] != version:
            continue
        build = release_bundle_build(release)
        if build is not None:
            builds.append(build)

    return max(builds, default=0)


def suggest_release(channel, existing_tags, existing_releases, release_year):
    validate_channel(channel)
    tags = parsed_tags(existing_tags, existing_releases)
    year_prefix = f"{release_year}."
    year_versions = sorted(
        {tag["version"] for tag in tags if tag["version"].startswith(year_prefix)},
        key=sort_version_key,
    )
    version = year_versions[-1] if year_versions else f"{release_year}.0.0"
    build = str(max_bundle_build_for_version(version, tags, existing_releases) + 1)

    if channel == "release":
        prerelease = None
    else:
        prerelease = str(max_prerelease_for_version(channel, version, tags) + 1)

    return {
        "suggested_version": version,
        "suggested_prerelease": prerelease,
        "suggested_build": build,
        "suggested_tag": make_tag(channel, version, prerelease),
    }


def detect_conflicts(tag, existing_tags, existing_releases, version, build, tags):
    conflicts = []
    if tag in set(existing_tags):
        conflicts.append(f"tag already exists: {tag}")

    for release in existing_releases:
        release_tag, is_draft = normalize_release(release)
        if release_tag != tag:
            continue
        if is_draft:
            conflicts.append(f"draft release already exists: {tag}")
        else:
            conflicts.append(f"release already exists: {tag}")

    existing_build = max_bundle_build_for_version(version, tags, existing_releases)
    if int(build) <= existing_build:
        conflicts.append(
            f"build {build} must be greater than existing build {existing_build} for {version}"
        )
    return conflicts


def plan_release(channel, version, prerelease, build, existing_tags, existing_releases, release_year):
    prerelease = optional_value(prerelease)
    build = optional_value(build)
    validate_channel(channel)
    suggestion = suggest_release(channel, existing_tags, existing_releases, release_year)

    if version is None:
        return {
            "channel": channel,
            "version": None,
            "prerelease": None,
            "build": None,
            "tag": None,
            "conflicts": [],
            **suggestion,
        }

    validate_version(version)
    validate_positive_integer(build, "build")
    if channel == "release":
        if prerelease is not None:
            raise ValueError("prerelease must be empty for release channel")
    else:
        validate_positive_integer(prerelease, "prerelease")

    tag = make_tag(channel, version, prerelease)
    tags = parsed_tags(existing_tags, existing_releases)
    return {
        "channel": channel,
        "version": version,
        "prerelease": prerelease,
        "build": str(build),
        "tag": tag,
        "conflicts": detect_conflicts(
            tag,
            existing_tags,
            existing_releases,
            version,
            build,
            tags,
        ),
        **suggestion,
    }


def run_command(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)


def load_remote_tags():
    try:
        output = run_command(["git", "ls-remote", "--tags", "--refs", "origin", "v*"])
    except subprocess.CalledProcessError:
        output = run_command(["git", "tag", "--list", "v*"])

    tags = []
    for line in output.splitlines():
        if "refs/tags/" in line:
            tags.append(line.rsplit("refs/tags/", 1)[1].strip())
        elif line.strip():
            tags.append(line.strip())
    return tags


def load_remote_releases():
    output = run_command(
        ["gh", "api", "--paginate", "--slurp", "repos/{owner}/{repo}/releases"]
    )
    return normalize_releases_payload(json.loads(output or "[]"))


def load_json_file(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_output(plan, output_path):
    if not output_path:
        return
    with Path(output_path).open("a", encoding="utf-8") as output:
        for key, value in plan.items():
            if isinstance(value, list):
                value = json.dumps(value)
            output.write(f"{key}={'' if value is None else value}\n")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Plan and preflight a MacActivity release.")
    parser.add_argument("--channel", choices=ALLOWED_CHANNELS, required=True)
    parser.add_argument("--version")
    parser.add_argument("--prerelease")
    parser.add_argument("--build")
    parser.add_argument("--release-year", type=int, default=int(dt.date.today().strftime("%y")))
    parser.add_argument("--remote", action="store_true", help="Read tags and releases from GitHub.")
    parser.add_argument("--tags-file", help="JSON file containing a list of tag names.")
    parser.add_argument("--releases-file", help="JSON file containing a GitHub releases list.")
    parser.add_argument(
        "--output",
        default=os.environ.get("GITHUB_OUTPUT"),
        help="GitHub Actions output file. Defaults to GITHUB_OUTPUT when set.",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        if args.remote:
            existing_tags = load_remote_tags()
            existing_releases = load_remote_releases()
        else:
            existing_tags = load_json_file(args.tags_file) if args.tags_file else []
            existing_releases = (
                normalize_releases_payload(load_json_file(args.releases_file))
                if args.releases_file
                else []
            )

        plan = plan_release(
            channel=args.channel,
            version=args.version,
            prerelease=args.prerelease,
            build=args.build,
            existing_tags=existing_tags,
            existing_releases=existing_releases,
            release_year=args.release_year,
        )
    except (json.JSONDecodeError, OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    print(json.dumps(plan, indent=2, sort_keys=True))
    write_output(plan, args.output)
    if plan["conflicts"]:
        for conflict in plan["conflicts"]:
            print(f"::error::{conflict}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
