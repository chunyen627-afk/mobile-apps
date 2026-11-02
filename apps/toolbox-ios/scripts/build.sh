#!/bin/bash
# Mac-only build of the toolbox: the desk remote's PC helper unit tests, the album's icon and VLC
# download, XcodeGen, every tool's unit tests plus the toolbox, album and desk remote UI tests on
# an iOS simulator (the desk remote against its fake helper on the Mac's loopback), then an
# unsigned Release IPA. Requires Xcode 15+, XcodeGen and python3; this script installs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
EXPECTED_ALBUM_TESTS="${EXPECTED_ALBUM_TESTS:-52}"
EXPECTED_MINER_TESTS="${EXPECTED_MINER_TESTS:-126}"
EXPECTED_DESK_TESTS="${EXPECTED_DESK_TESTS:-45}"
EXPECTED_TOOLBOX_UI_TESTS="${EXPECTED_TOOLBOX_UI_TESTS:-5}"
EXPECTED_ALBUM_UI_TESTS="${EXPECTED_ALBUM_UI_TESTS:-6}"
EXPECTED_DESK_UI_TESTS="${EXPECTED_DESK_UI_TESTS:-41}"
# Includes 3 Windows-only tests, skipped (and counted) on macOS.
EXPECTED_DESK_HELPER_TESTS="${EXPECTED_DESK_HELPER_TESTS:-157}"
# The desk remote's fake helpers, as its own scripts/build.sh runs them: the first on the port in
# its fake-config.json, then one with someone at the keyboard, one with Codex closed to the tray
# and newer Codex limits, one with a window popped up and an update pending.
DESK_DIR=$(cd ../desk-remote-ios && pwd)
DESK_FIXTURES="$DESK_DIR/fixtures/fake-helper"
DESK_HELPER_PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$DESK_FIXTURES/fake-config.json")
DESK_BUSY_PORT="${DESK_BUSY_PORT:-8791}"
DESK_CLOSED_PORT="${DESK_CLOSED_PORT:-8792}"
DESK_POPUP_PORT="${DESK_POPUP_PORT:-8793}"
DESK_DEAD_PORT="${DESK_DEAD_PORT:-8799}"
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
  if [[ -f build/fake-helper.log ]]; then
    echo "::error title=fake helper log tail::$(tail -n 15 build/fake-helper.log | escape_annotation)"
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
HELPER_PIDS=""
stop_helpers() {
  for pid in $HELPER_PIDS; do kill "$pid" 2>/dev/null || true; done
  HELPER_PIDS=""
}
on_exit() {
  local code=$?
  stop_helpers
  export_screenshots
  annotate_failure "$code"
}
trap on_exit EXIT

# 0. The desk remote's PC helper unit tests (pure Python, hand-written fixtures).
PHASE=desk-helper-tests
CURRENT_LOG=build/desk-helper-tests.log
(cd "$DESK_DIR/pc-helper" && python3 -m unittest discover -s tests -v) > "$CURRENT_LOG" 2>&1 || { cat "$CURRENT_LOG"; exit 1; }
DESK_HELPER_RESULT=$(grep -E "^Ran ${EXPECTED_DESK_HELPER_TESTS} tests? in" "$CURRENT_LOG" || true)
if [[ -z "$DESK_HELPER_RESULT" ]] || ! tail -n 3 "$CURRENT_LOG" | grep -qE '^OK( \(skipped=[0-9]+\))?$'; then
  echo "Expected ${EXPECTED_DESK_HELPER_TESTS} desk remote helper tests to pass."
  tail -n 20 "$CURRENT_LOG"
  exit 1
