#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


SECTION_ORDER = (
    ("breaking", "## ⚠️ Breaking Changes"),
    ("security", "## 🔒 Security"),
    ("feature", "## ✨ Features"),
    ("bugfix", "## 🐛 Bug Fixes"),
    ("performance", "## ⚡ Performance"),
)
OTHER_SECTION = "## Other Changes"
SKIP_LABEL = "skip-release-notes"
CONVENTIONAL_TITLE_PREFIX = re.compile(r"^[a-zA-Z]+(?:\([^)]+\))?!?:\s+")
STABLE_RELEASE_TAG = re.compile(r"^v\d+\.\d+\.\d+$")
TERMINAL_PUNCTUATION = (".", "!", "?", ")", "]", "`")


@dataclass(frozen=True)
class PullRequest:
    number: int
    title: str
    labels: tuple[str, ...]


def normalize_label(label: str) -> str:
    normalized = label.strip().lower()
    if normalized.startswith("release:"):
        return normalized.split(":", 1)[1].strip()
    return normalized


def section_for_labels(labels: tuple[str, ...]) -> str:
    normalized_labels = {normalize_label(label) for label in labels}
    for label, section in SECTION_ORDER:
        if label in normalized_labels:
            return section
    if "other" in normalized_labels:
        return OTHER_SECTION
    return OTHER_SECTION


def is_skipped(labels: tuple[str, ...]) -> bool:
    return SKIP_LABEL in {normalize_label(label) for label in labels}


def release_note_title(title: str) -> str:
    title = CONVENTIONAL_TITLE_PREFIX.sub("", title).strip()
    if not title:
        return "Untitled change."

    title = title[0].upper() + title[1:]
    if title.endswith(TERMINAL_PUNCTUATION):
        return title
    return f"{title}."


def release_note_entry(pr: PullRequest) -> str:
    return f"- {release_note_title(pr.title)} (#{pr.number})"


def pull_request_from_payload(payload: dict) -> PullRequest:
    labels = []
    for label in payload.get("labels", []):
        if isinstance(label, dict):
            name = label.get("name")
        else:
            name = str(label)
        if name:
            labels.append(name)

    return PullRequest(
        number=int(payload["number"]),
        title=str(payload.get("title") or ""),
        labels=tuple(labels),
    )


def unique_pull_requests(payloads: list[dict]) -> list[PullRequest]:
    seen = set()
    pull_requests = []
    for payload in payloads:
        pr = pull_request_from_payload(payload)
        if pr.number in seen:
            continue
        seen.add(pr.number)
        pull_requests.append(pr)
    return pull_requests


def render_release_notes(pull_requests: list[PullRequest]) -> str:
    grouped = {section: [] for _, section in SECTION_ORDER}
    grouped[OTHER_SECTION] = []

    for pr in pull_requests:
        if is_skipped(pr.labels):
            continue
        grouped[section_for_labels(pr.labels)].append(release_note_entry(pr))

    sections = []
    for section, entries in grouped.items():
        if entries:
            sections.append(f"{section}\n\n" + "\n".join(entries))

    if not sections:
        return ""
    return "\n\n".join(sections) + "\n"


def run_command(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout.strip()


def is_stable_release_tag(tag: str) -> bool:
    return bool(STABLE_RELEASE_TAG.fullmatch(tag))


def find_latest_reachable_tag(target: str, run=run_command) -> str | None:
    try:
        return run(["git", "describe", "--tags", "--abbrev=0", target])
    except subprocess.CalledProcessError:
        return None


def find_previous_stable_tag(
    target: str,
    current_tag: str,
    run=run_command,
) -> str | None:
    try:
        output = run(["git", "tag", "--merged", target, "--sort=-creatordate"])
    except subprocess.CalledProcessError:
        return None

    for tag in output.splitlines():
        tag = tag.strip()
        if tag == current_tag:
            continue
        if is_stable_release_tag(tag):
            return tag
    return None


def find_previous_tag(
    target: str,
    current_tag: str | None = None,
    run=run_command,
) -> str | None:
    if current_tag and is_stable_release_tag(current_tag):
        return find_previous_stable_tag(target, current_tag, run=run)
    return find_latest_reachable_tag(target, run=run)


def commits_since(previous_tag: str | None, target: str) -> list[str]:
    revision = f"{previous_tag}..{target}" if previous_tag else target
    output = run_command(["git", "rev-list", "--reverse", revision])
    if not output:
        return []
    return output.splitlines()


def pull_requests_for_commit(repo: str, commit: str) -> list[dict]:
    output = run_command(
        [
            "gh",
            "api",
            "-H",
            "Accept: application/vnd.github+json",
            f"/repos/{repo}/commits/{commit}/pulls",
        ]
    )
    return json.loads(output)


def collect_pull_requests(repo: str, target: str, previous_tag: str | None) -> list[PullRequest]:
    payloads = []
    for commit in commits_since(previous_tag, target):
        payloads.extend(pull_requests_for_commit(repo, commit))
    return unique_pull_requests(payloads)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate GitHub Release notes from PR release labels."
    )
    parser.add_argument("--repo", required=True, help="GitHub repository in owner/name form.")
    parser.add_argument("--target", required=True, help="Target commit SHA for this release.")
    parser.add_argument(
        "--previous-tag",
        default=None,
        help="Previous release tag. Defaults to the latest reachable tag before target.",
    )
    parser.add_argument(
        "--current-tag",
        default=None,
        help=(
            "Current release tag. Stable tags default previous-tag selection to the "
            "latest stable tag before target."
        ),
    )
    parser.add_argument("--output", required=True, help="Release notes markdown output path.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    previous_tag = args.previous_tag
    if previous_tag is None:
        previous_tag = find_previous_tag(args.target, current_tag=args.current_tag)

    try:
        pull_requests = collect_pull_requests(args.repo, args.target, previous_tag)
        notes = render_release_notes(pull_requests)
        Path(args.output).write_text(notes, encoding="utf-8")
    except (json.JSONDecodeError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        print(f"::error::failed to generate release notes: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
