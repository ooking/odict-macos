#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -sdk "$sdk_path" -parse-as-library \
    ODict/Models/DictionaryModels.swift ODict/Services/DictionaryClient.swift \
    ODict/Services/KeychainStore.swift ODict/Services/BlockingWorkQueue.swift \
    ODict/Services/ServiceSettingsStore.swift ODict/Services/HTTPTransport.swift \
    ODict/Services/RequestRateLimit.swift ODict/Services/RecentWordsStore.swift \
    ODict/Services/PronunciationService.swift ODict/Features/Lookup/LookupModel.swift \
    ODict/LocalDictionary/MDXBinary.swift ODict/LocalDictionary/MDXReader.swift \
    ODict/LocalDictionary/LocalDictionaryStore.swift ODict/LocalDictionary/LocalDictionaryLibrary.swift \
    ODict/LocalDictionary/DictionaryRouter.swift -lz \
    Tests/LookupModelChecks.swift -o build/Checks/LookupModelChecks
build/Checks/LookupModelChecks
