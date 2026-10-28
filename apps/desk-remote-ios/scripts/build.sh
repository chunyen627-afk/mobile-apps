#!/bin/bash
# Mac-only build, same flow as apps/miner-status-ios: the PC helper's own unit tests, XcodeGen,
# unit and UI tests on an iOS simulator against the fake helper, unsigned Release IPA.
# Requires Xcode 15+, XcodeGen and python3; this script installs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
# Includes 3 Windows-only tests (the real PowerShell companion twice, a real screen capture),
# which are skipped (and counted) on macOS.
EXPECTED_HELPER_TESTS="${EXPECTED_HELPER_TESTS:-105}"
EXPECTED_TESTS="${EXPECTED_TESTS:-36}"
EXPECTED_UI_TESTS="${EXPECTED_UI_TESTS:-29}"
FIXTURES=fixtures/fake-helper
HELPER_PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$FIXTURES/fake-config.json")
# A second fake helper that reports someone at the keyboard (5 s idle), for "send anyway".
BUSY_PORT="${BUSY_PORT:-8791}"
# A third whose Codex has no window (closed to the tray), for "coming in opens it", and whose
# Codex limits are newer than the first's (same account), for "the newer limits on both PCs".
CLOSED_PORT="${CLOSED_PORT:-8792}"
DEAD_PORT="${DEAD_PORT:-8799}"
BUNDLE_ID=org.personal.deskremote.app
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
    local failed passed
    failed=$({ grep -E "^Test Case '.*' failed" "$CURRENT_LOG" || true; } | sed -E "s/^Test Case '-\[[^ ]+ ([^]]+)\]'.*/\1/" | sort -u | tr '\n' ' ')
    passed=$({ grep -E "^Test Case '.*' passed" "$CURRENT_LOG" || true; } | wc -l | tr -d ' ')
    if [[ -n "$failed" ]]; then echo "::error title=failed tests::${passed} passed; failed: ${failed}"; fi
    { grep -E '(error|fatal error|Error|FAIL):' "$CURRENT_LOG" || true; } | sort -u | head -n 8 | while IFS= read -r line; do
      echo "::error title=${PHASE}::$(printf '%s\n' "$line" | escape_annotation)"
    done
    echo "::error title=${PHASE} log tail::$(tail -n 40 "$CURRENT_LOG" | escape_annotation)"
  fi
  if [[ -f build/fake-helper.log ]]; then
    echo "::error title=fake helper log tail::$(tail -n 15 build/fake-helper.log | escape_annotation)"
  fi
}
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
HELPER_PID=""
BUSY_PID=""
CLOSED_PID=""
on_exit() {
  local code=$?
  if [[ -n "$HELPER_PID" ]]; then kill "$HELPER_PID" 2>/dev/null || true; fi
  if [[ -n "$BUSY_PID" ]]; then kill "$BUSY_PID" 2>/dev/null || true; fi
  if [[ -n "$CLOSED_PID" ]]; then kill "$CLOSED_PID" 2>/dev/null || true; fi
  export_screenshots
  annotate_failure "$code"
}
trap on_exit EXIT

# 1. The PC helper's unit tests (pure Python, hand-written fixtures).
PHASE=helper-tests
CURRENT_LOG=build/helper-tests.log
(cd pc-helper && python3 -m unittest discover -s tests -v) > "$CURRENT_LOG" 2>&1 || { cat "$CURRENT_LOG"; exit 1; }
HELPER_RESULT=$(grep -E "^Ran ${EXPECTED_HELPER_TESTS} tests? in" "$CURRENT_LOG" || true)
HELPER_TAIL=$(tail -n 3 "$CURRENT_LOG")
if [[ -z "$HELPER_RESULT" ]] || ! grep -qE '^OK( \(skipped=[0-9]+\))?$' <<<"$HELPER_TAIL"; then
  echo "Expected ${EXPECTED_HELPER_TESTS} helper tests to pass."
  tail -n 20 "$CURRENT_LOG"
  exit 1
fi
echo "Helper: $HELPER_RESULT OK"

# 2. Generate the Xcode project from project.yml.
PHASE=xcodegen
CURRENT_LOG=build/xcodegen.log
xcodegen generate 2>&1 | tee "$CURRENT_LOG"

# 3. Unit and UI tests on an available iPhone simulator, with the fake helper on the Mac's
#    loopback (the simulator shares the Mac's network). Each bundle must run exactly the
#    expected number with 0 failures.
SIMULATOR_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); m=[x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x.get("isAvailable") and "iPhone" in x["name"]]; print(m[0] if m else "")')
if [[ -z "$SIMULATOR_ID" ]]; then
  echo 'No iPhone simulator available; refusing to continue.'
  exit 1
fi
PHASE=test
CURRENT_LOG=build/xcodebuild-test.log
rm -rf build/Tests.xcresult
python3 -I pc-helper/desk_remote_helper.py --fake "$FIXTURES" > build/fake-helper.log 2>&1 &
HELPER_PID=$!
python3 -I pc-helper/desk_remote_helper.py --fake "$FIXTURES" --fake-port "$BUSY_PORT" --fake-idle 5 \
  > build/fake-helper-busy.log 2>&1 &
BUSY_PID=$!
python3 -I pc-helper/desk_remote_helper.py --fake "$FIXTURES" --fake-port "$CLOSED_PORT" --fake-closed codex --fake-usage codex=37 \
  > build/fake-helper-closed.log 2>&1 &
