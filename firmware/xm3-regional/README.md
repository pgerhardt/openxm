# WH-1000XM3 regional firmware archive

Six original packages downloaded directly from Sony over HTTPS on October 29, 2026. Japanese and Chinese firmware is stored in separate service-ID directories. The four international packages remain in [../xm3](../xm3/README.md).

See [firmware release notes](../RELEASE_NOTES.md) for Sony's original change descriptions, English translations, regional sources and unresolved historical gaps.

| Region | Service ID | Version | File | Bytes |
| --- | --- | --- | --- | ---: |
| Japan | MDRID291601 | 4.1.1 | [HDX-2916_V0411_SPLC.bin](japan-MDRID291601/HDX-2916_V0411_SPLC.bin) | 2,916,572 |
| Japan | MDRID291601 | 4.2.2 | [HDX-2916_V0422_SPLC.bin](japan-MDRID291601/HDX-2916_V0422_SPLC.bin) | 2,917,412 |
| Japan | MDRID291601 | 4.5.2 | [HDX-2916_V0452_SPLC_with_stack.bin](japan-MDRID291601/HDX-2916_V0452_SPLC_with_stack.bin) | 3,776,802 |
| China | MDRID291602 | 4.1.3 | [HDX-2916_V0413_CN.bin](china-MDRID291602/HDX-2916_V0413_CN.bin) | 2,747,762 |
| China | MDRID291602 | 4.2.2 | [HDX-2916_V0422_CN.bin](china-MDRID291602/HDX-2916_V0422_CN.bin) | 2,748,326 |
| China | MDRID291602 | 4.5.2 | [HDX-2916_V0452_CN_with_stack.bin](china-MDRID291602/HDX-2916_V0452_CN_with_stack.bin) | 3,607,712 |

[manifest.json](manifest.json) records each direct source URL, original filename, region, service ID, size, SHA-256, SHA-1, MD5 and complete container record layout. Both 4.5.2 images match the size and SHA-1 in Sony's regional update metadata. Those two images and Chinese 4.1.3 also match the Git blob identities in the previously inspected, pinned MDR_Proxy archive. Raw and decoded Sony metadata is preserved under [metadata](metadata/).

Every file was parsed through all `APPUHDR2`, `PARTDATA` and `APPUPFTR` records with exact end-of-file bounds. Each uses variant `ZARKOV77`. These structure checks and recorded hashes do not constitute independent firmware signature verification. The downloaded bytes are unchanged.

Verify the regional binaries from this directory:

```sh
shasum -a 256 -c SHA256SUMS
```

Together with the international archive, ten packages are saved:

- International / MDRID291600: 2.0.0, 4.1.1, 4.2.2, 4.5.2.
- Japan / MDRID291601: 4.1.1, 4.2.2, 4.5.2.
- China / MDRID291602: 4.1.3, 4.2.2, 4.5.2.

Japanese 2.0.0 remains missing. The checked Sony paths returned 404, the known Wayback URL is an archived 404, and the inspected collections supplied no Japanese 2.0.0 payload. No 1.0.8 package was located for any region. No placeholder binaries are present.

These preservation copies are now pinned in the native updater alongside all four international packages. Region changes are explicitly flagged and final verification requires the target service ID and version. Only international 4.5.2 → 2.0.0 has been physically installed with OpenXM; all regional and cross-region paths remain experimental and hardware-unverified. Sony firmware remains proprietary; see [third-party notices](../../THIRD_PARTY_NOTICES.md).
