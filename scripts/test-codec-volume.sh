#!/bin/bash
set -euo pipefail
VOLUME_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VOLUME_SDK=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
mkdir -p "$VOLUME_ROOT/build/CodecTransport"
xcrun clang -isysroot "$VOLUME_SDK" -mmacosx-version-min=15.0 -fobjc-arc -fblocks -Wall -Wextra \
  -Wno-unused-parameter -I"$VOLUME_ROOT/Helpers/CodecTransport" -I"$VOLUME_ROOT/Vendor/BlueBloom/Driver" \
  "$VOLUME_ROOT/Helpers/CodecTransport/CodecVolumeSync.m" "$VOLUME_ROOT/Tests/CodecTransport/CodecVolumeSyncTests.m" \
  -framework Foundation -framework CoreAudio -o "$VOLUME_ROOT/build/CodecTransport/CodecVolumeSyncTests"
"$VOLUME_ROOT/build/CodecTransport/CodecVolumeSyncTests"
xcrun clang -isysroot "$VOLUME_SDK" -mmacosx-version-min=15.0 -fobjc-arc -fblocks -Wall -Wextra \
  -Wno-unused-parameter -I"$VOLUME_ROOT/Vendor/BlueBloom/Engine" \
  "$VOLUME_ROOT/Vendor/BlueBloom/Engine/AvrcpController.m" "$VOLUME_ROOT/Vendor/BlueBloom/Engine/BBLog.m" \
  "$VOLUME_ROOT/Tests/CodecTransport/AvrcpVolumeTests.m" -framework Foundation \
  -o "$VOLUME_ROOT/build/CodecTransport/AvrcpVolumeTests"
"$VOLUME_ROOT/build/CodecTransport/AvrcpVolumeTests"
