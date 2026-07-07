#!/usr/bin/env bash
set -euo pipefail

XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.45.4}"
XCODEGEN_SHA256="${XCODEGEN_SHA256:-090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef}"
XCODEGEN_URL="${XCODEGEN_URL:-https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip}"

temp_root="${RUNNER_TEMP:-}"
if [[ -z "${temp_root}" ]]; then
  temp_root="$(mktemp -d)"
fi

work_dir="${temp_root}/xcodegen-${XCODEGEN_VERSION}"
archive_path="${work_dir}/xcodegen.zip"
install_dir="${work_dir}/install"

rm -rf "${work_dir}"
mkdir -p "${install_dir}"

curl --fail --location --silent --show-error "${XCODEGEN_URL}" --output "${archive_path}"

actual_sha256="$(shasum -a 256 "${archive_path}" | awk '{ print $1 }')"
if [[ "${actual_sha256}" != "${XCODEGEN_SHA256}" ]]; then
  echo "::error::XcodeGen checksum mismatch. Expected ${XCODEGEN_SHA256}, got ${actual_sha256}."
  exit 1
fi

ditto -x -k "${archive_path}" "${install_dir}"

xcodegen_bin_dir="${install_dir}/xcodegen/bin"
xcodegen_bin="${xcodegen_bin_dir}/xcodegen"
if [[ ! -x "${xcodegen_bin}" ]]; then
  echo "::error::Downloaded XcodeGen archive did not contain xcodegen/bin/xcodegen."
  exit 1
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${xcodegen_bin_dir}" >> "${GITHUB_PATH}"
fi

export PATH="${xcodegen_bin_dir}:${PATH}"
xcodegen --version
