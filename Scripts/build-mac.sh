#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${WRIST_BUILD_DIR:-$PROJECT_ROOT/build}"
APP="${1:-$BUILD_DIR/WristControl.app}"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"
EXTRA=(-module-cache-path "$BUILD_DIR/modules")
if [[ -n "${WRIST_COMPILER_OVERLAY:-}" ]]; then
  EXTRA=(-vfsoverlay "$WRIST_COMPILER_OVERLAY" -module-cache-path "$BUILD_DIR/modules")
fi
TARGET="$(uname -m)-apple-macosx13.0"
xcrun swiftc -swift-version 5 -target "$TARGET" "${EXTRA[@]}" -emit-library -static -emit-module \
  -module-name WristCore "$PROJECT_ROOT"/Shared/Sources/WristCore/*.swift \
  -o "$BUILD_DIR/libWristCore.a" -emit-module-path "$BUILD_DIR/WristCore.swiftmodule"
xcrun swiftc -swift-version 5 -target "$TARGET" "${EXTRA[@]}" -I "$BUILD_DIR" -L "$BUILD_DIR" -lWristCore \
  -framework AppKit -framework CoreBluetooth "$PROJECT_ROOT"/MacApp/*.swift -o "$APP/Contents/MacOS/WristControl"
cp "$PROJECT_ROOT/Config/Mac-Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string WristControl "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string dev.wristcontrol.prototype.mac "$APP/Contents/Info.plist"
# Finder metadata may be attached automatically under Documents; remove only those
# resource attributes on the newly built artifact before signing.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --sign - --entitlements "$PROJECT_ROOT/Config/Mac.entitlements" "$APP"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
