#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -sdk "$sdk_path" -parse-as-library \
    ODict/Models/DictionaryModels.swift ODict/Services/DictionaryClient.swift \
    ODict/Services/KeychainStore.swift ODict/Features/Lookup/LookupModel.swift \
    Tests/LookupModelChecks.swift -o build/Checks/LookupModelChecks
build/Checks/LookupModelChecks
