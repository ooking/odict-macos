#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
mkdir -p build/Checks
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -parse-as-library \
    ODict/Models/AIModels.swift ODict/Models/DictionaryModels.swift \
    ODict/Services/AIClient.swift ODict/Services/AISettingsStore.swift \
    ODict/Services/KeychainStore.swift ODict/Services/BlockingWorkQueue.swift \
    ODict/Services/ServiceSettingsStore.swift ODict/Services/HTTPTransport.swift \
    ODict/Features/AI/AISettingsModel.swift Tests/AISettingsChecks.swift \
    -o build/Checks/AISettingsChecks
build/Checks/AISettingsChecks
