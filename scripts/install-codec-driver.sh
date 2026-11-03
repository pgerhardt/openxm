#!/bin/bash
# Explicit administrator operation; never invoked by the build.
# Usage: sudo scripts/install-codec-driver.sh /absolute/OpenXMCodec.driver EXPECTED_CDHASH
# Removal: sudo scripts/install-codec-driver.sh --uninstall
set -euo pipefail
CODEC_DEST=/Library/Audio/Plug-Ins/HAL/OpenXMCodec.driver
if [[ $EUID != 0 ]]; then echo "Administrator authorization is required." >&2; exit 77; fi
if [[ $# == 1 && $1 == --uninstall ]]; then
  if [[ -e "$CODEC_DEST" ]]; then
    /bin/rm -rf "$CODEC_DEST"
    /usr/bin/killall coreaudiod 2>/dev/null || true
  fi
  exit 0
fi
if [[ $# != 2 || ! $2 =~ ^[0-9a-fA-F]{40}$ || $1 != /* || ! -d $1 || -L $1 ]]; then
  echo "Expected a driver bundle and its 40-character signing hash." >&2; exit 64
fi
if [[ -n $(/usr/bin/find "$1" -type l -print -quit) ]]; then echo "Driver contains symlinks." >&2; exit 65; fi
CODEC_STAGE=$(/usr/bin/mktemp -d /Library/Audio/Plug-Ins/HAL/.openxm-codec.XXXXXX)
trap '/bin/rm -rf "$CODEC_STAGE"' EXIT
/bin/cp -R -X "$1" "$CODEC_STAGE/OpenXMCodec.driver"
CODEC_COPY="$CODEC_STAGE/OpenXMCodec.driver"
/usr/bin/codesign --verify --strict -R "=cdhash H\"$2\"" "$CODEC_COPY"
if [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CODEC_COPY/Contents/Info.plist") != io.github.pgerhardt.OpenXM.codec.driver ]]; then
  echo "Unexpected driver identity." >&2; exit 65
fi
/usr/sbin/chown -R root:wheel "$CODEC_COPY"
/bin/chmod -R go-w "$CODEC_COPY"
if [[ -e "$CODEC_DEST" ]]; then /bin/mv "$CODEC_DEST" "$CODEC_STAGE/previous.driver"; fi
if ! /bin/mv "$CODEC_COPY" "$CODEC_DEST"; then
  if [[ -e "$CODEC_STAGE/previous.driver" ]]; then /bin/mv "$CODEC_STAGE/previous.driver" "$CODEC_DEST"; fi
  exit 1
fi
/usr/bin/killall coreaudiod 2>/dev/null || true
echo "Installed OpenXM Headphones and restarted the Mac audio service."
