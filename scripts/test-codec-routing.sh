#!/bin/bash
set -euo pipefail
ROUTE_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROUTE_OUT="$ROUTE_ROOT/build/CodecTransport/RouteTests"
ROUTE_SDK=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
mkdir -p "$ROUTE_OUT"
xcrun clang -isysroot "$ROUTE_SDK" -mmacosx-version-min=15.0 -O2 -fobjc-arc -fblocks -Wall -Wextra \
  -I"$ROUTE_ROOT/Helpers/CodecTransport" "$ROUTE_ROOT/Helpers/CodecTransport/CodecAudioRoute.m" \
  "$ROUTE_ROOT/Tests/CodecTransport/CodecAudioRouteTests.m" -framework Foundation -o "$ROUTE_OUT/CodecAudioRouteTests"
"$ROUTE_OUT/CodecAudioRouteTests"
