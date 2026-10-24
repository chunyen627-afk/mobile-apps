#!/bin/bash
# Mac-only build: core tests, app compile, optional simulator launch smoke, unsigned Release IPA.
# Written without access to a Mac and NOT yet executed. Requires Xcode 15+ and XcodeGen;
# this script installs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
EXPECTED_TESTS="${EXPECTED_TESTS:-80}"
BUNDLE_ID=org.personal.minerstatus.app
mkdir -p build

# 1. JSON contract, only if jsonschema is already installed (a skip is not a pass).
if python3 -c 'import jsonschema' 2>/dev/null; then
  python3 -I tools/validate_contract.py
else
  echo 'jsonschema not installed: JSON contract check SKIPPED (not counted as passed).'
fi

# 2. Core package tests on the macOS host. Fail unless exactly the expected number ran,
#    so missing or skipped tests can never be reported as a pass.
if [[ "${RUN_TESTS:-1}" == "1" ]]; then
  swift test 2>&1 | tee build/swift-test.log
  if ! grep -Eq "Executed ${EXPECTED_TESTS} tests?, with 0 failures" build/swift-test.log; then
    echo "Expected ${EXPECTED_TESTS} executed XCTest methods with 0 failures; see build/swift-test.log."
    exit 1
  fi
fi

# 3. Generate the Xcode project from App/project.yml.
(cd App && xcodegen generate)

# 4. Compile the app for an available iPhone simulator, unsigned.
SIMULATOR_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); m=[x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x.get("isAvailable") and "iPhone" in x["name"]]; print(m[0] if m else "")')
if [[ -z "$SIMULATOR_ID" ]]; then
  echo 'No iPhone simulator available; refusing to continue.'
  exit 1
fi
xcodebuild build -project App/MinerStatus.xcodeproj -scheme MinerStatus \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO

# 5. Optional launch smoke: install, launch the offline demo, confirm it is still running,
#    save a screenshot. This is not a UI test suite; screens still need human review.
if [[ "${RUN_SIM_SMOKE:-0}" == "1" ]]; then
  SIM_APP=build/DerivedData/Build/Products/Debug-iphonesimulator/MinerStatus.app
  mkdir -p build/screenshots
  xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
  xcrun simctl bootstatus "$SIMULATOR_ID" -b
  xcrun simctl install "$SIMULATOR_ID" "$SIM_APP"
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID"
  sleep 8
  xcrun simctl io "$SIMULATOR_ID" screenshot --type=jpeg build/screenshots/launch-demo.jpg
  if ! xcrun simctl spawn "$SIMULATOR_ID" launchctl list | grep -q "$BUNDLE_ID"; then
    echo 'App is not running 8 seconds after launch.'
    exit 1
  fi
  xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" || true
fi

# 6. Release archive for devices with signing off.
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

# 7. Package an unsigned IPA and record its SHA256.
rm -rf build/package
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/MinerStatus.app
(cd build/package && /usr/bin/zip -qr ../MinerStatus-unsigned.ipa Payload)
unzip -t build/MinerStatus-unsigned.ipa
(cd build && shasum -a 256 MinerStatus-unsigned.ipa | tee MinerStatus-unsigned.ipa.sha256)
echo 'Created build/MinerStatus-unsigned.ipa: sign with your own Apple account before installing.'
