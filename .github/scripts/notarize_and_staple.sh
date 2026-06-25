#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_PATH=""

usage() {
  cat <<'USAGE'
Usage: .github/scripts/notarize_and_staple.sh --path ARTIFACT

Notarizes a supported macOS distribution artifact with notarytool, staples the
result, and performs a Gatekeeper assessment when assessments are enabled.

Environment:
  APPLE_ID
  APPLE_APP_SPECIFIC_PASSWORD
  APPLE_TEAM_ID
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

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "${name} is required"
}

artifact_kind() {
  local path="$1"

  if [[ -d "${path}" && "${path}" == *.app ]]; then
    printf 'app\n'
  elif [[ -f "${path}" && "${path}" == *.dmg ]]; then
    printf 'dmg\n'
  elif [[ -f "${path}" && "${path}" == *.pkg ]]; then
    printf 'pkg\n'
  else
    die "unsupported artifact path: ${path}"
  fi
}

assessment_type_for_kind() {
  local kind="$1"

  case "${kind}" in
    app)
      printf 'execute\n'
      ;;
    dmg)
      printf 'open\n'
      ;;
    pkg)
      printf 'install\n'
      ;;
    *)
      die "unsupported artifact kind: ${kind}"
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      ARTIFACT_PATH="$2"
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

[[ -n "${ARTIFACT_PATH}" ]] || die "--path is required"
[[ -e "${ARTIFACT_PATH}" ]] || die "artifact not found: ${ARTIFACT_PATH}"

require_env APPLE_ID
require_env APPLE_APP_SPECIFIC_PASSWORD
require_env APPLE_TEAM_ID

artifact_path="$(cd "$(dirname "${ARTIFACT_PATH}")" && pwd)/$(basename "${ARTIFACT_PATH}")"
artifact_kind="$(artifact_kind "${artifact_path}")"
assessment_type="$(assessment_type_for_kind "${artifact_kind}")"
submission_dir=""
if [[ "${artifact_kind}" == "app" ]]; then
  submission_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/notary-app.XXXXXX")"
  submission_path="${submission_dir}/$(basename "${artifact_path}" .app).zip"
  ditto -c -k --keepParent "${artifact_path}" "${submission_path}"
else
  submission_path="${artifact_path}"
fi
submit_output="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/notary-submit.XXXXXX")"
log_output="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/notary-log.XXXXXX")"

trap 'if [[ -n "${submission_dir}" && -d "${submission_dir}" ]]; then rm -rf "${submission_dir}"; fi; rm -f "${submit_output}" "${log_output}"' EXIT

log "Submitting ${artifact_path} for notarization"
if ! xcrun notarytool submit "${submission_path}" \
  --apple-id "${APPLE_ID}" \
  --team-id "${APPLE_TEAM_ID}" \
  --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
  --wait \
  --output-format json | tee "${submit_output}"; then
  die "notarytool submit failed before returning a status for ${artifact_path}"
fi

notary_result="$(python3 - "${submit_output}" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("", end="")
    raise SystemExit(0)

status = ""
submission_id = ""
if isinstance(data, dict):
    status = data.get("status", "")
    submission_id = data.get("id", "")
print(status)
print(submission_id)
PY
)"
notary_status="$(printf '%s\n' "${notary_result}" | sed -n '1p')"
notary_submission_id="$(printf '%s\n' "${notary_result}" | sed -n '2p')"
log "Notary submission status: ${notary_status}"
log "Notary submission id: ${notary_submission_id}"

if [[ -n "${notary_submission_id}" ]]; then
  if ! xcrun notarytool log "${notary_submission_id}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --output-format json | tee "${log_output}"; then
    warn "Unable to fetch detailed notary log for ${notary_submission_id}"
  fi
fi

[[ "${notary_status}" == "Accepted" ]] || die "notarytool returned non-success status for ${artifact_path}: ${notary_status}"

log "Stapling ${artifact_path}"
xcrun stapler staple "${artifact_path}"
xcrun stapler validate "${artifact_path}"

spctl_status=""
if spctl_status="$(spctl --status 2>&1)"; then
  log "Running Gatekeeper assessment for ${artifact_path}"
  spctl --assess --type "${assessment_type}" -vv "${artifact_path}"
elif [[ "${spctl_status}" == *"disabled"* ]]; then
  warn "Gatekeeper assessments are disabled; skipping spctl assessment for ${artifact_path}"
else
  printf '%s\n' "${spctl_status}" >&2
  die "unable to determine Gatekeeper status"
fi
