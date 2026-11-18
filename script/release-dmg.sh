#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?Usage: release-dmg.sh <version> <output-directory>}"
output="${2:?Provide an output directory}"
identity="${SIPAWAKE_SIGN_IDENTITY:?Set SIPAWAKE_SIGN_IDENTITY to a Developer ID Application identity}"
profile="${SIPAWAKE_NOTARY_PROFILE:?Set SIPAWAKE_NOTARY_PROFILE to a notarytool keychain profile}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Provide a numeric version such as 0.2.0." >&2
    exit 1
fi

mkdir -p "$output"
output="$(cd "$output" && pwd)"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
"$project/script/bundle.sh" "$staging" "$version" release
app="$staging/SipAwake.app"
dmg="$output/SipAwake-$version.dmg"
ln -s /Applications "$staging/Applications"
chmod 755 "$staging"
codesign --force --sign "$identity" --identifier com.fujiwarachoki.sipawake.cli --options runtime --timestamp "$app/Contents/Helpers/sipawake"
codesign --force --sign "$identity" --options runtime --timestamp "$app"
codesign --verify --deep --strict -v "$app"
hdiutil create -srcfolder "$staging" -volname SipAwake -format UDZO -ov "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict -v "$dmg"
shasum -a 256 "$dmg"
