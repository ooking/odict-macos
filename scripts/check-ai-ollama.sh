#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
# Explicit opt-in script: localhost only, fixed local model, no saved credentials.
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -parse-as-library \
    ODict/Models/DictionaryModels.swift ODict/Models/AIModels.swift \
    ODict/Services/BlockingWorkQueue.swift ODict/Services/KeychainStore.swift \
    ODict/Services/ServiceSettingsStore.swift ODict/Services/HTTPTransport.swift \
    ODict/Services/AISettingsStore.swift ODict/Services/AIClient.swift ODict/Services/AIStreamTransport.swift ODict/Services/AIStreamDecoder.swift \
    Tests/OllamaAIChecks.swift -o build/Checks/OllamaAIChecks
build/Checks/OllamaAIChecks
