#!/bin/bash
set -euo pipefail
SETTINGS_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SETTINGS_SRC="$SETTINGS_ROOT/Vendor/BlueBloom"
SETTINGS_OUT="$SETTINGS_ROOT/build/CodecTransport/SettingsTestsObjects"
SETTINGS_SDK=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
mkdir -p "$SETTINGS_OUT"
SETTINGS_FLAGS=(-isysroot "$SETTINGS_SDK" -mmacosx-version-min=15.0 -O2 -I"$SETTINGS_SRC/Engine"
  -I"$SETTINGS_SRC/third_party/libldac" -I"$SETTINGS_SRC/third_party/libldac/inc" -I"$SETTINGS_SRC/third_party/libldac/abr/inc"
  -I"$SETTINGS_ROOT/Helpers/CodecTransport")
SETTINGS_OBJECTS=()
for SETTINGS_FILE in "$SETTINGS_SRC/third_party/libldac/src/ldaclib.c" "$SETTINGS_SRC/third_party/libldac/src/ldacBT.c" \
  "$SETTINGS_SRC/third_party/libldac/abr/src/ldacBT_abr.c" "$SETTINGS_SRC/third_party/libldac/ldac_a2dp.c"; do
  SETTINGS_OBJECT="$SETTINGS_OUT/$(basename "$SETTINGS_FILE").o"
  xcrun clang "${SETTINGS_FLAGS[@]}" -c "$SETTINGS_FILE" -o "$SETTINGS_OBJECT"
  SETTINGS_OBJECTS+=("$SETTINGS_OBJECT")
done
xcrun clang "${SETTINGS_FLAGS[@]}" -fobjc-arc -fblocks \
  "$SETTINGS_ROOT/Tests/CodecTransport/CodecSettingsTests.m" "$SETTINGS_ROOT/Helpers/CodecTransport/CodecStreamSettings.m" \
  "$SETTINGS_SRC/Engine/A2DPCodec.m" "$SETTINGS_SRC/Engine/CodecLDAC.m" "$SETTINGS_SRC/Engine/BBLog.m" \
  "${SETTINGS_OBJECTS[@]}" -framework Foundation -o "$SETTINGS_OUT/CodecSettingsTests"
"$SETTINGS_OUT/CodecSettingsTests"
