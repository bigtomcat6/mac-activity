#!/usr/bin/env python3
"""Update or verify the README localization coverage table."""

from __future__ import annotations

import argparse
import html
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote


README_PATH = Path("README.md")
RESOURCES_PATH = Path("Sources/MacActivityApp/Resources")
LANGUAGE_SELF_NAME_KEY = "language.selfName"
START_MARKER = "<!-- localization-coverage:start -->"
END_MARKER = "<!-- localization-coverage:end -->"
BADGES_START_MARKER = "<!-- localization-badges:start -->"
BADGES_END_MARKER = "<!-- localization-badges:end -->"
SECTION_HEADING = "## Localization"

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
        help="fail if README.md does not already contain the generated table",
    )
    args = parser.parse_args()

    coverage = collect_coverage()
    table = render_coverage_table(coverage)
    badges = render_coverage_badges(coverage)
    readme = README_PATH.read_text(encoding="utf-8")
    updated = update_readme(readme, table, badges)

    if args.check:
        if updated != readme:
            print(
                "README.md localization coverage is out of date. "
                "Run python3 .github/scripts/update_localization_coverage.py.",
                file=sys.stderr,
            )
            return 1
        return 0

    README_PATH.write_text(updated, encoding="utf-8")
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


def render_coverage_badges(coverage: list[Coverage]) -> str:
    lines = ['<p align="center">']
    for row in coverage:
        percent = format_percent(row.overall_present, row.overall_total)
        color = badge_color(row.overall_present, row.overall_total)
        label = quote(f"l10n {row.display_name}", safe="")
        message = quote(percent, safe="")
        alt = html.escape(f"{row.display_name} localization {percent}", quote=True)
        lines.append(
            f'  <a href="#localization"><img src="https://img.shields.io/badge/{label}-{message}-{color}" alt="{alt}"></a>'
        )
    lines.append("</p>")
    return "\n".join(lines)


def format_ratio(present: int, total: int) -> str:
    if total == 0:
        return "n/a"
    return f"{format_percent(present, total)} ({present}/{total})"


def format_percent(present: int, total: int) -> str:
    if total == 0:
        return "n/a"
    percent = present / total * 100
    return f"{percent:.0f}%"


def badge_color(present: int, total: int) -> str:
    if total == 0:
        return "lightgrey"
    percent = present / total * 100
    if percent >= 100:
        return "2ea44f"
    if percent >= 90:
        return "dfb317"
    return "d73a49"


def update_readme(readme: str, table: str, badges: str) -> str:
    readme = update_badges(readme, badges)
    replacement = f"{START_MARKER}\n{table}\n{END_MARKER}"

    if START_MARKER in readme and END_MARKER in readme:
        start = readme.index(START_MARKER)
        end = readme.index(END_MARKER, start) + len(END_MARKER)
        return f"{readme[:start]}{replacement}{readme[end:]}"

    section = f"\n{SECTION_HEADING}\n\n{replacement}\n"
    badge_paragraphs = list(re.finditer(r'(?s)<p align="center">.*?</p>\n', readme))
    if badge_paragraphs:
        insert_at = badge_paragraphs[-1].end()
        return f"{readme[:insert_at]}{section}{readme[insert_at:]}"

    return f"{section.lstrip()}\n{readme}"


def update_badges(readme: str, badges: str) -> str:
    replacement = f"{BADGES_START_MARKER}\n{badges}\n{BADGES_END_MARKER}"

    if BADGES_START_MARKER in readme and BADGES_END_MARKER in readme:
        start = readme.index(BADGES_START_MARKER)
        end = readme.index(BADGES_END_MARKER, start) + len(BADGES_END_MARKER)
        return f"{readme[:start]}{replacement}{readme[end:]}"

    if SECTION_HEADING in readme:
        insert_at = readme.index(SECTION_HEADING)
        return f"{readme[:insert_at]}{replacement}\n\n{readme[insert_at:]}"

    badge_paragraphs = list(re.finditer(r'(?s)<p align="center">.*?</p>\n', readme))
    if badge_paragraphs:
        insert_at = badge_paragraphs[-1].end()
        return f"{readme[:insert_at]}\n{replacement}\n{readme[insert_at:]}"

    return f"{replacement}\n\n{readme}"


if __name__ == "__main__":
    raise SystemExit(main())
