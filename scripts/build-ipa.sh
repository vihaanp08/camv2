#!/bin/bash
#
# Builds an unsigned Cam.ipa.
#
# Unsigned on purpose: that is what sideloading tools (Sideloadly, AltStore,
# ESign) expect — they re-sign the bundle with your own Apple ID and rewrite the
# bundle identifier as they install it. The original Cam.ipa was unsigned the
# same way.
#
# Needs Xcode (not just Command Line Tools). Runs locally or on a CI runner.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="build"
APP_NAME="Cam"
OUT="${APP_NAME}.ipa"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: xcodebuild not available. This needs full Xcode, not just Command Line Tools." >&2
  echo "       Current developer dir: $(xcode-select -p 2>/dev/null || echo unknown)" >&2
  exit 1
fi

echo "==> Toolchain"
xcodebuild -version

echo "==> Cleaning"
rm -rf "$BUILD_DIR" Payload "$OUT"

echo "==> Building (Release, device, unsigned)"
xcodebuild \
  -project CardSwap/CardSwap.xcodeproj \
  -scheme CardSwap \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  build

APP_PATH="$BUILD_DIR/Build/Products/Release-iphoneos/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: expected app bundle not found at $APP_PATH" >&2
  echo "       built products:" >&2
  ls -la "$BUILD_DIR/Build/Products/Release-iphoneos/" >&2 || true
  exit 1
fi

echo "==> Packaging $OUT"
# An .ipa is just a zip with the bundle inside a top-level Payload/ directory.
mkdir -p Payload
cp -R "$APP_PATH" "Payload/"
zip -qry "$OUT" Payload
rm -rf Payload

echo
echo "==> Done: $ROOT/$OUT  ($(du -h "$OUT" | cut -f1))"
unzip -l "$OUT" | head -15
echo
echo "Install it with Sideloadly (https://sideloadly.io) or AltStore."
