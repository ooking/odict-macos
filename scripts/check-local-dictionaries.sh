#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
xcrun swiftc -O -D ODICT_CHECKS -swift-version 5 -parse-as-library \
    ODict/Services/BlockingWorkQueue.swift \
    ODict/Models/DictionaryModels.swift ODict/Models/TranslationMethod.swift ODict/LocalDictionary/*.swift \
    Tests/LocalArticleDocumentChecks.swift Tests/LocalDictionaryChecks.swift -lz -o build/Checks/LocalDictionaryChecks
build/Checks/LocalDictionaryChecks "$@"
