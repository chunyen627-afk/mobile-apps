#!/bin/bash
# Mac-only build, same flow as apps/album-ios: XcodeGen, unit tests on an iOS simulator,
# optional launch smoke, unsigned Release IPA. Requires Xcode 15+ and XcodeGen;
# this script installs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
EXPECTED_TESTS="${EXPECTED_TESTS:-80}"
BUNDLE_ID=org.personal.minerstatus.app
mkdir -p build

# In GitHub Actions, report the failing phase and its errors as annotations, which the
# public API can read without signing in.
PHASE=setup
CURRENT_LOG=""
escape_annotation() { tr -d '\r' | sed 's/%/%25/g' | awk 'BEGIN { ORS = "%0A" } { print }'; }
annotate_failure() {
  local code=$?
  [[ $code -ne 0 && -n "${GITHUB_ACTIONS:-}" ]] || return 0
  echo "::error title=build.sh failed::phase ${PHASE} exited with ${code}"
  if [[ -n "$CURRENT_LOG" && -f "$CURRENT_LOG" ]]; then
    { grep -E '(error|fatal error):' "$CURRENT_LOG" || true; } | sort -u | head -n 8 | while IFS= read -r line; do
      echo "::error title=${PHASE}::$(printf '%s\n' "$line" | escape_annotation)"
    done
    echo "::error title=${PHASE} log tail::$(tail -n 40 "$CURRENT_LOG" | escape_annotation)"
  fi
}
trap annotate_failure EXIT

# 1. JSON contract, only if jsonschema is already installed (a skip is not a pass).
PHASE=contract
if python3 -c 'import jsonschema' 2>/dev/null; then
  python3 -I tools/validate_contract.py
else
  echo 'jsonschema not installed: JSON contract check SKIPPED (not counted as passed).'
fi

# 2. Generate the Xcode project from project.yml.
PHASE=xcodegen
CURRENT_LOG=build/xcodegen.log
xcodegen generate 2>&1 | tee "$CURRENT_LOG"

# 3. Unit tests on an available iPhone simulator. Fail unless exactly the expected number
#    ran with 0 failures, so missing or skipped tests can never be reported as a pass.
SIMULATOR_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); m=[x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x.get("isAvailable") and "iPhone" in x["name"]]; print(m[0] if m else "")')
if [[ -z "$SIMULATOR_ID" ]]; then
  echo 'No iPhone simulator available; refusing to continue.'
  exit 1
fi
if [[ "${RUN_TESTS:-1}" == "1" ]]; then
  PHASE=test
  CURRENT_LOG=build/xcodebuild-test.log
  rm -rf build/Tests.xcresult
  xcodebuild test -project MinerStatus.xcodeproj -scheme MinerStatus \
    -parallel-testing-enabled NO \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath build/DerivedData \
    -resultBundlePath build/Tests.xcresult CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$CURRENT_LOG"
  grep -E "^Test Case .*(passed|failed)|Executed [0-9]+ tests?|\*\* TEST" "$CURRENT_LOG" > build/test-summary.txt || true
  if ! grep -Eq "Executed ${EXPECTED_TESTS} tests?, with 0 failures" "$CURRENT_LOG"; then
    echo "Expected ${EXPECTED_TESTS} executed XCTest methods with 0 failures; see build/test-summary.txt."
    exit 1
  fi
else
  PHASE=simulator-build
  CURRENT_LOG=build/xcodebuild-sim.log
  xcodebuild build -project MinerStatus.xcodeproj -scheme MinerStatus \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$CURRENT_LOG"
fi

# 4. Optional launch smoke: install, launch the offline demo, confirm it is still running,
#    save a screenshot. This is not a UI test suite; screens still need human review.
if [[ "${RUN_SIM_SMOKE:-0}" == "1" ]]; then
  PHASE=launch-smoke
  CURRENT_LOG=""
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

# 5. Release archive for devices with signing off.
PHASE=archive
CURRENT_LOG=build/xcodebuild-archive.log
xcodebuild archive -project MinerStatus.xcodeproj -scheme MinerStatus \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/MinerStatus.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tee "$CURRENT_LOG"

# 6. Check the device bundle explicitly.
PHASE=bundle-checks
CURRENT_LOG=""
APP=build/MinerStatus.xcarchive/Products/Applications/MinerStatus.app
PLIST="$APP/Info.plist"
test -f "$APP/MinerStatus"
test -s "$APP/demo-running.json"
test -s "$APP/Frameworks/MinerStatusCore.framework/MinerStatusCore"
otool -L "$APP/MinerStatus" | grep -F '@rpath/MinerStatusCore.framework/MinerStatusCore'
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
PHASE=package
rm -rf build/package
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/MinerStatus.app
(cd build/package && /usr/bin/zip -qr ../MinerStatus-unsigned.ipa Payload)
unzip -t build/MinerStatus-unsigned.ipa
(cd build && shasum -a 256 MinerStatus-unsigned.ipa | tee MinerStatus-unsigned.ipa.sha256)
echo 'Created build/MinerStatus-unsigned.ipa: sign with your own Apple account before installing.'
