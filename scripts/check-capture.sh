#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -sdk "$sdk_path" -target "$(uname -m)-apple-macosx12.0" -parse-as-library \
    ODict/Models/AIModels.swift \
    ODict/Features/Capture/CaptureSupport.swift \
    ODict/Features/Capture/ScreenSelectionController.swift \
    ODict/Features/Capture/CaptureCoordinator.swift \
    ODict/Services/BlockingWorkQueue.swift \
    ODict/Services/SelectedTextService.swift ODict/Services/ScreenTextService.swift \
    ODict/Services/LegacyPreferencesMigration.swift \
    Tests/ScreenCaptureChecks.swift -o build/Checks/ScreenCaptureChecks
build/Checks/ScreenCaptureChecks
