#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
mkdir -p build/Checks
# Pure synthetic vectors only; no IOKit, Keychain, networking or app launch.
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -parse-as-library \
    ODict/Services/MacDeviceIdentifier.swift Tests/MacDeviceIdentifierChecks.swift \
    -o build/Checks/MacDeviceIdentifierChecks
build/Checks/MacDeviceIdentifierChecks
