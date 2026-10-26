#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -sdk "$sdk_path" -parse-as-library \
    ODict/Models/AIHistoryModels.swift ODict/Services/AIHistoryStore.swift ODict/Features/AI/AIHistoryModel.swift \
    ODict/Models/AIModels.swift ODict/Services/AISettingsStore.swift ODict/Services/AIClient.swift ODict/Services/AIStreamTransport.swift ODict/Services/AIStreamDecoder.swift ODict/Features/AI/AIQueryModel.swift \
    ODict/Models/DictionaryModels.swift ODict/Services/DictionaryClient.swift \
    ODict/Services/KeychainStore.swift ODict/Services/BlockingWorkQueue.swift \
    ODict/Services/ODictService.swift ODict/Services/HTTPTransport.swift \
    ODict/Services/RequestRateLimit.swift ODict/Services/RecentWordsStore.swift \
    ODict/Models/PronunciationSource.swift ODict/Services/PronunciationSettingsStore.swift ODict/Services/SystemSpeechVoice.swift ODict/Services/PronunciationService.swift ODict/Services/LookupResultCache.swift ODict/Features/Lookup/LookupModel.swift \
    ODict/LocalDictionary/MDXBinary.swift ODict/LocalDictionary/MDXReader.swift \
    ODict/LocalDictionary/LocalDictionaryStore.swift ODict/LocalDictionary/LocalDictionaryLibrary.swift \
    ODict/LocalDictionary/LocalArticleSummary.swift ODict/LocalDictionary/LocalArticleDocument.swift \
    ODict/LocalDictionary/LocalDictionaryDebug.swift \
    ODict/LocalDictionary/DictionaryRouter.swift -lz \
    Tests/LookupModelChecks.swift -o build/Checks/LookupModelChecks
build/Checks/LookupModelChecks
