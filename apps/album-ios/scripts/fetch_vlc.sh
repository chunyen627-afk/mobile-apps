#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=3.7.3
SHA256=0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9
mkdir -p Vendor
if [[ -f Vendor/vlc-version && "$(cat Vendor/vlc-version)" == "$SHA256" && -d Vendor/MobileVLCKit.xcframework ]]; then
  exit 0
fi
STAGING=$(mktemp -d Vendor/vlc.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
curl --fail --location --retry 3 --max-time 600 \
  "https://download.videolan.org/cocoapods/prod/MobileVLCKit-$VERSION-319ed2c0-79128878.tar.xz" \
  -o "$STAGING/vlc.tar.xz"
echo "$SHA256  $STAGING/vlc.tar.xz" | shasum -a 256 -c -
tar -xJf "$STAGING/vlc.tar.xz" -C "$STAGING" MobileVLCKit-binary/MobileVLCKit.xcframework
rm -rf Vendor/MobileVLCKit.xcframework
mv "$STAGING/MobileVLCKit-binary/MobileVLCKit.xcframework" Vendor/
echo "$SHA256" > Vendor/vlc-version
