#!/bin/bash
# Builds an ad-hoc signed IPA with Xcode (the repo's normal xtool flow only does development installs).
#
#   xcode/build-adhoc.sh [path/to/profile.mobileprovision]
#
# Needs the "Apple Distribution: Cloud Gravity, Ltd. (4X776PJ9B2)" certificate with its private key
# in the keychain. Output: xcode/build/ipa/YTadless.ipa
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${1:-../adhoc-youtube-without-ads.mobileprovision}"
TEAM_ID=4X776PJ9B2

if ! security find-identity -v -p codesigning | grep -q "Apple Distribution: .*($TEAM_ID)"; then
    echo "error: no valid 'Apple Distribution' identity for team $TEAM_ID in the keychain." >&2
    echo "       Import the certificate's .p12 (certificate + private key) and re-run." >&2
    exit 1
fi

# Xcode finds manual-signing profiles by name in this directory, stored as <UUID>.mobileprovision.
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
UUID=$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -extract UUID raw -)
mkdir -p "$PROFILE_DIR"
cp "$PROFILE" "$PROFILE_DIR/$UUID.mobileprovision"

rm -rf build/YTadless.xcarchive build/ipa
xcodebuild archive \
    -project YTadless.xcodeproj \
    -scheme YTadlessApp \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath DerivedData \
    -archivePath build/YTadless.xcarchive

xcodebuild -exportArchive \
    -archivePath build/YTadless.xcarchive \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath build/ipa

echo
echo "IPA: $(pwd)/build/ipa/YTadless.ipa"
