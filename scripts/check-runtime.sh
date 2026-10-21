#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -sdk "$sdk_path" -parse-as-library \
    ODict/Models/AIModels.swift ODict/Services/AISettingsStore.swift ODict/Services/AIClient.swift ODict/Services/AIStreamTransport.swift ODict/Services/AIStreamDecoder.swift ODict/Features/AI/AISettingsModel.swift \
    ODict/Models/DictionaryModels.swift ODict/Services/BlockingWorkQueue.swift \
    ODict/Services/KeychainStore.swift ODict/Services/ServiceSettingsStore.swift \
    ODict/Services/HTTPTransport.swift ODict/Services/DictionaryClient.swift \
    ODict/Services/RequestRateLimit.swift ODict/Services/RecentWordsStore.swift \
    ODict/Features/Settings/SettingsModel.swift Tests/RuntimeServiceChecks.swift \
    -o build/Checks/RuntimeServiceChecks
build/Checks/RuntimeServiceChecks
