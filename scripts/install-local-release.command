#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Mac Activity"
BUNDLE_ID="com.how.macactivity"
PROJECT="MacActivity.xcodeproj"
SCHEME="MacActivity"
CONFIGURATION="Release"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DERIVED_DATA="${MAC_ACTIVITY_DERIVED_DATA:-${REPO_ROOT}/.build/LocalRelease}"
INSTALL_DIR="${MAC_ACTIVITY_INSTALL_DIR:-/Applications}"
SIGNING_MODE="${MAC_ACTIVITY_SIGNING:-local}"
ARCH="${MAC_ACTIVITY_ARCH:-$(uname -m)}"

BUILD_ONLY=false
SKIP_LAUNCH=false
SKIP_QUIT=false
STAGING_DIR=""

usage() {
  cat <<'USAGE'
Usage: scripts/install-local-release.command [options]

Builds Mac Activity in Release configuration and installs it locally.

Options:
  --build-only       Build and validate the Release app without installing it.
  --skip-launch      Install without launching the app afterward.
  --skip-quit        Install without asking a running app instance to quit.
  --local-signing    Sign to run locally. This is the default.
  --project-signing  Use the project signing settings instead of local signing.
  --developer-id-signing
                    Sign with a Developer ID Application certificate.
  -h, --help         Show this help text.

Environment:
  MAC_ACTIVITY_INSTALL_DIR   Install directory. Defaults to /Applications.
  MAC_ACTIVITY_DERIVED_DATA  DerivedData path. Defaults to .build/LocalRelease.
  MAC_ACTIVITY_SIGNING       local or project. Defaults to local.
  MAC_ACTIVITY_ARCH          Build architecture. Defaults to current machine arch.
USAGE
}

log() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup_staging_dir() {
  if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
    rm -rf "${STAGING_DIR}"
  fi
}

trap cleanup_staging_dir EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)
      BUILD_ONLY=true
      ;;
    --skip-launch)
      SKIP_LAUNCH=true
      ;;
    --skip-quit)
      SKIP_QUIT=true
      ;;
    --local-signing)
      SIGNING_MODE="local"
      ;;
    --project-signing)
      SIGNING_MODE="project"
      ;;
    --developer-id-signing)
      SIGNING_MODE="developer-id"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

case "${SIGNING_MODE}" in
  local|adhoc|ad-hoc)
    SIGNING_MODE="local"
    ;;
  project)
    ;;
  developer-id)
    if [[ -z "${MAC_ACTIVITY_DEVELOPMENT_TEAM:-}" ]]; then
      die "MAC_ACTIVITY_DEVELOPMENT_TEAM is required for Developer ID signing"
    fi
    ;;
  *)
    die "MAC_ACTIVITY_SIGNING must be 'local', 'project', or 'developer-id', got '${SIGNING_MODE}'"
    ;;
esac

cd "${REPO_ROOT}"

BUILT_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
DEST_APP="${INSTALL_DIR%/}/${APP_NAME}.app"

if [[ ! -d "${PROJECT}" ]]; then
  die "expected ${PROJECT} in ${REPO_ROOT}; run this script from the mac-activity checkout"
fi

bundle_identifier() {
  local app_path="$1"
  /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "${app_path}/Contents/Info.plist" 2>/dev/null
}

validate_app() {
  local app_path="$1"

  [[ -d "${app_path}" ]] || die "app bundle not found: ${app_path}"
  [[ -f "${app_path}/Contents/Info.plist" ]] || die "Info.plist not found in ${app_path}"
  [[ -x "${app_path}/Contents/MacOS/${APP_NAME}" ]] || die "executable not found in ${app_path}"

  local actual_bundle_id
  actual_bundle_id="$(bundle_identifier "${app_path}")" || die "could not read bundle identifier from ${app_path}"
  [[ "${actual_bundle_id}" == "${BUNDLE_ID}" ]] || die "unexpected bundle id '${actual_bundle_id}' in ${app_path}"

  /usr/bin/codesign --verify --deep --verbose=2 "${app_path}"
}

