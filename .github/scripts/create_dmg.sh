#!/usr/bin/env bash
set -euo pipefail


APP_PATH=""
OUTPUT_PATH=""
VOLUME_NAME=""
BACKGROUND_PATH=""

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
command -v hdiutil >/dev/null || die "hdiutil is required to create the disk image"
command -v osascript >/dev/null || die "osascript is required to create the Applications alias"

APP_PATH="$(absolute_existing_path "${APP_PATH}")"
BACKGROUND_PATH="$(absolute_existing_path "${BACKGROUND_PATH}")"
OUTPUT_PATH="$(absolute_output_path "${OUTPUT_PATH}")"

APP_BASENAME="$(basename "${APP_PATH}")"
BACKGROUND_BASENAME="background.png"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macactivity-dmg.XXXXXX")"
STAGING_DIR="${WORK_DIR}/staging"
mkdir -p "${STAGING_DIR}"
ditto "${APP_PATH}" "${STAGING_DIR}/${APP_BASENAME}"
ditto "${BACKGROUND_PATH}" "${STAGING_DIR}/${BACKGROUND_BASENAME}"
create_applications_alias

rm -f "${OUTPUT_PATH}"
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "${OUTPUT_PATH}"

printf 'Created %s\n' "${OUTPUT_PATH}"
