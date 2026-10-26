#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -parse-as-library \
    ODict/Models/AIHistoryModels.swift ODict/Services/AIHistoryStore.swift ODict/Features/AI/AIHistoryModel.swift \
    ODict/Models/DictionaryModels.swift ODict/Models/AIModels.swift \
    ODict/Services/BlockingWorkQueue.swift ODict/Services/KeychainStore.swift \
    ODict/Services/ServiceSettingsStore.swift ODict/Services/HTTPTransport.swift \
    ODict/Services/AISettingsStore.swift ODict/Services/AIClient.swift ODict/Services/AIStreamTransport.swift ODict/Services/AIStreamDecoder.swift \
    ODict/Services/DictionaryClient.swift ODict/Services/RequestRateLimit.swift \
    ODict/Services/RecentWordsStore.swift ODict/Models/PronunciationSource.swift ODict/Services/PronunciationSettingsStore.swift ODict/Services/PronunciationService.swift \
    ODict/LocalDictionary/*.swift ODict/Features/AI/AIQueryModel.swift \
    ODict/Services/LookupResultCache.swift ODict/Features/Lookup/LookupModel.swift Tests/AIHistoryChecks.swift -lz -o build/Checks/AIHistoryChecks
build/Checks/AIHistoryChecks
