#!/usr/bin/env bash
set -euo pipefail

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
BACKGROUND_DIR_NAME=".background"
DMG_HEADROOM_MEGABYTES=16

WORK_DIR=""
MOUNT_POINT=""

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

apply_finder_layout() {
  local volume_path="$1"

  /usr/bin/osascript - \
    "${volume_path}" \
    "${APP_BASENAME}" \
    "${APPLICATIONS_ALIAS_NAME}" \
    "${BACKGROUND_DIR_NAME}/${BACKGROUND_BASENAME}" \
    "${WINDOW_WIDTH}" \
    "${WINDOW_HEIGHT}" \
    "${ICON_SIZE}" \
    "${APP_X}" \
    "${APP_Y}" \
    "${APPLICATIONS_X}" \
    "${APPLICATIONS_Y}" >/dev/null <<'OSA'
on run argv
  set volumePath to item 1 of argv
  set appName to item 2 of argv
  set applicationsName to item 3 of argv
  set backgroundRelativePath to item 4 of argv
  set windowWidth to (item 5 of argv) as integer
  set windowHeight to (item 6 of argv) as integer
  set iconSize to (item 7 of argv) as integer
  set appX to (item 8 of argv) as integer
  set appY to (item 9 of argv) as integer
  set applicationsX to (item 10 of argv) as integer
  set applicationsY to (item 11 of argv) as integer
  set backgroundPath to POSIX file (volumePath & "/" & backgroundRelativePath) as alias
  set volumeFolder to POSIX file volumePath as alias

  tell application "Finder"
    tell folder volumeFolder
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {100, 100, 100 + windowWidth, 100 + windowHeight}
      set opts to icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to iconSize
      set background picture of opts to backgroundPath
      set position of item appName to {appX, appY}
      set position of item applicationsName to {applicationsX, applicationsY}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
OSA
}

detach_mount() {
  local mount_point="$1"

  for attempt in 1 2 3; do
    hdiutil detach "${mount_point}" >/dev/null 2>&1 && return 0
    sleep "${attempt}"
  done

  hdiutil detach "${mount_point}" -force >/dev/null
}

cleanup() {
  if [[ -n "${MOUNT_POINT}" && -d "${MOUNT_POINT}" ]]; then
    detach_mount "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi
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
RW_DMG_PATH="${WORK_DIR}/rw.dmg"
MOUNT_POINT="${WORK_DIR}/mount"
mkdir -p "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/${BACKGROUND_DIR_NAME}"
ditto "${APP_PATH}" "${STAGING_DIR}/${APP_BASENAME}"
ditto "${BACKGROUND_PATH}" "${STAGING_DIR}/${BACKGROUND_DIR_NAME}/${BACKGROUND_BASENAME}"
create_applications_alias
STAGING_SIZE_MEGABYTES="$(du -sm "${STAGING_DIR}" | awk '{print $1}')"
RW_DMG_SIZE_MEGABYTES="$((STAGING_SIZE_MEGABYTES + DMG_HEADROOM_MEGABYTES))"

rm -f "${OUTPUT_PATH}"
hdiutil create \
  -size "${RW_DMG_SIZE_MEGABYTES}m" \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "${RW_DMG_PATH}"

mkdir -p "${MOUNT_POINT}"
hdiutil attach -readwrite -nobrowse -mountpoint "${MOUNT_POINT}" "${RW_DMG_PATH}" >/dev/null
apply_finder_layout "${MOUNT_POINT}"
sync
detach_mount "${MOUNT_POINT}"
MOUNT_POINT=""

hdiutil convert \
  "${RW_DMG_PATH}" \
  -format UDZO \
  -o "${OUTPUT_PATH}" \
  -ov

printf 'Created %s\n' "${OUTPUT_PATH}"