fi
echo "Desk remote helper: $DESK_HELPER_RESULT OK"

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
  # The desk remote's fake helpers (the simulator shares the Mac's network).
  python3 -I "$DESK_DIR/pc-helper/desk_remote_helper.py" --fake "$DESK_FIXTURES" > build/fake-helper.log 2>&1 &
  HELPER_PIDS="$HELPER_PIDS $!"
  python3 -I "$DESK_DIR/pc-helper/desk_remote_helper.py" --fake "$DESK_FIXTURES" --fake-port "$DESK_BUSY_PORT" --fake-idle 5 \
    > build/fake-helper-busy.log 2>&1 &
  HELPER_PIDS="$HELPER_PIDS $!"
  python3 -I "$DESK_DIR/pc-helper/desk_remote_helper.py" --fake "$DESK_FIXTURES" --fake-port "$DESK_CLOSED_PORT" --fake-closed codex --fake-usage codex=37 \
    > build/fake-helper-closed.log 2>&1 &
  HELPER_PIDS="$HELPER_PIDS $!"
  python3 -I "$DESK_DIR/pc-helper/desk_remote_helper.py" --fake "$DESK_FIXTURES" --fake-port "$DESK_POPUP_PORT" --fake-popup --fake-update \
    > build/fake-helper-popup.log 2>&1 &
  HELPER_PIDS="$HELPER_PIDS $!"
  for port in "$DESK_HELPER_PORT" "$DESK_BUSY_PORT" "$DESK_CLOSED_PORT" "$DESK_POPUP_PORT"; do
    for _ in $(seq 1 20); do
      curl -sf "http://127.0.0.1:${port}/health" >/dev/null && break
      sleep 0.5
    done
    curl -sf "http://127.0.0.1:${port}/health" >/dev/null || { echo "error: desk remote fake helper on ${port} did not start"; exit 1; }
  done
  TEST_RUNNER_DESK_HELPER_HOST=127.0.0.1 \
  TEST_RUNNER_DESK_HELPER_PORT="$DESK_HELPER_PORT" \
  TEST_RUNNER_DESK_BUSY_PORT="$DESK_BUSY_PORT" \
  TEST_RUNNER_DESK_CLOSED_PORT="$DESK_CLOSED_PORT" \
  TEST_RUNNER_DESK_POPUP_PORT="$DESK_POPUP_PORT" \
  TEST_RUNNER_DESK_ELEVATE_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["elevate_key"])' "$DESK_FIXTURES/fake-config.json")" \
  TEST_RUNNER_DESK_HELPER_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$DESK_FIXTURES/fake-config.json")" \
  TEST_RUNNER_DESK_DEAD_PORT="$DESK_DEAD_PORT" \
  xcodebuild test -project Toolbox.xcodeproj -scheme Lightbox \
    -parallel-testing-enabled NO \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath build/DerivedData \
    -resultBundlePath build/Tests.xcresult CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$CURRENT_LOG"
  stop_helpers
  grep -E "^Test Case .*(passed|failed)|^Test Suite '.*\.xctest'|Executed [0-9]+ tests?|\*\* TEST" "$CURRENT_LOG" > build/test-summary.txt || true
  # The "Executed" line right after each bundle's "Test Suite '<bundle>.xctest' passed" line.
  bundle_result() { grep -A1 "Test Suite '$1.xctest' passed" "$CURRENT_LOG" | grep -E "Executed $2 tests?, with 0 failures" | tail -n 1 | sed 's/^[[:space:]]*//'; }
  ALBUM_RESULT=$(bundle_result LightboxTests "$EXPECTED_ALBUM_TESTS")
  MINER_RESULT=$(bundle_result MinerStatusCoreTests "$EXPECTED_MINER_TESTS")
  DESK_RESULT=$(bundle_result DeskRemoteCoreTests "$EXPECTED_DESK_TESTS")
  TOOLBOX_UI_RESULT=$(bundle_result ToolboxUITests "$EXPECTED_TOOLBOX_UI_TESTS")
  ALBUM_UI_RESULT=$(bundle_result LightboxUITests "$EXPECTED_ALBUM_UI_TESTS")
  DESK_UI_RESULT=$(bundle_result DeskRemoteUITests "$EXPECTED_DESK_UI_TESTS")
  if [[ -z "$ALBUM_RESULT" || -z "$MINER_RESULT" || -z "$DESK_RESULT" || -z "$TOOLBOX_UI_RESULT" || -z "$ALBUM_UI_RESULT" || -z "$DESK_UI_RESULT" ]]; then
    echo "Expected ${EXPECTED_ALBUM_TESTS} album, ${EXPECTED_MINER_TESTS} miner, ${EXPECTED_DESK_TESTS} desk remote, ${EXPECTED_TOOLBOX_UI_TESTS} toolbox UI, ${EXPECTED_ALBUM_UI_TESTS} album UI and ${EXPECTED_DESK_UI_TESTS} desk remote UI tests with 0 failures; see build/test-summary.txt."
    exit 1
  fi
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::notice title=Desk remote helper unittest::${DESK_HELPER_RESULT} OK"
    echo "::notice title=XCTest album unit::${ALBUM_RESULT}"
    echo "::notice title=XCTest miner unit::${MINER_RESULT}"
    echo "::notice title=XCTest desk remote unit::${DESK_RESULT}"
    echo "::notice title=XCTest toolbox UI::${TOOLBOX_UI_RESULT}"
    echo "::notice title=XCTest album UI::${ALBUM_UI_RESULT}"
    echo "::notice title=XCTest desk remote UI::${DESK_UI_RESULT}"
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
test -s "$APP/Frameworks/DeskRemoteCore.framework/DeskRemoteCore"
test -s "$APP/demo-running.json"
test ! -e "$APP/decoder-fixture.avi"
test ! -e "$APP/decoder-mjpeg-fixture.avi"
otool -L "$APP/Lightbox" | grep -F '@rpath/AMSMB2.framework/AMSMB2'
otool -L "$APP/Lightbox" | grep -F '@rpath/MobileVLCKit.framework/MobileVLCKit'
otool -L "$APP/Lightbox" | grep -F '@rpath/MinerStatusCore.framework/MinerStatusCore'
otool -L "$APP/Lightbox" | grep -F '@rpath/DeskRemoteCore.framework/DeskRemoteCore'
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = org.personal.lightbox.album
test "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' "$PLIST")" = true
# The desk remote's permissions and its notification links (deskremote://) now belong to the toolbox.
for key in NSCameraUsageDescription NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription NSFaceIDUsageDescription; do
  test -n "$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST")"
done
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$PLIST")" = deskremote
# No desk remote fixture or helper file may ship in the app.
if find "$APP" -name '*.jsonl' -o -name 'fake-config.json' -o -name '*.py' -o -name '*.ps1' | grep -q .; then
  echo 'fixtures or helper files ended up in the app bundle'
  exit 1
fi
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
