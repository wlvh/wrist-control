#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${WRIST_BUILD_DIR:-$PROJECT_ROOT/build/verification}"
mkdir -p "$BUILD_DIR"
DEVELOPER_DIR_LOCAL="$(xcode-select -p)"
EXTRA=(--disable-xctest --enable-swift-testing)
if [[ "$DEVELOPER_DIR_LOCAL" == /Library/Developer/CommandLineTools ]]; then
  # Work around the mixed 2024 CLT files observed on the development Mac.
  # This is a compiler-only virtual file map; no system files are changed.
  python3 - "$BUILD_DIR" "$DEVELOPER_DIR_LOCAL" <<'PY'
import json, sys
from pathlib import Path
out, developer = map(Path, sys.argv[1:])
out = out.resolve()
empty = out / 'empty.modulemap'
empty.write_text('')
roots = []
include = developer / 'usr/include/swift'
if (include / 'module.modulemap').exists() and (include / 'bridging.modulemap').exists():
    if 'module SwiftBridging' in (include / 'module.modulemap').read_text():
        roots.append({'type':'file','name':str(include/'module.modulemap'),'external-contents':str(empty)})
manifest = developer / 'usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule'
for private in manifest.glob('*.private.swiftinterface'):
    public = Path(str(private).replace('.private.swiftinterface', '.swiftinterface'))
    if public.exists() and public.stat().st_mtime > private.stat().st_mtime:
        roots.append({'type':'file','name':str(private),'external-contents':str(public)})
(out / 'clt-overlay.json').write_text(json.dumps({'version':0,'roots':roots}))
PY
  OVERLAY="$BUILD_DIR/clt-overlay.json"
  EXTRA+=(-Xbuild-tools-swiftc -vfsoverlay -Xbuild-tools-swiftc "$OVERLAY"
         -Xbuild-tools-swiftc -module-cache-path -Xbuild-tools-swiftc "$BUILD_DIR/manifest-modules"
         -Xswiftc -vfsoverlay -Xswiftc "$OVERLAY"
         -Xswiftc -module-cache-path -Xswiftc "$BUILD_DIR/modules"
         -Xswiftc -F -Xswiftc "$DEVELOPER_DIR_LOCAL/Library/Developer/Frameworks"
         -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_LOCAL/Library/Developer/Frameworks")
fi
swift test --package-path "$PROJECT_ROOT" --scratch-path "$BUILD_DIR/package" \
  "${EXTRA[@]}"
plutil -lint "$PROJECT_ROOT/WristControl.xcodeproj/project.pbxproj" \
  "$PROJECT_ROOT/Config/Mac-Info.plist" "$PROJECT_ROOT/Config/Watch-Info.plist" "$PROJECT_ROOT/Config/Mac.entitlements"
