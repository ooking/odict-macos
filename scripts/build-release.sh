#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

# Pass the app's Release team to Swift Package targets as well.
signing_team="$(plutil -extract objects.00000000000000000000000E.buildSettings.DEVELOPMENT_TEAM \
    raw -o - ODict.xcodeproj/project.pbxproj)"
if [ -z "$signing_team" ]; then
    echo "Configure the Release development team in Xcode before building." >&2
    exit 1
fi

# Keep the project's development identity; never fall back to ad hoc signing.
xcodebuild -project ODict.xcodeproj -scheme ODict \
    -configuration Release -derivedDataPath build \
    -disableAutomaticPackageResolution \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$signing_team" build
