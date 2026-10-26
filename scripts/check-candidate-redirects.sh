#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# This integration check needs an explicitly selected, legally held dictionary.
if [ "$#" -ne 1 ]; then
    echo "Usage: sh scripts/check-candidate-redirects.sh /path/to/dictionaries" >&2
    exit 64
fi
if [ ! -d "$1" ]; then
    echo "The dictionary root must be an existing directory." >&2
    exit 1
fi

mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
xcrun swiftc -O -D ODICT_CHECKS -swift-version 5 -parse-as-library \
    ODict/Models/AIHistoryModels.swift ODict/Services/AIHistoryStore.swift ODict/Features/AI/AIHistoryModel.swift \
    ODict/Models/AIModels.swift ODict/Services/AISettingsStore.swift ODict/Services/AIClient.swift ODict/Services/AIStreamTransport.swift ODict/Services/AIStreamDecoder.swift ODict/Features/AI/AIQueryModel.swift \
    ODict/Models/DictionaryModels.swift ODict/LocalDictionary/*.swift \
    ODict/Services/DictionaryClient.swift ODict/Services/KeychainStore.swift ODict/Services/BlockingWorkQueue.swift \
    ODict/Services/ServiceSettingsStore.swift ODict/Services/HTTPTransport.swift ODict/Services/RequestRateLimit.swift \
    ODict/Services/RecentWordsStore.swift ODict/Models/PronunciationSource.swift ODict/Services/PronunciationSettingsStore.swift ODict/Services/SystemSpeechVoice.swift ODict/Services/PronunciationService.swift \
    ODict/Services/LookupResultCache.swift ODict/Features/Lookup/LookupModel.swift Tests/CandidateRedirectChecks.swift -lz -o build/Checks/CandidateRedirectChecks
build/Checks/CandidateRedirectChecks "$@"
