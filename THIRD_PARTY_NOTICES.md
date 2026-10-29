# Third-party notices and provenance

OpenXM is an independent community fork. It is not the original Open Sound Connect distribution and is not affiliated with Sony, Apple, or Nina Labs.

## Open Sound Connect — MIT

The native Swift application, Bluetooth drivers, scenes, initial packaging scripts, and Blender headphone artwork derive from [rolottr/open-sound-connect](https://github.com/rolottr/open-sound-connect), commit `db03bc8d3908d2e101bedd11d2141f942866c5be`, retrieved 2026-10-29. Copyright (c) 2026 rolottr and Sound Connect contributors. The full MIT license is retained in [LICENSE](LICENSE). The original README is preserved in [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md) as historical provenance, not instructions for this distribution.

Changes in this fork include separate identity and storage, sea-glass styling, an original programmatic icon, offline preview mode, safer packet reassembly and byte bounds, additional regression tests, opt-in update checks pointed at this repository, a companion website, and release automation. Upstream work is credited, not claimed as original.

## MediaRemote Adapter — BSD-3-Clause

Vendored source from [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), by Jonas van den Berg and contributors. The full copyright notice, license and pinned revision are in [Vendor/MediaRemoteAdapter/LICENSE](Vendor/MediaRemoteAdapter/LICENSE) and [Vendor/MediaRemoteAdapter/UPSTREAM.md](Vendor/MediaRemoteAdapter/UPSTREAM.md). Its license is included in every app bundle. This optional local Now Playing integration uses a private macOS interface and may need updates across OS releases.

## Protocol references

[SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge), commit `d0ecd561ebf6f1cb87ffbf29528107b2221724d5`, and [sony-device-center](https://github.com/marconvcm/sony-device-center), commit `0bf98223c1ba402dd6c5136c21e6ab35482e4390`, were consulted for V1 battery, noise-control, and EQ packet layouts and generation-specific safety. Both use the MIT license, copyright (c) 2020 Nir Harel, Mor Gal, Sem Visscher, jimzrt, guilhermealbm, and other contributors. Their C++ implementations are not bundled. The Swift implementation also inherits the upstream credits to the SonyHeadphonesClient projects listed in the archived upstream README.

## Artwork and website

The headphone model and thumbnail are upstream original Blender artwork under MIT; see [Resources/Artwork/ATTRIBUTION.md](Resources/Artwork/ATTRIBUTION.md). The website reuses that thumbnail, not manufacturer photographs. The new OpenXM mark is drawn with CoreGraphics in `Sources/OpenXMArtwork/main.swift` and SVG in `website/dist/assets/mark.svg`, under MIT. Product names are used to identify compatibility; trademark rights are not granted.
