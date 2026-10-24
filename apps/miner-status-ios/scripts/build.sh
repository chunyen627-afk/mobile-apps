#!/bin/bash
# Mac-only build: core tests, app compile, unsigned Release IPA.
# Written without access to a Mac and NOT yet executed. Requires Xcode 15+ and XcodeGen;
# this script installs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. JSON contract, only if jsonschema is already installed (a skip is not a pass).
if python3 -c 'import jsonschema' 2>/dev/null; then
  python3 -I tools/validate_contract.py
else
  echo 'jsonschema not installed: JSON contract check SKIPPED (not counted as passed).'
fi

# 2. Core package tests on the macOS host.
if [[ "${RUN_TESTS:-1}" == "1" ]]; then
  swift test
fi

# 3. Generate the Xcode project from App/project.yml.
(cd App && xcodegen generate)
mkdir -p build

# 4. Compile the app for the simulator, unsigned.
xcodebuild build -project App/MinerStatus.xcodeproj -scheme MinerStatus \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO

# 5. Release archive for devices with signing off.
xcodebuild archive -project App/MinerStatus.xcodeproj -scheme MinerStatus \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/MinerStatus.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''

APP=build/MinerStatus.xcarchive/Products/Applications/MinerStatus.app
PLIST="$APP/Info.plist"
test -f "$APP/MinerStatus"
test -s "$APP/demo-running.json"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' "$PLIST")" = true
if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$PLIST" >/dev/null 2>&1; then
  echo 'NSAllowsArbitraryLoads must not be set'
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$PLIST" >/dev/null 2>&1; then
  echo 'UIBackgroundModes must not be set: the app reads in the foreground only'
  exit 1
fi
echo "MinimumOSVersion: $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")"
echo "UIDeviceFamily: $(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily' "$PLIST" | tr -d '\n')"

# 6. Package an unsigned IPA.
rm -rf build/package
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/MinerStatus.app
(cd build/package && /usr/bin/zip -qr ../MinerStatus-unsigned.ipa Payload)
unzip -t build/MinerStatus-unsigned.ipa
echo 'Created build/MinerStatus-unsigned.ipa: sign with your own Apple account before installing.'
