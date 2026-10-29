#!/bin/zsh
# Build and package the app for this Mac's architecture.
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=release "$ROOT/scripts/build.sh"
ARCHIVE="SoundConnect-macos-$(uname -m).zip"
cd "$ROOT/build"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "SoundConnect.app" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "==> Packaged $ROOT/build/$ARCHIVE"
