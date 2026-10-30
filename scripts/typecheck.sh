#!/bin/bash
#
# Type-checks the whole app WITHOUT Xcode or an iOS SDK.
#
# The trick: Command Line Tools ships the macOS SDK, and that SDK contains
# System/iOSSupport — the Mac Catalyst variants of UIKit, SwiftUI, AVKit,
# PhotosUI and MetalKit. Targeting *-macabi therefore type-checks against real
# iOS framework headers. It does not produce a runnable binary and it will not
# catch anything genuinely iOS-only, but it does catch ordinary type errors in
# every file, which plain `swiftc -parse` silently misses.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS="$SDK/System/iOSSupport"

if [ ! -d "$IOS" ]; then
  echo "error: $IOS not found; cannot type-check UIKit code on this machine." >&2
  exit 1
fi

cd "$ROOT/CardSwap/CardSwap"
swiftc -typecheck \
  -target arm64-apple-ios17.2-macabi \
  -sdk "$SDK" \
  -Fsystem "$IOS/System/Library/Frameworks" \
  -I "$IOS/usr/lib/swift" \
  -Xcc -iframework -Xcc "$IOS/System/Library/Frameworks" \
  -Xcc -isystem -Xcc "$IOS/usr/include" \
  $(find . -name '*.swift')

echo "type-check clean"
