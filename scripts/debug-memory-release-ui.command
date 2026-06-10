#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/clang-module-cache}" \
swift run \
  --quiet \
  --scratch-path "${MAC_ACTIVITY_DEBUG_MEMORY_UI_SCRATCH:-/private/tmp/macactivity-debug-memory-release-ui-build}" \
  DebugMemoryReleaseUI \
  "$@"