CLOSED_PID=$!
for port in "$HELPER_PORT" "$BUSY_PORT" "$CLOSED_PORT"; do
  for _ in $(seq 1 20); do
    curl -sf "http://127.0.0.1:${port}/health" >/dev/null && break
    sleep 0.5
  done
  curl -sf "http://127.0.0.1:${port}/health" >/dev/null || { echo "error: fake helper on ${port} did not start"; exit 1; }
done
TEST_RUNNER_DESK_HELPER_HOST=127.0.0.1 \
TEST_RUNNER_DESK_HELPER_PORT="$HELPER_PORT" \
TEST_RUNNER_DESK_BUSY_PORT="$BUSY_PORT" \
TEST_RUNNER_DESK_CLOSED_PORT="$CLOSED_PORT" \
TEST_RUNNER_DESK_ELEVATE_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["elevate_key"])' "$FIXTURES/fake-config.json")" \
TEST_RUNNER_DESK_HELPER_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$FIXTURES/fake-config.json")" \
TEST_RUNNER_DESK_DEAD_PORT="$DEAD_PORT" \
xcodebuild test -project DeskRemote.xcodeproj -scheme DeskRemote \
  -parallel-testing-enabled NO \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath build/DerivedData \
  -resultBundlePath build/Tests.xcresult CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$CURRENT_LOG"
grep -E "^Test Case .*(passed|failed)|^Test Suite '.*\.xctest'|Executed [0-9]+ tests?|\*\* TEST" "$CURRENT_LOG" > build/test-summary.txt || true
bundle_result() { grep -A1 "Test Suite '$1.xctest' passed" "$CURRENT_LOG" | grep -E "Executed $2 tests?, with 0 failures" | tail -n 1 | sed 's/^[[:space:]]*//'; }
CORE_RESULT=$(bundle_result DeskRemoteCoreTests "$EXPECTED_TESTS")
UI_RESULT=$(bundle_result DeskRemoteUITests "$EXPECTED_UI_TESTS")
if [[ -z "$CORE_RESULT" || -z "$UI_RESULT" ]]; then
  echo "error: expected ${EXPECTED_TESTS} unit and ${EXPECTED_UI_TESTS} UI tests executed with 0 failures; see build/test-summary.txt."
  exit 1
fi
kill "$HELPER_PID" "$BUSY_PID" "$CLOSED_PID" 2>/dev/null || true
HELPER_PID=""
BUSY_PID=""
CLOSED_PID=""
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "::notice title=Helper unittest::${HELPER_RESULT} OK"
  echo "::notice title=XCTest unit::${CORE_RESULT}"
  echo "::notice title=XCTest UI::${UI_RESULT}"
  echo "::notice title=Toolchain::$(xcodebuild -version | tr '\n' ' ')/ simulator: $(xcrun simctl list devices | grep -F "$SIMULATOR_ID" | sed 's/^ *//')"
fi

# 4. Release archive for devices with signing off.
PHASE=archive
CURRENT_LOG=build/xcodebuild-archive.log
xcodebuild archive -project DeskRemote.xcodeproj -scheme DeskRemote \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/DeskRemote.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tee "$CURRENT_LOG"

# 5. Check the device bundle explicitly.
PHASE=bundle-checks
CURRENT_LOG=""
APP=build/DeskRemote.xcarchive/Products/Applications/DeskRemote.app
PLIST="$APP/Info.plist"
test -f "$APP/DeskRemote"
test -s "$APP/Frameworks/DeskRemoteCore.framework/DeskRemoteCore"
otool -L "$APP/DeskRemote" | grep -F '@rpath/DeskRemoteCore.framework/DeskRemoteCore'
test "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' "$PLIST")" = true
if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$PLIST" >/dev/null 2>&1; then
  echo 'NSAllowsArbitraryLoads must not be set'
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$PLIST" >/dev/null 2>&1; then
  echo 'UIBackgroundModes must not be set: the app reads in the foreground only'
  exit 1
fi
DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")
if ! [[ "$DISPLAY_NAME" =~ ^[A-Za-z0-9\ ]+$ ]]; then
  echo "CFBundleDisplayName '$DISPLAY_NAME' must be ASCII letters, digits or spaces (SideStore App ID name)"
  exit 1
fi
test "$(plutil -extract CFBundleDisplayName raw -o - "$APP/zh-Hant.lproj/InfoPlist.strings")" = '桌面遙控'
# No fixture or helper file may ship in the app.
if find "$APP" -name '*.jsonl' -o -name 'fake-config.json' -o -name '*.py' | grep -q .; then
  echo 'fixtures or helper files ended up in the app bundle'
  exit 1
fi
echo "Display name: $DISPLAY_NAME (zh-Hant: 桌面遙控)"
echo "MinimumOSVersion: $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")"

# 6. Package an unsigned IPA and record its SHA256.
PHASE=package
rm -rf build/package
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/DeskRemote.app
(cd build/package && /usr/bin/zip -qr ../DeskRemote-unsigned.ipa Payload)
unzip -t build/DeskRemote-unsigned.ipa
(cd build && shasum -a 256 DeskRemote-unsigned.ipa | tee DeskRemote-unsigned.ipa.sha256)
echo 'Created build/DeskRemote-unsigned.ipa: sign with your own Apple account before installing.'
