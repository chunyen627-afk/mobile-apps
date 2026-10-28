#!/bin/bash
# Mac-only build of the toolbox: the album's icon and VLC download, XcodeGen, every tool's unit
# tests plus the toolbox and album UI tests on an iOS simulator, then an unsigned Release IPA.
# Requires Xcode 15+ and XcodeGen; this script installs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
EXPECTED_ALBUM_TESTS="${EXPECTED_ALBUM_TESTS:-41}"
EXPECTED_MINER_TESTS="${EXPECTED_MINER_TESTS:-125}"
EXPECTED_TOOLBOX_UI_TESTS="${EXPECTED_TOOLBOX_UI_TESTS:-4}"
EXPECTED_ALBUM_UI_TESTS="${EXPECTED_ALBUM_UI_TESTS:-6}"
mkdir -p build

# In GitHub Actions, report the failing phase and its errors as annotations, which the public API
# can read without signing in.
PHASE=setup
CURRENT_LOG=""
escape_annotation() { tr -d '\r' | sed 's/%/%25/g' | awk 'BEGIN { ORS = "%0A" } { print }'; }
annotate_failure() {
  local code=$1
  [[ $code -ne 0 && -n "${GITHUB_ACTIONS:-}" ]] || return 0
  echo "::error title=build.sh failed::phase ${PHASE} exited with ${code}"
  if [[ -n "$CURRENT_LOG" && -f "$CURRENT_LOG" ]]; then
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
  python3 ../miner-status-ios/scripts/collect_screenshots.py build/ui-attachments build/screenshots-ui \
    || echo '::warning title=screenshots::collecting screenshots failed'
}
on_exit() {
  local code=$?
  export_screenshots
  annotate_failure "$code"
}
trap on_exit EXIT

# 1. The album's generated icon and pinned VLC framework (both live in apps/album-ios).
PHASE=album-assets
CURRENT_LOG=build/album-assets.log
{ python3 ../album-ios/scripts/make_icon.py && bash ../album-ios/scripts/fetch_vlc.sh; } 2>&1 | tee "$CURRENT_LOG"

# 2. Generate the Xcode project from project.yml.
PHASE=xcodegen
CURRENT_LOG=build/xcodegen.log
xcodegen generate 2>&1 | tee "$CURRENT_LOG"

# 3. Unit and UI tests on an available iPhone simulator. Each bundle must run exactly the expected
#    number with 0 failures, so missing or skipped tests never count as a pass.
SIMULATOR_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); m=[x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x.get("isAvailable") and "iPhone" in x["name"]]; print(m[0] if m else "")')
if [[ -z "$SIMULATOR_ID" ]]; then
  echo 'No iPhone simulator available; refusing to continue.'
  exit 1
fi
if [[ "${RUN_TESTS:-1}" == "1" ]]; then
  PHASE=test
  CURRENT_LOG=build/xcodebuild-test.log
  rm -rf build/Tests.xcresult
  xcodebuild test -project Toolbox.xcodeproj -scheme Lightbox \
    -parallel-testing-enabled NO \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath build/DerivedData \
    -resultBundlePath build/Tests.xcresult CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$CURRENT_LOG"
  grep -E "^Test Case .*(passed|failed)|^Test Suite '.*\.xctest'|Executed [0-9]+ tests?|\*\* TEST" "$CURRENT_LOG" > build/test-summary.txt || true
  # The "Executed" line right after each bundle's "Test Suite '<bundle>.xctest' passed" line.
  bundle_result() { grep -A1 "Test Suite '$1.xctest' passed" "$CURRENT_LOG" | grep -E "Executed $2 tests?, with 0 failures" | tail -n 1 | sed 's/^[[:space:]]*//'; }
  ALBUM_RESULT=$(bundle_result LightboxTests "$EXPECTED_ALBUM_TESTS")
  MINER_RESULT=$(bundle_result MinerStatusCoreTests "$EXPECTED_MINER_TESTS")
  TOOLBOX_UI_RESULT=$(bundle_result ToolboxUITests "$EXPECTED_TOOLBOX_UI_TESTS")
  ALBUM_UI_RESULT=$(bundle_result LightboxUITests "$EXPECTED_ALBUM_UI_TESTS")
  if [[ -z "$ALBUM_RESULT" || -z "$MINER_RESULT" || -z "$TOOLBOX_UI_RESULT" || -z "$ALBUM_UI_RESULT" ]]; then
    echo "Expected ${EXPECTED_ALBUM_TESTS} album, ${EXPECTED_MINER_TESTS} miner, ${EXPECTED_TOOLBOX_UI_TESTS} toolbox UI and ${EXPECTED_ALBUM_UI_TESTS} album UI tests with 0 failures; see build/test-summary.txt."
    exit 1
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::notice title=XCTest album unit::${ALBUM_RESULT}"
    echo "::notice title=XCTest miner unit::${MINER_RESULT}"
    echo "::notice title=XCTest toolbox UI::${TOOLBOX_UI_RESULT}"
    echo "::notice title=XCTest album UI::${ALBUM_UI_RESULT}"
    echo "::notice title=Toolchain::$(xcodebuild -version | tr '\n' ' ')/ simulator: $(xcrun simctl list devices | grep -F "$SIMULATOR_ID" | sed 's/^ *//')"
  fi
