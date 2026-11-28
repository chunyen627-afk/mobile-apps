#!/bin/bash
# Mac-only build, same flow as apps/album-ios: XcodeGen, unit tests on an iOS simulator,
# optional launch smoke, unsigned Release IPA. Requires Xcode 15+ and XcodeGen;
# this script installs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
EXPECTED_TESTS="${EXPECTED_TESTS:-9}"
EXPECTED_UI_TESTS="${EXPECTED_UI_TESTS:-3}"
BUNDLE_ID=org.personal.watchlink.app
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
on_exit() {
  local code=$?
  export_screenshots
  annotate_failure "$code"
}
trap on_exit EXIT

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
  xcodebuild test -project WatchLink.xcodeproj -scheme WatchLink \
    -parallel-testing-enabled NO \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath build/DerivedData \
    -resultBundlePath build/Tests.xcresult CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$CURRENT_LOG"
  grep -E "^Test Case .*(passed|failed)|^Test Suite '.*\.xctest'|Executed [0-9]+ tests?|\*\* TEST" "$CURRENT_LOG" > build/test-summary.txt || true
  # The "Executed" line right after each bundle's "Test Suite '<bundle>.xctest' passed" line.
  bundle_result() { grep -A1 "Test Suite '$1.xctest' passed" "$CURRENT_LOG" | grep -E "Executed $2 tests?, with 0 failures" | tail -n 1 | sed 's/^[[:space:]]*//'; }
  CORE_RESULT=$(bundle_result WatchLinkCoreTests "$EXPECTED_TESTS")
  UI_RESULT=$(bundle_result WatchLinkUITests "$EXPECTED_UI_TESTS")
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
  xcodebuild build -project WatchLink.xcodeproj -scheme WatchLink \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$CURRENT_LOG"
fi

# 4. Optional launch smoke: install, launch the app, confirm it is still running,
#    save a screenshot. This is not a UI test suite; screens still need human review.
if [[ "${RUN_SIM_SMOKE:-0}" == "1" ]]; then
  PHASE=launch-smoke
  # Logged so a failure shows which step broke (annotate_failure prints the tail).
  CURRENT_LOG=build/launch-smoke.log
  SIM_APP=build/DerivedData/Build/Products/Debug-iphonesimulator/WatchLink.app
  mkdir -p build/screenshots
  # One redirect per command: a failure inside a redirected { } group would run the EXIT trap
  # with its output going to the log instead of the annotations.
  : > "$CURRENT_LOG"
  xcrun simctl boot "$SIMULATOR_ID" >> "$CURRENT_LOG" 2>&1 || true
  xcrun simctl bootstatus "$SIMULATOR_ID" -b >> "$CURRENT_LOG" 2>&1
  xcrun simctl install "$SIMULATOR_ID" "$SIM_APP" >> "$CURRENT_LOG" 2>&1
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" >> "$CURRENT_LOG" 2>&1
  sleep 8
  xcrun simctl io "$SIMULATOR_ID" screenshot --type=jpeg build/screenshots/launch-demo.jpg >> "$CURRENT_LOG" 2>&1
  # Read the list first: `launchctl list | grep -q` under pipefail failed whenever grep matched
  # early and launchctl got SIGPIPE, reporting a running app as not running.
  RUNNING=$(xcrun simctl spawn "$SIMULATOR_ID" launchctl list 2>&1 || true)
  if ! grep -q "$BUNDLE_ID" <<<"$RUNNING"; then
    # The exit stays outside this redirect, or the EXIT trap's annotations land in the log file.
    {
      echo 'error: App is not running 8 seconds after launch.'
      echo "== launchctl entries for the app"
      grep -i watchlink <<<"$RUNNING" || echo "(none)"
      echo "== newest crash reports"
      for report in $(ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i watchlink | head -n 3); do
        echo "-- $report"; head -n 40 ~/Library/Logs/DiagnosticReports/"$report"
      done
    } >> "$CURRENT_LOG" 2>&1 || true
    exit 1
  fi
  xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" || true
fi

# 5. Release archive for devices with signing off.
PHASE=archive
CURRENT_LOG=build/xcodebuild-archive.log
xcodebuild archive -project WatchLink.xcodeproj -scheme WatchLink \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/WatchLink.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tee "$CURRENT_LOG"

# 6. Check the device bundle explicitly.
PHASE=bundle-checks
CURRENT_LOG=""
APP=build/WatchLink.xcarchive/Products/Applications/WatchLink.app
PLIST="$APP/Info.plist"
test -f "$APP/WatchLink"
test -s "$APP/Frameworks/WatchLinkCore.framework/WatchLinkCore"
otool -L "$APP/WatchLink" | grep -F '@rpath/WatchLinkCore.framework/WatchLinkCore'
if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$PLIST" >/dev/null 2>&1; then
  echo 'NSAllowsArbitraryLoads must not be set'
  exit 1
fi
# The watch wakes the app over Bluetooth; active guidance also uses background location.
test "$(/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes:0' "$PLIST")" = bluetooth-peripheral
test "$(/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes:1' "$PLIST")" = location
# SideStore uses CFBundleDisplayName as the Apple App ID name, which must be ASCII; the Chinese
# home-screen name comes from zh-Hant.lproj/InfoPlist.strings.
DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")
if ! [[ "$DISPLAY_NAME" =~ ^[A-Za-z0-9\ ]+$ ]]; then
  echo "CFBundleDisplayName '$DISPLAY_NAME' must be ASCII letters, digits or spaces (SideStore App ID name)"
  exit 1
fi
test "$(plutil -extract CFBundleDisplayName raw -o - "$APP/zh-Hant.lproj/InfoPlist.strings")" = '手錶連結'
echo "Display name: $DISPLAY_NAME (zh-Hant: 手錶連結)"
echo "MinimumOSVersion: $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")"
echo "UIDeviceFamily: $(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily' "$PLIST" | tr -d '\n')"

# 7. Package an unsigned IPA and record its SHA256.
PHASE=package
rm -rf build/package
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/WatchLink.app
(cd build/package && /usr/bin/zip -qr ../WatchLink-unsigned.ipa Payload)
unzip -t build/WatchLink-unsigned.ipa
(cd build && shasum -a 256 WatchLink-unsigned.ipa | tee WatchLink-unsigned.ipa.sha256)
echo 'Created build/WatchLink-unsigned.ipa: sign with your own Apple account before installing.'
