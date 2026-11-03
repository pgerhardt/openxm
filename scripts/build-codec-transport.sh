#!/bin/bash
# Build only; never installs the driver, opens Bluetooth or changes an audio route.
set -euo pipefail
CODEC_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CODEC_SRC="$CODEC_ROOT/Vendor/BlueBloom"
CODEC_OUT="$CODEC_ROOT/build/CodecTransport"
CODEC_SDK=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
mkdir -p "$CODEC_OUT/obj" "$CODEC_OUT/Frameworks" "$CODEC_OUT/OpenXMCodec.driver/Contents/MacOS"
CODEC_FLAGS=(-isysroot "$CODEC_SDK" -mmacosx-version-min=15.0 -O2)
CODEC_INCLUDES=(-I"$CODEC_SRC/Engine" -I"$CODEC_SRC/Driver" -I"$CODEC_SRC/third_party/libfreeaptx"
  -I"$CODEC_SRC/third_party/libldac" -I"$CODEC_SRC/third_party/libldac/inc" -I"$CODEC_SRC/third_party/libldac/abr/inc"
  -I"$CODEC_SRC/third_party/sbc" -I"$CODEC_SRC/third_party/sbc/encoder/include")
CODEC_OBJECTS=()
for CODEC_FILE in "$CODEC_SRC"/Engine/*.m; do
  CODEC_OBJ="$CODEC_OUT/obj/$(basename "$CODEC_FILE").o"
  xcrun clang "${CODEC_FLAGS[@]}" "${CODEC_INCLUDES[@]}" -fobjc-arc -fblocks -c "$CODEC_FILE" -o "$CODEC_OBJ"
  CODEC_OBJECTS+=("$CODEC_OBJ")
done
for CODEC_FILE in "$CODEC_SRC/third_party/libldac/src/ldaclib.c" "$CODEC_SRC/third_party/libldac/src/ldacBT.c" \
  "$CODEC_SRC/third_party/libldac/abr/src/ldacBT_abr.c" "$CODEC_SRC/third_party/libldac/ldac_a2dp.c" \
  "$CODEC_SRC/third_party/sbc/sbc_a2dp.c" "$CODEC_SRC"/third_party/sbc/encoder/srce/*.c; do
  CODEC_OBJ="$CODEC_OUT/obj/$(basename "$CODEC_FILE").o"
  xcrun clang "${CODEC_FLAGS[@]}" "${CODEC_INCLUDES[@]}" -c "$CODEC_FILE" -o "$CODEC_OBJ"
  CODEC_OBJECTS+=("$CODEC_OBJ")
done
xcrun clang "${CODEC_FLAGS[@]}" -I"$CODEC_SRC/third_party/libfreeaptx" -dynamiclib "$CODEC_SRC/third_party/libfreeaptx/freeaptx.c" \
  -install_name @rpath/libfreeaptx.dylib -o "$CODEC_OUT/Frameworks/libfreeaptx.dylib"
CODEC_LINK=(-L"$CODEC_OUT/Frameworks" -lfreeaptx -Wl,-rpath,@executable_path/Frameworks \
  -Wl,-rpath,@executable_path/../Frameworks -framework Foundation -framework IOBluetooth \
  -framework AVFoundation -framework CoreAudio -framework AudioToolbox)
xcrun clang "${CODEC_FLAGS[@]}" "${CODEC_INCLUDES[@]}" -fobjc-arc -fblocks \
  "$CODEC_ROOT/Helpers/CodecTransport/main.m" "$CODEC_ROOT/Helpers/CodecTransport/CodecVolumeSync.m" \
  "$CODEC_ROOT/Helpers/CodecTransport/CodecStreamSettings.m" "${CODEC_OBJECTS[@]}" "${CODEC_LINK[@]}" \
  "$CODEC_ROOT/Helpers/CodecTransport/CodecAudioRoute.m" "$CODEC_ROOT/Helpers/CodecTransport/CodecHALAudioOutputs.m" \
  "$CODEC_ROOT/Helpers/CodecTransport/CodecDisconnectPause.m" \
  -sectcreate __TEXT __info_plist "$CODEC_ROOT/Helpers/CodecTransport/Info.plist" \
  -o "$CODEC_OUT/OpenXMCodecTransport"
xcrun clang "${CODEC_FLAGS[@]}" "${CODEC_INCLUDES[@]}" -fobjc-arc -fblocks \
  "$CODEC_SRC/CLI/main.m" "${CODEC_OBJECTS[@]}" "${CODEC_LINK[@]}" -o "$CODEC_OUT/CodecTests"
xcrun clang "${CODEC_FLAGS[@]}" -bundle -I"$CODEC_SRC/Driver" "$CODEC_SRC/Driver/BlueBloomDevice.c" \
  -framework CoreAudio -framework CoreFoundation -o "$CODEC_OUT/OpenXMCodec.driver/Contents/MacOS/OpenXMCodec"
cp "$CODEC_SRC/Driver/Info.plist" "$CODEC_OUT/OpenXMCodec.driver/Contents/Info.plist"
codesign --force --sign - "$CODEC_OUT/Frameworks/libfreeaptx.dylib"
codesign --force --sign - --identifier io.github.pgerhardt.OpenXM.CodecTransport \
  --requirements '=designated => identifier "io.github.pgerhardt.OpenXM.CodecTransport"' "$CODEC_OUT/OpenXMCodecTransport"
codesign --force --sign - "$CODEC_OUT/OpenXMCodec.driver"
codesign --verify --strict "$CODEC_OUT/OpenXMCodec.driver"
echo "Built codec helper, test tool and driver in $CODEC_OUT (nothing installed)."