fi

# 4. Release archive for devices with signing off.
PHASE=archive
CURRENT_LOG=build/xcodebuild-archive.log
xcodebuild archive -project Toolbox.xcodeproj -scheme Lightbox \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Toolbox.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tee "$CURRENT_LOG"

# 5. Check the device bundle explicitly: the simulator finds frameworks in DerivedData even when
#    the archive forgets to embed them.
PHASE=bundle-checks
CURRENT_LOG=""
APP=build/Toolbox.xcarchive/Products/Applications/Lightbox.app
PLIST="$APP/Info.plist"
test -f "$APP/Lightbox"
test -s "$APP/Frameworks/AMSMB2.framework/AMSMB2"
test -s "$APP/Frameworks/MobileVLCKit.framework/MobileVLCKit"
test -s "$APP/Frameworks/MinerStatusCore.framework/MinerStatusCore"
test -s "$APP/demo-running.json"
test ! -e "$APP/decoder-fixture.avi"
test ! -e "$APP/decoder-mjpeg-fixture.avi"
otool -L "$APP/Lightbox" | grep -F '@rpath/AMSMB2.framework/AMSMB2'
otool -L "$APP/Lightbox" | grep -F '@rpath/MobileVLCKit.framework/MobileVLCKit'
otool -L "$APP/Lightbox" | grep -F '@rpath/MinerStatusCore.framework/MinerStatusCore'
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = org.personal.lightbox.album
test "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' "$PLIST")" = true
if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$PLIST" >/dev/null 2>&1; then
  echo 'NSAllowsArbitraryLoads must not be set'
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$PLIST" >/dev/null 2>&1; then
  echo 'UIBackgroundModes must not be set: the tools read in the foreground only'
  exit 1
fi
# SideStore uses CFBundleDisplayName as the Apple App ID name, which must be ASCII; the Chinese
# home-screen name comes from zh-Hant.lproj/InfoPlist.strings.
DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")
if ! [[ "$DISPLAY_NAME" =~ ^[A-Za-z0-9\ ]+$ ]]; then
  echo "CFBundleDisplayName '$DISPLAY_NAME' must be ASCII letters, digits or spaces (SideStore App ID name)"
  exit 1
fi
test "$(plutil -extract CFBundleDisplayName raw -o - "$APP/zh-Hant.lproj/InfoPlist.strings")" = '工具箱'
echo "Display name: $DISPLAY_NAME (zh-Hant: 工具箱)"
echo "MinimumOSVersion: $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")"

# 6. Package an unsigned IPA and record its SHA256.
PHASE=package
rm -rf build/package
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/Lightbox.app
(cd build/package && /usr/bin/zip -qr ../Toolbox-unsigned.ipa Payload)
unzip -t build/Toolbox-unsigned.ipa > /dev/null
(cd build && shasum -a 256 Toolbox-unsigned.ipa | tee Toolbox-unsigned.ipa.sha256)
echo 'Created build/Toolbox-unsigned.ipa: sign with your own Apple account before installing.'
