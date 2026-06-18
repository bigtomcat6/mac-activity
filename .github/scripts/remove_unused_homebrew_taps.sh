#!/usr/bin/env bash
set -euo pipefail

cleanup_tap() {
  local tap="$1"

  if ! brew tap | grep -qx "${tap}"; then
    echo "Tap ${tap} is not installed. Skip."
    return
  fi

  echo "Cleaning tap: ${tap}"

  while IFS= read -r formula; do
    echo "Uninstalling formula from ${tap}: ${formula}"
    brew uninstall "${formula}" || true
  done < <(brew list --formula --full-name | grep "^${tap}/" || true)

  while IFS= read -r cask; do
    echo "Uninstalling cask from ${tap}: ${cask}"
    brew uninstall --cask "${cask}" || true
  done < <(brew list --cask --full-name | grep "^${tap}/" || true)

  brew untap --force "${tap}" || true
}

for tap in "$@"; do
  cleanup_tap "${tap}"
done
