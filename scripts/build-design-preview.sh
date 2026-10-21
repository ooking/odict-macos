#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
preview_app="$PWD/build/Checks/ODictResizePreview.app"
mkdir -p "$preview_app/Contents/MacOS"
cat > "$preview_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>ODictResizePreview</string><key>CFBundleIdentifier</key><string>com.touchany.odict.resize-preview</string><key>CFBundleName</key><string>ODictResizePreview</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
# Reuse the production typography without the @main application or real app coordinator.
python3 - <<'PY'
from pathlib import Path
source = Path('ODict/App/ODictApp.swift').read_text()
Path('build/Checks/PreviewTypography.swift').write_text('import SwiftUI\nimport AppKit\n' + source[source.index('// Shared native typography'):])
PY
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -parse-as-library \
    ODict/Models/*.swift ODict/Services/*.swift ODict/LocalDictionary/*.swift \
    ODict/Features/Lookup/*.swift ODict/Features/AI/*.swift ODict/Features/LocalDictionary/*.swift \
    ODict/Features/Capture/CaptureSupport.swift ODict/App/MenuBarController.swift ODict/App/LifecycleDiagnostics.swift \
    build/Checks/PreviewTypography.swift Tests/DesignPreviewApp.swift -lz \
    -o "$preview_app/Contents/MacOS/ODictResizePreview"
codesign --force --sign "Apple Development" --options runtime "$preview_app"
printf '%s\n' "$preview_app"
