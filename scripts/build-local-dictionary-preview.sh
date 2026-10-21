#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
preview_app="${ODICT_PREVIEW_APP:-$PWD/build/Checks/ODictLocalPreview.app}"
mkdir -p "$preview_app/Contents/MacOS"
cat > "$preview_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>ODictLocalPreview</string><key>CFBundleIdentifier</key><string>com.touchany.odict.local-preview</string><key>CFBundleName</key><string>ODictLocalPreview</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
xcrun swiftc -O -D ODICT_CHECKS -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -parse-as-library \
    ODict/Models/AIModels.swift ODict/Services/AISettingsStore.swift ODict/Services/AIClient.swift ODict/Services/AIStreamTransport.swift ODict/Services/AIStreamDecoder.swift ODict/Features/AI/AIQueryModel.swift ODict/Features/AI/AITextInput.swift ODict/Features/AI/AIComposerView.swift ODict/Features/AI/AIResultView.swift ODict/Features/AI/AIMarkdownView.swift \
    ODict/Models/DictionaryModels.swift ODict/LocalDictionary/*.swift \
    ODict/Services/DictionaryClient.swift ODict/Services/KeychainStore.swift ODict/Services/BlockingWorkQueue.swift \
    ODict/Services/ServiceSettingsStore.swift ODict/Services/HTTPTransport.swift ODict/Services/RequestRateLimit.swift \
    ODict/Services/RecentWordsStore.swift ODict/Services/PronunciationService.swift \
    ODict/Features/Lookup/LookupModel.swift ODict/Features/Lookup/LookupView.swift ODict/Features/Lookup/CandidateSearchField.swift \
    ODict/Features/LocalDictionary/*.swift Tests/LocalDictionaryPreviewApp.swift -lz \
    -o "$preview_app/Contents/MacOS/ODictLocalPreview"
codesign --force --sign "Apple Development" --options runtime "$preview_app"
printf '%s\n' "$preview_app"
