#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
from pathlib import Path


ALLOWED_TYPES = {
    "feat",
    "fix",
    "perf",
    "test",
    "docs",
    "refactor",
    "build",
    "ci",
    "chore",
}
ALLOWED_SCOPES = {
    "actives",
    "app",
    "core",
    "dashboard",
    "docs",
    "metrics",
    "prefs",
    "release",
}
REQUIRED_SECTIONS = (
    "Summary",
    "How to test",
    "Release impact",
    "Checklist",
)
TITLE_PATTERN = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[a-z]+)\))?(?P<breaking>!)?: (?P<summary>.+)$"
)
TICKET_PATTERN = re.compile(r"\b[A-Z]{2,}-\d+\b")
NO_CHANGELOG_SUFFIX = re.compile(r"\s+\(no-changelog\)$")


def validate_title(title):
    errors = []
    match = TITLE_PATTERN.match(title or "")
    if not match:
        return ["title must match '<type>(<scope>): <Summary>'"]

    title_type = match.group("type")
    scope = match.group("scope")
    summary = match.group("summary")
    summary_without_suffix = NO_CHANGELOG_SUFFIX.sub("", summary)

    if title_type not in ALLOWED_TYPES:
        errors.append(f"title type must be one of: {', '.join(sorted(ALLOWED_TYPES))}")
    if scope is not None and scope not in ALLOWED_SCOPES:
        errors.append(f"title scope must be one of: {', '.join(sorted(ALLOWED_SCOPES))}")
    if not summary_without_suffix:
        errors.append("title summary must not be empty")
    elif not summary_without_suffix[0].isupper():
        errors.append("title summary must start with a capital letter")
    if summary_without_suffix.endswith("."):
        errors.append("title must not end with a period")
    if TICKET_PATTERN.search(title):
        errors.append("title must not include ticket IDs")

    return errors


def strip_comments(text):
    return re.sub(r"<!--.*?-->", "", text or "", flags=re.DOTALL).strip()


def section_content(body, section):
    pattern = re.compile(
        rf"^##\s+{re.escape(section)}\s*$\n(?P<content>.*?)(?=^##\s+|\Z)",
        flags=re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(body or "")
    if not match:
        return None
    return strip_comments(match.group("content"))


def validate_body(body):
    errors = []
    for section in REQUIRED_SECTIONS:
        content = section_content(body, section)
        if content is None:
            errors.append(f"body is missing required section: ## {section}")
            continue
        if section != "Checklist" and not content:
            errors.append(f"body section must not be empty: ## {section}")
    return errors


def validate_pr(title, body):
    return validate_title(title) + validate_body(body)


def read_event(event_path):
    data = json.loads(Path(event_path).read_text())
    pull_request = data.get("pull_request")
    if not pull_request:
        raise ValueError("GitHub event does not contain pull_request")
    return pull_request.get("title", ""), pull_request.get("body") or ""


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate pull request title and body.")
    parser.add_argument("--event", help="Path to GitHub event JSON")
    parser.add_argument("--title", help="PR title for local checks")
    parser.add_argument("--body-file", help="PR body markdown file for local checks")
    args = parser.parse_args(argv)

    if args.event or os.environ.get("GITHUB_EVENT_PATH"):
        title, body = read_event(args.event or os.environ["GITHUB_EVENT_PATH"])
    elif args.title and args.body_file:
        title = args.title
        body = Path(args.body_file).read_text()
    else:
        parser.error("provide --event or both --title and --body-file")

    errors = validate_pr(title, body)
    for error in errors:
        print(f"::error::{error}")
    if errors:
        return 1

    print("PR metadata looks valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
