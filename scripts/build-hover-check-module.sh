#!/bin/sh
# Compile the reusable module for the existing local checks; does not run checks.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/Checks
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -sdk "$sdk_path" -target "$(uname -m)-apple-macosx12.0" \
    -parse-as-library -emit-library -emit-module -module-name HoverLookupKit \
    Packages/HoverLookupKit/Sources/HoverLookupKit/*.swift \
    -emit-module-path build/Checks/HoverLookupKit.swiftmodule \
    -o build/Checks/libHoverLookupKit.dylib
