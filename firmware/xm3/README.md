# WH-1000XM3 firmware archive

International model only: **WH-1000XM3 / HP001 / MDRID291600**.

See [firmware release notes](../RELEASE_NOTES.md) for Sony's original change descriptions, English translations, regional sources and unresolved historical gaps.

Six Japanese and Chinese packages are preserved separately in the [regional archive](../xm3-regional/README.md), with their own service IDs, source URLs and checksums.

Four of the five versions identified in Sony's update metadata have downloadable packages here. **1.0.8 is missing**: its existence is documented, but no international download was located as of 2026-10-29. There is no placeholder `.bin` for it.

| Version | File | Bytes | Source | OpenXM installation support |
| --- | --- | ---: | --- | --- |
| 1.0.8 | Not found | — | Listed in Sony update metadata | None |
| 2.0.0 | [xm3-2.0.0.bin](xm3-2.0.0.bin) | 2,711,470 | Pinned MDR Proxy archive | Downgrade from 4.5.2; one physical test completed |
| 4.1.1 | [xm3-4.1.1.bin](xm3-4.1.1.bin) | 2,916,572 | Sony server; byte-identical to pinned archive | Experimental; hardware installation unverified |
| 4.2.2 | [xm3-4.2.2.bin](xm3-4.2.2.bin) | 2,917,412 | Sony server | Experimental; hardware installation unverified |
| 4.5.2 | [xm3-4.5.2.bin](xm3-4.5.2.bin) | 3,776,802 | Sony server; byte-identical to pinned archive | Experimental; hardware installation unverified |

These are unchanged firmware packages. The filenames are normalized for this repository; original URLs, sizes, SHA-256, SHA-1, MD5 and container record lengths are recorded in [manifest.json](manifest.json). Every available image was downloaded, checked against its recorded hashes, and parsed through the complete `APPUHDR2` / `PARTDATA` / `APPUPFTR` container. All use the `ZARKOV77` variant. A locally recorded hash identifies these bytes; it is not an independent Sony signature check.

Verify the archive from this directory:

```sh
shasum -a 256 -c SHA256SUMS
```

## Sources

- [Sony's international XM3 update metadata](https://info.update.sony.net/HP001/MDRID291600/info/info.xml) lists 1.0.8, 2.0.0, 4.1.1 and 4.2.2 as source versions for 4.5.2. The 4.5.2 package's size and SHA-1 also match that metadata. The decoded metadata digest was checked on 2026-10-29.
- [Pinned MDR Proxy international XM3 archive](https://github.com/lzghzr/MDR_Proxy/tree/2e80d32e05f55ebf354389283e767e5a7c273e27/firmware/2916/MDRID291600) supplies 2.0.0 and corroborates the 4.1.1 and 4.5.2 files.
- [Sony 4.1.1 package](https://info.update.sony.net/HP001/MDRID291600/contents/0002/HDX-2916_V0411.bin).
- [Sony 4.2.2 package](https://info.update.sony.net/HP001/MDRID291600/contents/0003/HDX-2916_V0422.bin).
- [Sony 4.5.2 package, including stack](https://info.update.sony.net/HP001/MDRID291600/contents/0004/HDX-2916_V0452_with_stack.bin).

The search for 1.0.8 checked the MDR Proxy archive and its XM3 history, public file searches, and Sony's plausible `contents/0000/HDX-2916_V0108.bin` and `contents/0001/HDX-2916_V0108.bin` URLs (both returned HTTP 404). This does not prove no copy exists elsewhere. A known firmware version is not necessarily available as a downloadable update package.

## Installation and ownership

OpenXM now accepts these four pinned international packages and the six regional packages, with experimental transitions between distinct catalog entries; see [firmware instructions](../../docs/FIRMWARE.md). Firmware files in this folder are not copied into the macOS app by the build script.

Sony firmware is proprietary and is not covered by this repository's MIT license. See [third-party notices](../../THIRD_PARTY_NOTICES.md).