run_or_sudo() {
  local description="$1"
  shift

  if "$@"; then
    return 0
  fi

  warn "${description} failed; retrying with sudo"
  sudo "$@"
}

build_release_app() {
  local build_args=(
    xcodebuild
    -project "${PROJECT}"
    -scheme "${SCHEME}"
    -configuration "${CONFIGURATION}"
    -destination "platform=macOS,arch=${ARCH}"
    -derivedDataPath "${DERIVED_DATA}"
  )

  if [[ "${SIGNING_MODE}" == "local" ]]; then
    build_args+=(
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY=-
      DEVELOPMENT_TEAM=
    )
  elif [[ "${SIGNING_MODE}" == "developer-id" ]]; then
    build_args+=(
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY="${MAC_ACTIVITY_DEVELOPER_ID_IDENTITY:-Developer ID Application}"
      DEVELOPMENT_TEAM="${MAC_ACTIVITY_DEVELOPMENT_TEAM}"
      ENABLE_HARDENED_RUNTIME=YES
    )
  fi

  build_args+=(build)

  log "Building ${SCHEME} (${CONFIGURATION}, ${ARCH}, signing=${SIGNING_MODE})"
  "${build_args[@]}"
}

quit_running_app() {
  if [[ "${SKIP_QUIT}" == true ]]; then
    log "Skipping running app shutdown"
    return
  fi

  log "Quitting running ${APP_NAME} instance if present"
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  sleep 1

  if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    warn "${APP_NAME} is still running; sending terminate signal"
    pkill -x "${APP_NAME}" || true
    sleep 1
  fi
}

ensure_safe_destination() {
  case "${DEST_APP}" in
    */"${APP_NAME}.app")
      ;;
    *)
      die "refusing to install to unexpected destination: ${DEST_APP}"
      ;;
  esac

  if [[ -e "${DEST_APP}" && ! -d "${DEST_APP}" ]]; then
    die "destination exists but is not an app directory: ${DEST_APP}"
  fi

  if [[ -d "${DEST_APP}" ]]; then
    if [[ ! -f "${DEST_APP}/Contents/Info.plist" ]]; then
      die "destination app has no Info.plist; refusing to remove it: ${DEST_APP}"
    fi

    local existing_bundle_id
    existing_bundle_id="$(bundle_identifier "${DEST_APP}")" || die "could not read bundle identifier from existing ${DEST_APP}"
    [[ "${existing_bundle_id}" == "${BUNDLE_ID}" ]] || die "existing app bundle id '${existing_bundle_id}' does not match ${BUNDLE_ID}"
  fi
}

install_app() {
  ensure_safe_destination

  STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macactivity-install.XXXXXX")"
  local staged_app="${STAGING_DIR}/${APP_NAME}.app"

  log "Preparing staged app copy"
  ditto "${BUILT_APP}" "${staged_app}"
  validate_app "${staged_app}"

  log "Installing to ${DEST_APP}"
  run_or_sudo "creating install directory" mkdir -p "${INSTALL_DIR}"

  if [[ -d "${DEST_APP}" ]]; then
    run_or_sudo "removing existing app" rm -rf "${DEST_APP}"
  fi

  run_or_sudo "copying app into place" ditto "${staged_app}" "${DEST_APP}"
  validate_app "${DEST_APP}"
}

launch_app() {
  if [[ "${SKIP_LAUNCH}" == true ]]; then
    log "Skipping launch"
    return
  fi

  log "Launching ${DEST_APP}"
  open "${DEST_APP}"
}

build_release_app
validate_app "${BUILT_APP}"

if [[ "${BUILD_ONLY}" == true ]]; then
  log "Build-only verification complete: ${BUILT_APP}"
  exit 0
fi

quit_running_app
install_app
launch_app

log "Installed ${APP_NAME} from ${BUILT_APP}"
