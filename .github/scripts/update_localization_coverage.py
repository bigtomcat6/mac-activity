#!/usr/bin/env python3
"""Check localization resource coverage."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


RESOURCES_PATH = Path("Sources/MacActivityApp/Resources")
LANGUAGE_SELF_NAME_KEY = "language.selfName"

STRING_ENTRY_RE = re.compile(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;', re.DOTALL)


@dataclass(frozen=True)
class Coverage:
    language_identifier: str
    display_name: str
    app_present: int
    app_total: int
    metadata_present: int
    metadata_total: int

    @property
    def overall_present(self) -> int:
        return self.app_present + self.metadata_present

    @property
    def overall_total(self) -> int:
        return self.app_total + self.metadata_total


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if any localized resource is missing baseline keys",
    )
    parser.add_argument(
        "--badge-json-dir",
        type=Path,
        help="write one Shields.io endpoint JSON file per language",
    )
    args = parser.parse_args()

    coverage = collect_coverage()

    if args.badge_json_dir:
        write_shields_endpoint_badges(coverage, args.badge_json_dir)

    if args.check:
        incomplete = incomplete_coverage(coverage)
        if incomplete:
            print(
                "Localization coverage is incomplete:",
                file=sys.stderr,
            )
            print(render_coverage_table(coverage), file=sys.stderr)
            return 1
        return 0

    print(render_coverage_table(coverage))
    return 0


def collect_coverage() -> list[Coverage]:
    languages = available_languages()
    if "en" not in languages:
        raise SystemExit("Missing required en.lproj localization baseline.")

    localizable = {
        language: parse_strings(RESOURCES_PATH / f"{language}.lproj" / "Localizable.strings")
        for language in languages
    }
    info_plist = {
        language: parse_strings(RESOURCES_PATH / f"{language}.lproj" / "InfoPlist.strings")
        for language in languages
    }

    expected_app_keys = set(localizable["en"].keys())
    expected_metadata_keys = set(info_plist["en"].keys())

    rows: list[Coverage] = []
    for language in languages:
        app_keys = set(localizable[language].keys())
        metadata_keys = set(info_plist[language].keys())
        rows.append(
            Coverage(
                language_identifier=language,
                display_name=localizable[language].get(LANGUAGE_SELF_NAME_KEY, language),
                app_present=len(app_keys & expected_app_keys),
                app_total=len(expected_app_keys),
                metadata_present=len(metadata_keys & expected_metadata_keys),
                metadata_total=len(expected_metadata_keys),
            )
        )

    return rows


def available_languages() -> list[str]:
    languages = [
        path.name.removesuffix(".lproj")
        for path in RESOURCES_PATH.glob("*.lproj")
        if path.is_dir() and path.name != "Base.lproj"
    ]
    return sorted(languages, key=lambda language: (language != "en", language.casefold()))


def parse_strings(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}

    text = path.read_text(encoding="utf-8")
    return {
        unescape_strings_token(key): unescape_strings_token(value)
        for key, value in STRING_ENTRY_RE.findall(text)
    }


def unescape_strings_token(value: str) -> str:
    return (
        value
        .replace(r"\"", '"')
        .replace(r"\n", "\n")
        .replace(r"\t", "\t")
        .replace(r"\\", "\\")
    )


def render_coverage_table(coverage: list[Coverage]) -> str:
    lines = [
        "_Coverage counts resource-key presence; translation wording is reviewed separately._",
        "",
        "| Language | App UI | Bundle metadata | Overall |",
        "| --- | ---: | ---: | ---: |",
    ]

    for row in coverage:
        lines.append(
            "| {language} | {app} | {metadata} | {overall} |".format(
                language=row.display_name,
                app=format_ratio(row.app_present, row.app_total),
                metadata=format_ratio(row.metadata_present, row.metadata_total),
                overall=format_ratio(row.overall_present, row.overall_total),
            )
        )

    return "\n".join(lines)


def incomplete_coverage(coverage: list[Coverage]) -> list[Coverage]:
    return [
        row
        for row in coverage
        if row.app_present < row.app_total
        or row.metadata_present < row.metadata_total
    ]


def write_shields_endpoint_badges(coverage: list[Coverage], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    for row in coverage:
        payload = {
            "schemaVersion": 1,
            "label": f"l10n {row.display_name}",
            "message": format_percent(row.overall_present, row.overall_total),
            "color": shields_color(row.overall_present, row.overall_total),
        }
        path = output_dir / f"{row.language_identifier}.json"
        path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )


def format_ratio(present: int, total: int) -> str:
    if total == 0:
        return "n/a"
    return f"{format_percent(present, total)} ({present}/{total})"


def format_percent(present: int, total: int) -> str:
    if total == 0:
        return "n/a"
    percent = present / total * 100
    return f"{percent:.0f}%"


def shields_color(present: int, total: int) -> str:
    if total == 0:
        return "lightgrey"
    percent = present / total * 100
    if percent >= 100:
        return "brightgreen"
    if percent >= 90:
        return "yellow"
    return "red"


if __name__ == "__main__":
    raise SystemExit(main())
