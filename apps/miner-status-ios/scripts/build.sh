#!/bin/bash
# Mac-only build, same flow as apps/album-ios: XcodeGen, unit tests on an iOS simulator,
# optional launch smoke, unsigned Release IPA. Requires Xcode 15+ and XcodeGen;
# this script installs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
EXPECTED_TESTS="${EXPECTED_TESTS:-86}"
EXPECTED_UI_TESTS="${EXPECTED_UI_TESTS:-11}"
# Local feed for the custom-source UI tests: fixtures served on the build Mac's loopback, plus a
# port nothing listens on for the failure case. The simulator shares the Mac's network.
UI_FEED_PORT="${UI_FEED_PORT:-8765}"
UI_FAILING_PORT="${UI_FAILING_PORT:-8799}"
BUNDLE_ID=org.personal.minerstatus.app
mkdir -p build

# In GitHub Actions, report the failing phase and its errors as annotations, which the
# public API can read without signing in.
PHASE=setup
CURRENT_LOG=""
escape_annotation() { tr -d '\r' | sed 's/%/%25/g' | awk 'BEGIN { ORS = "%0A" } { print }'; }
annotate_failure() {
  local code=$1
  [[ $code -ne 0 && -n "${GITHUB_ACTIONS:-}" ]] || return 0
  echo "::error title=build.sh failed::phase ${PHASE} exited with ${code}"
  if [[ -n "$CURRENT_LOG" && -f "$CURRENT_LOG" ]]; then
    # Which test methods failed and how many passed, before the individual error lines.
    local failed passed
    failed=$({ grep -E "^Test Case '.*' failed" "$CURRENT_LOG" || true; } | sed -E "s/^Test Case '-\[[^ ]+ ([^]]+)\]'.*/\1/" | sort -u | tr '\n' ' ')
    passed=$({ grep -E "^Test Case '.*' passed" "$CURRENT_LOG" || true; } | wc -l | tr -d ' ')
    if [[ -n "$failed" ]]; then echo "::error title=failed tests::${passed} passed; failed: ${failed}"; fi
    { grep -E '(error|fatal error):' "$CURRENT_LOG" || true; } | sort -u | head -n 6 | while IFS= read -r line; do
      echo "::error title=${PHASE}::$(printf '%s\n' "$line" | escape_annotation)"
    done
    echo "::error title=${PHASE} log tail::$(tail -n 40 "$CURRENT_LOG" | escape_annotation)"
  fi
}
# Screenshots from the UI tests, named after each test's attachment; also exported on failure.
export_screenshots() {
  [[ -d build/Tests.xcresult ]] || return 0
  rm -rf build/ui-attachments build/screenshots-ui
  if ! xcrun xcresulttool export attachments --path build/Tests.xcresult \
      --output-path build/ui-attachments >/dev/null 2>&1; then
    echo '::warning title=screenshots::xcresulttool could not export attachments'
    return 0
  fi
  python3 scripts/collect_screenshots.py build/ui-attachments build/screenshots-ui \
    || echo '::warning title=screenshots::collecting screenshots failed'
}
FEED_PID=""
on_exit() {
  local code=$?
  if [[ -n "$FEED_PID" ]]; then kill "$FEED_PID" 2>/dev/null || true; fi
  export_screenshots
  annotate_failure "$code"
}
trap on_exit EXIT

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

# 3. Unit and UI tests on an available iPhone simulator. Fail unless each bundle ran exactly
#    the expected number with 0 failures, so missing or skipped tests never count as a pass.
SIMULATOR_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); m=[x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x.get("isAvailable") and "iPhone" in x["name"]]; print(m[0] if m else "")')
if [[ -z "$SIMULATOR_ID" ]]; then
  echo 'No iPhone simulator available; refusing to continue.'
  exit 1
fi
if [[ "${RUN_TESTS:-1}" == "1" ]]; then
  PHASE=test
  CURRENT_LOG=build/xcodebuild-test.log
  rm -rf build/Tests.xcresult
  python3 -m http.server "$UI_FEED_PORT" --bind 127.0.0.1 --directory fixtures \
    > build/ui-feed-server.log 2>&1 &
  FEED_PID=$!
  sleep 1
  TEST_RUNNER_MINER_UI_SOURCE_URL="http://127.0.0.1:${UI_FEED_PORT}/demo-two-machines.json" \
  TEST_RUNNER_MINER_UI_FAILING_SOURCE_URL="http://127.0.0.1:${UI_FAILING_PORT}/status" \
  xcodebuild test -project MinerStatus.xcodeproj -scheme MinerStatus \
    -parallel-testing-enabled NO \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath build/DerivedData \
    -resultBundlePath build/Tests.xcresult CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$CURRENT_LOG"
  grep -E "^Test Case .*(passed|failed)|^Test Suite '.*\.xctest'|Executed [0-9]+ tests?|\*\* TEST" "$CURRENT_LOG" > build/test-summary.txt || true
  # The "Executed" line right after each bundle's "Test Suite '<bundle>.xctest' passed" line.
  bundle_result() { grep -A1 "Test Suite '$1.xctest' passed" "$CURRENT_LOG" | grep -E "Executed $2 tests?, with 0 failures" | tail -n 1 | sed 's/^[[:space:]]*//'; }
  CORE_RESULT=$(bundle_result MinerStatusCoreTests "$EXPECTED_TESTS")
  UI_RESULT=$(bundle_result MinerStatusUITests "$EXPECTED_UI_TESTS")
  if [[ -z "$CORE_RESULT" || -z "$UI_RESULT" ]]; then
    echo "Expected ${EXPECTED_TESTS} unit and ${EXPECTED_UI_TESTS} UI tests executed with 0 failures; see build/test-summary.txt."
    exit 1
  fi
  # Public evidence: annotations are readable through the API without signing in.
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::notice title=XCTest unit::${CORE_RESULT}"
    echo "::notice title=XCTest UI::${UI_RESULT}"
    echo "::notice title=Toolchain::$(xcodebuild -version | tr '\n' ' ')/ simulator: $(xcrun simctl list devices | grep -F "$SIMULATOR_ID" | sed 's/^ *//')"
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
# SideStore uses CFBundleDisplayName as the Apple App ID name, which must be ASCII; the Chinese
# home-screen name comes from zh-Hant.lproj/InfoPlist.strings.
DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")
if ! [[ "$DISPLAY_NAME" =~ ^[A-Za-z0-9\ ]+$ ]]; then
  echo "CFBundleDisplayName '$DISPLAY_NAME' must be ASCII letters, digits or spaces (SideStore App ID name)"
  exit 1
fi
test "$(plutil -extract CFBundleDisplayName raw -o - "$APP/zh-Hant.lproj/InfoPlist.strings")" = '礦機狀態'
echo "Display name: $DISPLAY_NAME (zh-Hant: 礦機狀態)"
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
