# Third-party notices and provenance

OpenXM is an independent community fork. It is not the original Open Sound Connect distribution and is not affiliated with Sony, Apple, or Nina Labs.

## Open Sound Connect — MIT

The native Swift application, Bluetooth drivers, scenes, initial packaging scripts, and Blender headphone artwork derive from [rolottr/open-sound-connect](https://github.com/rolottr/open-sound-connect), commit `db03bc8d3908d2e101bedd11d2141f942866c5be`, retrieved 2026-10-29. Copyright (c) 2026 rolottr and Sound Connect contributors. The full MIT license is retained in [LICENSE](LICENSE). The original README is preserved in [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md) as historical provenance, not instructions for this distribution.

Changes in this fork include separate identity and storage, sea-glass styling, an original programmatic icon, offline preview mode, safer packet reassembly and byte bounds, additional regression tests, opt-in update checks pointed at this repository, a companion website, and release automation. Upstream work is credited, not claimed as original.

## MediaRemote Adapter — BSD-3-Clause

Vendored source from [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), by Jonas van den Berg and contributors. The full copyright notice, license and pinned revision are in [Vendor/MediaRemoteAdapter/LICENSE](Vendor/MediaRemoteAdapter/LICENSE) and [Vendor/MediaRemoteAdapter/UPSTREAM.md](Vendor/MediaRemoteAdapter/UPSTREAM.md). Its license is included in every app bundle. This optional local Now Playing integration uses a private macOS interface and may need updates across OS releases.

## Protocol references

[SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge), commit `d0ecd561ebf6f1cb87ffbf29528107b2221724d5`, and [sony-device-center](https://github.com/marconvcm/sony-device-center), commit `0bf98223c1ba402dd6c5136c21e6ab35482e4390`, were consulted for V1 battery, noise-control, and EQ packet layouts and generation-specific safety. Both use the MIT license, copyright (c) 2020 Nir Harel, Mor Gal, Sem Visscher, jimzrt, guilhermealbm, and other contributors. Their C++ implementations are not bundled. The Swift implementation also inherits the upstream credits to the SonyHeadphonesClient projects listed in the archived upstream README.

## Firmware protocol research

V2 EQ and V1/V2 playback metadata layouts were also checked against [mos9527/SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient/tree/68dfced0403b38114b77f2b374e606ce12a206a8), commit `68dfced0403b38114b77f2b374e606ce12a206a8`, MIT, copyright (c) 2026 mos9527, Amr Satrio and other contributors. The Swift mode-preservation and metadata implementations are independently written. Three unchanged received EQ packets from its `WF-LC900-2.0.3-equalizer` test capture are retained as test fixtures, with exact provenance/checksums and the upstream license in `Tests/OpenXMTests/Fixtures`. These are standard V2 parsing references, not ULT captures or evidence of live OpenXM control. No upstream executable or protocol implementation is bundled.

The native Sony metadata decoder uses independently written Swift based on the public ENC0003/HAS0003 format, key and digest construction documented by [lzghzr/MDR_Proxy](https://github.com/lzghzr/MDR_Proxy/blob/2e80d32e05f55ebf354389283e767e5a7c273e27/mdr.ts), copyright (c) 2019 lzghzr, MIT. The reference license is retained in `Vendor/MDRProxy/LICENSE` and included in the app bundle. The synthetic encrypted test vector was generated independently using OpenSSL and Python hashlib; it is not a Sony server capture. Sony firmware packages are not bundled.

The XM3 general-setting list, Surround/VPT and Sound Position Control implementation also uses wire-format facts from the same pinned Sony research snapshot below (`GENERAL_SETTING_SET_PARAM`, `VPT_GET/RET_CAPABILITY`, status and parameter messages). The Swift code is independently written; no decompiled implementation is bundled. Literal button capability fixtures come from our own XM3 4.5.2 capture.

The experimental native XM3 firmware tool uses independently written Swift code informed by the Sony updater research snapshot in [egaebel/sony-headphones-hack](https://github.com/egaebel/sony-headphones-hack/tree/ac1d5f8ff8d82a07e7b07d07ecc67c7b37a7b1ed) and the Qualcomm GAIA/VM Upgrade reference in [qiu-yongheng/GAIAControl](https://github.com/qiu-yongheng/GAIAControl/tree/fb9a492e783172041cc53eeb41143a7ad00eb212), whose reference files credit Qualcomm Technologies International, Ltd. (2017). Those sources were consulted for wire-format facts and state transitions and are not redistributed here. Sony firmware remains proprietary and is not covered by this repository's MIT license. Unchanged international XM3 packages are archived in [firmware/xm3](firmware/xm3/README.md), with source URLs and checksums; the app build does not bundle them. The optional download helper retrieves pinned 2.0.0 bytes from a community archive or 4.5.2 bytes from Sony’s firmware server and verifies the selected checksum; see [firmware provenance and limitations](docs/FIRMWARE.md).

## Artwork and website

The headphone model and thumbnail are upstream original Blender artwork under MIT; see [Resources/Artwork/ATTRIBUTION.md](Resources/Artwork/ATTRIBUTION.md). The website reuses that thumbnail, not manufacturer photographs. The new OpenXM mark is drawn with CoreGraphics in `Sources/OpenXMArtwork/main.swift` and SVG in `website/dist/assets/mark.svg`, under MIT. Product names are used to identify compatibility; trademark rights are not granted.
# Experimental Bluetooth codec transport

OpenXM includes selected components of [Blue Bloom](https://github.com/jonathanlu98/bluebloom)
at revision `7a9ab6c97d3a575f9d474dec1e636003e8999cca`, Copyright (c) 2026
Blue Bloom contributors, under the MIT License. The engine and virtual audio
driver have been adapted for OpenXM. See `Vendor/BlueBloom/OPENXM-PROVENANCE.md`
and `Vendor/BlueBloom/LICENSE` for the source inventory and modifications.

The transport includes Sony libldac (Apache-2.0), AOSP/Broadcom SBC (Apache-2.0),
and libfreeaptx (LGPL-2.1-or-later). Full licenses, notices and pinned versions
are retained in `Vendor/BlueBloom/third_party` and bundled in `CodecLicenses`.
libfreeaptx is dynamically linked as `Contents/Frameworks/libfreeaptx.dylib`;
its complete source and rebuild command are included in this repository.
Modified versions may be rebuilt with `scripts/build-codec-transport.sh` and
the application re-signed. AAC encoding uses Apple's AudioToolbox.

LDAC, aptX and Bluetooth names belong to their respective trademark owners.
OpenXM is not endorsed or certified by Sony, Qualcomm or Bluetooth SIG.
