#!/usr/bin/env bash
set -euo pipefail

APPDMG_VERSION="${APPDMG_VERSION:-0.6.6}"

APP_PATH=""
OUTPUT_PATH=""
VOLUME_NAME=""
BACKGROUND_PATH=""

WINDOW_WIDTH=627
WINDOW_HEIGHT=560
ICON_SIZE=96
APP_X=185
APP_Y=290
APPLICATIONS_X=442
APPLICATIONS_Y=290
APPLICATIONS_ALIAS_NAME="Applications"

WORK_DIR=""

usage() {
  cat <<'USAGE'
Usage: .github/scripts/create_dmg.sh --app APP --output DMG --volume-name NAME --background PNG

Creates a styled macOS installer DMG with the app bundle, an Applications
alias, and a Finder background image.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

absolute_existing_path() {
  local path="$1"
  local dir
  local base
  dir="$(cd "$(dirname "${path}")" && pwd)"
  base="$(basename "${path}")"
  printf '%s/%s\n' "${dir}" "${base}"
}

absolute_output_path() {
  local path="$1"
  local dir
  local base
  dir="$(dirname "${path}")"
  base="$(basename "${path}")"
  mkdir -p "${dir}"
  dir="$(cd "${dir}" && pwd)"
  printf '%s/%s\n' "${dir}" "${base}"
}

create_applications_alias() {
  local alias_path="${STAGING_DIR}/${APPLICATIONS_ALIAS_NAME}"

  rm -f "${alias_path}"
  /usr/bin/osascript - "${STAGING_DIR}" >/dev/null <<'OSA'
on run argv
  set outputFolder to POSIX file (item 1 of argv) as alias
  tell application "Finder"
    make new alias file to POSIX file "/Applications" at outputFolder with properties {name:"Applications"}
  end tell
end run
OSA

  [[ -f "${alias_path}" ]] || die "failed to create Applications alias"
  [[ ! -L "${alias_path}" ]] || die "Applications alias must not be a symlink"
  file "${alias_path}" | grep -q "MacOS Alias file" || die "Applications item is not a Finder alias"
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --volume-name)
      VOLUME_NAME="$2"
      shift 2
      ;;
    --background)
      BACKGROUND_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "${APP_PATH}" ]] || die "--app is required"
[[ -n "${OUTPUT_PATH}" ]] || die "--output is required"
[[ -n "${VOLUME_NAME}" ]] || die "--volume-name is required"
[[ -n "${BACKGROUND_PATH}" ]] || die "--background is required"
[[ -d "${APP_PATH}" ]] || die "app bundle not found: ${APP_PATH}"
[[ -f "${BACKGROUND_PATH}" ]] || die "background image not found: ${BACKGROUND_PATH}"
command -v npx >/dev/null || die "npx is required to run appdmg"
command -v python3 >/dev/null || die "python3 is required to write the appdmg spec"
command -v osascript >/dev/null || die "osascript is required to create the Applications alias"

APP_PATH="$(absolute_existing_path "${APP_PATH}")"
BACKGROUND_PATH="$(absolute_existing_path "${BACKGROUND_PATH}")"
OUTPUT_PATH="$(absolute_output_path "${OUTPUT_PATH}")"

APP_BASENAME="$(basename "${APP_PATH}")"
BACKGROUND_BASENAME="background.png"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macactivity-dmg.XXXXXX")"
STAGING_DIR="${WORK_DIR}/staging"
SPEC_PATH="${STAGING_DIR}/appdmg.json"

mkdir -p "${STAGING_DIR}"
ditto "${APP_PATH}" "${STAGING_DIR}/${APP_BASENAME}"
ditto "${BACKGROUND_PATH}" "${STAGING_DIR}/${BACKGROUND_BASENAME}"
create_applications_alias

python3 - "${SPEC_PATH}" "${VOLUME_NAME}" "${APP_BASENAME}" "${BACKGROUND_BASENAME}" "${APPLICATIONS_ALIAS_NAME}" \
  "${WINDOW_WIDTH}" "${WINDOW_HEIGHT}" "${ICON_SIZE}" \
  "${APP_X}" "${APP_Y}" "${APPLICATIONS_X}" "${APPLICATIONS_Y}" <<'PY'
import json
import sys
from pathlib import Path

(
    spec_path,
    volume_name,
    app_name,
    background_name,
    applications_alias_name,
    window_width,
    window_height,
    icon_size,
    app_x,
    app_y,
    applications_x,
    applications_y,
) = sys.argv[1:]

spec = {
    "title": volume_name,
    "background": background_name,
    "icon-size": int(icon_size),
    "window": {
        "size": {
            "width": int(window_width),
            "height": int(window_height),
        },
    },
    "format": "UDZO",
    "filesystem": "HFS+",
    "contents": [
        {
            "x": int(app_x),
            "y": int(app_y),
            "type": "file",
            "path": app_name,
        },
        {
            "x": int(applications_x),
            "y": int(applications_y),
            "type": "file",
            "path": applications_alias_name,
        },
        {
            "x": 900,
            "y": 900,
            "type": "position",
            "path": ".background",
        },
        {
            "x": 900,
            "y": 900,
            "type": "position",
            "path": ".DS_Store",
        },
    ],
}

Path(spec_path).write_text(json.dumps(spec, indent=2) + "\n", encoding="utf-8")
PY

rm -f "${OUTPUT_PATH}"
npx --yes "appdmg@${APPDMG_VERSION}" "${SPEC_PATH}" "${OUTPUT_PATH}"

printf 'Created %s\n' "${OUTPUT_PATH}"
