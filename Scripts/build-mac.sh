#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${WRIST_BUILD_DIR:-$PROJECT_ROOT/build/mac-development}"
# Protected keychain access needs an authorized development profile. Do not fall
# back to ad-hoc signing or remove entitlements to make a build appear usable.
xcodebuild -project "$PROJECT_ROOT/WristControl.xcodeproj" -scheme WristControl \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
APP="$BUILD_DIR/Build/Products/Debug/WristControl.app"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
