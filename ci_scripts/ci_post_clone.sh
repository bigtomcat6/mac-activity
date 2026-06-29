#!/bin/sh
set -eu

echo "CI_WORKFLOW=${CI_WORKFLOW:-}"
echo "CI_WORKFLOW_ID=${CI_WORKFLOW_ID:-}"
echo "CI_START_CONDITION=${CI_START_CONDITION:-}"
echo "CI_BRANCH=${CI_BRANCH:-}"
echo "CI_COMMIT=${CI_COMMIT:-}"
echo "CI_XCODE_PROJECT=${CI_XCODE_PROJECT:-}"
echo "CI_XCODE_SCHEME=${CI_XCODE_SCHEME:-}"
echo "CI_XCODEBUILD_ACTION=${CI_XCODEBUILD_ACTION:-}"

sw_vers
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
swift --version
