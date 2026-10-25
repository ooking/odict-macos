#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

if [ -z "${DEVELOPMENT_TEAM:-}" ] && [ ! -f Config/Signing.local.xcconfig ]; then
    echo "Copy Config/Signing.local.example.xcconfig to Config/Signing.local.xcconfig and set your Team ID, or pass DEVELOPMENT_TEAM. See docs/building.md." >&2
    exit 1
fi

# Apply the same team to the app and Swift Package targets. Xcode also reads
# this file as the app's base configuration, so GUI and scripted builds agree.
set -- -project ODict.xcodeproj -scheme ODict \
    -configuration Release -derivedDataPath build \
    -xcconfig Config/Signing.xcconfig \
    -disableAutomaticPackageResolution \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="Apple Development"

# Command-line settings take priority over the optional local configuration.
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    set -- "$@" "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
fi

# Never fall back to ad hoc signing or disable code signing.
xcodebuild "$@" build
