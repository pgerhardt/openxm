#!/bin/bash
set -euo pipefail
PAUSE_ROOT=$(cd "$(dirname "$0")/.." && pwd)
PAUSE_OUT="$PAUSE_ROOT/build/CodecTransport/PauseTests"
PAUSE_SDK=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
mkdir -p "$PAUSE_OUT"
xcrun clang -isysroot "$PAUSE_SDK" -mmacosx-version-min=15.0 -O2 -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
  -I"$PAUSE_ROOT/Helpers/CodecTransport" -I"$PAUSE_ROOT/Helpers/MediaPause" \
  "$PAUSE_ROOT/Helpers/MediaPause/DisconnectPause.m" "$PAUSE_ROOT/Helpers/CodecTransport/CodecDisconnectPause.m" \
  "$PAUSE_ROOT/Tests/CodecTransport/DisconnectPauseTests.m" -framework Foundation -o "$PAUSE_OUT/DisconnectPauseTests"
"$PAUSE_OUT/DisconnectPauseTests"
