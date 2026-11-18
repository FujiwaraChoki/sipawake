#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project"
destination="${1:?Provide a directory for SipAwake.app}"
version="${2:-0.2.0}"
mode="${3:-development}"
app="$destination/SipAwake.app"

if [[ "$mode" == release ]]; then
    swift build -c release --arch arm64 --arch x86_64 >&2
    binaries="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build >&2
    binaries="$(swift build --show-bin-path)"
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
install -m 755 "$binaries/SipAwakeMenu" "$app/Contents/MacOS/SipAwakeMenu"
install -m 755 "$binaries/sipawake" "$app/Contents/Helpers/sipawake"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>SipAwakeMenu</string>
    <key>CFBundleIdentifier</key><string>com.fujiwarachoki.sipawake</string>
    <key>CFBundleName</key><string>SipAwake</string>
    <key>CFBundleDisplayName</key><string>SipAwake</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >&2
