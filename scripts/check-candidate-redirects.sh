#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
xcrun swiftc -O -D ODICT_CHECKS -swift-version 5 -parse-as-library \
    ODict/Models/AIModels.swift ODict/Services/AISettingsStore.swift ODict/Services/AIClient.swift ODict/Services/AIStreamTransport.swift ODict/Services/AIStreamDecoder.swift ODict/Features/AI/AIQueryModel.swift \
    ODict/Models/DictionaryModels.swift ODict/LocalDictionary/*.swift \
    ODict/Services/DictionaryClient.swift ODict/Services/KeychainStore.swift ODict/Services/BlockingWorkQueue.swift \
    ODict/Services/ServiceSettingsStore.swift ODict/Services/HTTPTransport.swift ODict/Services/RequestRateLimit.swift \
    ODict/Services/RecentWordsStore.swift ODict/Services/PronunciationService.swift \
    ODict/Services/LookupResultCache.swift ODict/Features/Lookup/LookupModel.swift Tests/CandidateRedirectChecks.swift -lz -o build/Checks/CandidateRedirectChecks
build/Checks/CandidateRedirectChecks "$@"
