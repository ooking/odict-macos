#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
mkdir -p build/Checks
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -parse-as-library \
    ODict/Models/PronunciationSource.swift ODict/Services/PronunciationSettingsStore.swift \
    ODict/Services/PronunciationService.swift Tests/PronunciationChecks.swift \
    -o build/Checks/PronunciationChecks
build/Checks/PronunciationChecks
