#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/make_icon.py
xcodegen generate
mkdir -p build

if [[ "${RUN_TESTS:-1}" == "1" ]]; then
  SIMULATOR_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); matches=[x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x.get("isAvailable") and "iPhone" in x["name"]]; print(matches[0] if matches else "")')
  if [[ -z "$SIMULATOR_ID" ]]; then
    echo "No iPhone simulator available; refusing to mark tests as passed."
    exit 1
  fi
  xcodebuild test -project Lightbox.xcodeproj -scheme Lightbox \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -resultBundlePath build/Tests.xcresult CODE_SIGNING_ALLOWED=NO
fi

xcodebuild archive -project Lightbox.xcodeproj -scheme Lightbox \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Lightbox.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''

APP=build/Lightbox.xcarchive/Products/Applications/Lightbox.app
test -f "$APP/Lightbox"
test -s "$APP/Frameworks/AMSMB2.framework/AMSMB2"
# The simulator can find package frameworks in DerivedData even when the
# archive forgets to embed them. Validate the device bundle explicitly.
otool -L "$APP/Lightbox" | grep -F '@rpath/AMSMB2.framework/AMSMB2'
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/Lightbox.app
(cd build/package && /usr/bin/zip -qr ../Lightbox-unsigned.ipa Payload)
unzip -t build/Lightbox-unsigned.ipa
echo 'Created build/Lightbox-unsigned.ipa — sign with your own Apple account before installation.'
