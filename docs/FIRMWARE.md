# Experimental Mac-only XM3 firmware installation

The firmware tool supports **WH-1000XM3 / HP001** with ten pinned original packages and upgrades, downgrades, or region changes between distinct catalog entries. This is a native macOS Bluetooth implementation. It does not need a phone, proxy, modified Sony app, root certificate, or additional runtime.

Hardware context: [52audio's WH-1000XM3 teardown](https://www.52audio.com/archives/31755.html) identifies Qualcomm CSR8675, Sony CXD90050/QN1, ST STM32L071CZT6, Cirrus CS47L15 and CS48L10. [TechInsights' public summary](https://www.techinsights.com/products/ddt-1912-813) independently lists the Qualcomm, Sony and Cirrus parts and Sony RC-S967 NFC. The CSR8675 identification supports researching the CSR updater, but chip presence alone does not identify update partitions, prove access to individual processors, establish regional package compatibility or enable arbitrary button remapping. The app uses captured device capabilities and protocol evidence for those decisions. WH-1000XM3 and WF-1000XM3 remain distinct targets.

| Region | Service ID | Available versions |
| --- | --- | --- |
| International | MDRID291600 | 2.0.0, 4.1.1, 4.2.2, 4.5.2 |
| Japan | MDRID291601 | 4.1.1, 4.2.2, 4.5.2 |
| China | MDRID291602 | 4.1.3, 4.2.2, 4.5.2 |

Only the **international 4.5.2 → 2.0.0** installation has been physically verified with this native updater. Other transitions, including all cross-region installations, are implemented and tested with pinned bytes and simulated/preflight checks, but remain hardware-unverified. Cross-region selection is permitted with a visible warning in the sheet and final confirmation; guidance and assistant availability may change. An identical version **and region** is rejected as already installed; the same version in a different region is a region change.

Other models, unknown service IDs, unlisted source versions and unpinned package bytes are rejected. The source and target must each be among the ten catalog entries above. No 1.0.8, Japanese 2.0.0 or Chinese 2.0.0 package is offered. This does not establish recovery from a failed flash. The tool does not back up calibration data or install modified firmware.

## In the main app

Open **Settings → Headphone Firmware**. The same sheet is available while ordinary headphone controls are disconnected. Device details load automatically; downloads and installation remain explicit:

1. **Package → Your headphones** automatically reads the connected headset's model, firmware, region and battery through the existing control channel. Reopening the sheet or reconnecting reads them again; changing the selected device clears the previous identity. **Refresh** retries a failed read without an automatic retry loop. An unfinished firmware session can still use a separate reserved connection for a manual refresh. Region names come from the XM3 service ID: international `MDRID291600`, Japan `MDRID291601`, China `MDRID291602`; locale and guidance language do not determine region.
2. **Check Server** fetches and decodes Sony's metadata for the selected package region. It verifies the envelope digest and accepted update-rule format. The digest is a consistency check, not a publisher signature; metadata cannot expand the pinned installation catalog.
3. Choose **Region** and **Firmware version**, then **Download Package**, or use **Choose File…**. The entire file must match the pinned size and SHA-256. Identical file sizes across regions are resolved by SHA-256; choosing a local file selects its actual region and version regardless of filename. Downloads use HTTPS and explicit host restrictions, and complete verified files are cached in `~/Library/Application Support/SoundConnect/Firmware`. An invalid existing cache file is preserved rather than silently replaced.
4. The install button becomes available only for a checked compatible headset and verified package. Installation uses the same `FirmwareRunner` and `VMUTransfer` as the CLI, including the final confirmation and another live identity/power check. A saved session selects its original target and permits only the matching device and image. A completed session offers independent version verification without starting another transfer.

Normal control writes, reconnection and pairing are reserved during firmware access or while a session journal remains. A kernel file lock excludes concurrent firmware processes; a leftover lock file alone does not indicate a running process. Corrupt journals are preserved and disable installation. Quitting during an installation displays a warning; phase checkpoints remain available for subsequent resume. Resume logic does not establish recovery from device failure.

The sheet flags Japan/China → International as a region change, with a warning that voice guidance and assistant availability can change. Region switching is documented by the [XM3 Utility Tool](https://github.com/saccomartin/xm3utilitytool/blob/36f742caeecadcfc6b52a09c670cab256128849b/README.md) and [MDR Proxy maintainer](https://www.mrwalkman.com/p/mdrproxyfwsidegradetool.html) (checked 2026-10-30). Those tools use Sony's mobile updater; this does not verify OpenXM's native transfer, resume and final regional read-back. OpenXM now exposes those selections experimentally, while keeping that hardware-evidence limitation visible.

Earlier on 2026-10-30, before the catalog expansion, the signed native app successfully decoded the live Sony metadata, downloaded both pinned images and verified their bytes. It rejected a Japanese 4.5.2 package on SHA-256 and kept installation disabled with the headset disconnected. No firmware installation or headphone setting write was performed during these UI checks. The main-app installation/resume flow still needs hardware validation.

The revised sheet was checked live in signed build `202610300856`: opening it while the app finished connecting automatically displayed **WH-1000XM3 / International / 2.0.0 / 100%** at 08:57:00 MDT, without pressing Refresh. Closing and reopening it produced a fresh reading at 08:57:38. Selecting the 2.0.0 package displayed the two-hour-or-longer downgrade warning and 50% minimum; the layout was visually inspected. All 211 tests across 30 suites passed, including the 49%/50% boundary, low-power resume rejection, regional-service labels, and automatic refresh deferral/reconnect behavior. No firmware installation was started.

## Ten-package catalog validation — 2026-10-30

All ten source URLs were fetched again and the returned bytes matched the preserved sizes and SHA-256 hashes. The six regional originals and four international originals also passed the production image verifier; single-byte changes were rejected. The full suite passed **217 tests in 31 suites**, including all 90 distinct catalog source/target pairs, identical-version region changes, wrong-region final read-back, malformed regional journals, legacy-journal compatibility and region-specific metadata decoding.

Signed native build `202610300932` displayed all four International, three Japan and three China menu choices. With the physical international XM3 still reporting **2.0.0 / 100%**, the app downloaded and verified **Japan 4.1.1** and **China 4.1.3**, enabled the correctly labeled installation action, and showed the International → Japan/China warnings. Check Server decoded live metadata for each selected regional service. Switching back to International cleared the regional metadata, previous package verification and mismatch warning. The layout was visually inspected. No installation or headphone setting write was performed during these checks; the earlier physical installation evidence below remains the only validated transfer path.

## Hardware result

The successful test used an international WH-1000XM3 reporting `HP001/MDRID291600`, initially on 4.5.2 with 100% battery, and an Apple Silicon Mac running macOS 26.6.2. The local debug app build was `202610291446`, based on commit `d5042a2` plus the firmware implementation and local changes. The Mac remained on AC power.

The image upload ran approximately 14:47–16:51 MDT (about 123 minutes). The headset accepted image validation (`VMU 0B`), restarted after the installation request, and reconnected automatically. Its next sync response reported resume point `03` with the same image identifier. The in-progress confirmation (`0E 00`) received completion (`12`) directly; this device did not require a separate `10` commit request. The runner then closed the upgrade session and independently read firmware **2.0.0** through MDR V1. macOS Bluetooth settings also displayed **2.0.0**. The process exited successfully and removed its completed-session journal at approximately 16:53 MDT.

Earlier attempts stopped before image data transfer while resolving service discovery and the XM3 sync-length extension described below. The successful run used the same-image resume entry point from that preparation state and transferred the complete image without interruption. It was not a test of recovery after a partial upload, power loss, or failed installation. At the time of that downgrade, 33 automated tests across six suites passed, including protocol fixtures and simulated transfer/failure paths. The subsequent upgrade implementation passes 40 tests across seven suites when both local firmware fixtures are supplied.

The subsequent regular-app session also read firmware 2.0.0 and completed initialization. It read noise/EQ/audio settings and treated unanswered playback-metadata requests as unavailable. The headset reported battery bytes `11 00 00 00` (0%, not charging), then closed its connection later. The cause of that later disconnect has not been established. Audio quality and the full control matrix on 2.0.0 remain untested.

## Prepare and inspect

The repository's [XM3 firmware archive](../firmware/xm3/README.md) contains 2.0.0, 4.1.1, 4.2.2 and 4.5.2, with checksums and source URLs. Version 1.0.8 is documented but its package has not been located. The updater accepts only 2.0.0 and 4.5.2. You can pass the files in `firmware/xm3` directly to the commands below, or fetch separate copies as shown.

Build from the repository, then retrieve the pinned package explicitly:

```sh
./scripts/build.sh
python3 scripts/fetch-xm3-firmware.py
open -n -W -a "$PWD/build/OpenXM.app" --args --firmware-inspect "$PWD/.work/firmware/xm3-2.0.0.bin"
```

The 2.0.0 download comes from a pinned community archive on GitHub. It is not bundled or automatically downloaded when OpenXM starts. For 2.0.0, verification accepts only the exact 2,711,470-byte image, regardless of the file's name:

```text
SHA-256 c0f3a263011e14d3ad24f53661dc9c9c4e7f4a2171efff0e929f2053a0ffe3bd
SHA-1   952e4c5816428f871f6f3a29d30976feb17d51c8
MD5     1bc9144f8a551369c902ec678adec9ae
```

These hashes identify the archive bytes; they are not proof of a Sony signature. The file in the independent XM3 utility archive is byte-identical. The filename `custom_fw.bin` in that archive refers to stock 2.0.0, according to its author.

For upgrading **2.0.0 → 4.5.2**, fetch and inspect the other pinned image:

```sh
python3 scripts/fetch-xm3-firmware.py --version 4.5.2
open -n -W -a "$PWD/build/OpenXM.app" --args --firmware-inspect "$PWD/.work/firmware/xm3-4.5.2.bin"
```

The helper downloads 4.5.2 directly from [Sony's firmware server](https://info.update.sony.net/HP001/MDRID291600/contents/0004/HDX-2916_V0452_with_stack.bin). On 2026-10-29, Sony's [international XM3 update metadata](https://info.update.sony.net/HP001/MDRID291600/info/info.xml) explicitly selected this package for source version 2.0.0, target version 4.5.2, size 3,776,802 bytes and SHA-1 below. The decoded metadata digest was verified, and the downloaded bytes matched the pinned MDR Proxy archive exactly. The app accepts the entire `with_stack` package unchanged, using its size and SHA-256:

```text
SHA-256 b67330f6f75a87c7798bc7c994a25f2df09ac66d8013f2536e8799838850aa43
SHA-1   442ac8d9e1fac3f22144316e0f8a41ad3f43a195
MD5     50d4038c20699dd5646f000b7d91fb64
```

The resulting VMU sync identifier is `7D 91 FB 64`. Package verification does not establish that the Mac upgrade works on hardware. Neither image is bundled with the app. The helper defaults to 2.0.0 for compatibility; `--version 4.5.2` is required for the upgrade download. Existing files are reused only if their size and checksum match; different contents are never overwritten.

Quit the normal OpenXM instance, connect exactly one WH-1000XM3 through macOS Bluetooth settings, then run:

```sh
open -n -W -a "$PWD/build/OpenXM.app" --args --firmware-probe --out "$PWD/.work/xm3-firmware-probe.txt"
```

This reads the model, firmware, battery, update category and service ID via MDR V1, then reads the GAIA application version. It does not enter upgrade mode. The report excludes the Bluetooth address and serial number. Preview/replay cannot run alongside firmware commands.

On 2026-10-29, this probe succeeded on the test headset: `WH-1000XM3`, firmware `4.5.2`, category/service `HP001/MDRID291600`, battery `100%`; GAIA application version reply `00 01 00 0A 00 01 04 52`. No upgrade-connect, sync, transfer or commit command was issued during that probe.

On this headset, reopening GAIA after the first probe timed out while normal MDR reads still worked. Bluetooth logs showed GAIA using channels 1 and 18 at different times. The updater now refreshes the full SDP service list before each GAIA connection, since filtered SDP queries timed out on the test Mac. It also closes MDR before opening GAIA and does not reopen MDR during firmware preparation. A subsequent full-query read-only probe succeeded, but reopening GAIA still required a fresh Bluetooth connection. Disconnect and reconnect the XM3 in macOS Bluetooth settings between a probe and the transfer; do not attempt a flash until preflight succeeds. The channel-reopen issue is not yet resolved.

## Run an experimental transfer

Allow **2 hours or more for a downgrade**, based on the approximately 123-minute local transfer above. The sheet and final confirmation display this guidance. The tool requires at least **50% reported headphone battery** and no reported charging, both before installation and before an unfinished transfer resumes. This is OpenXM's minimum, not a Sony-certified threshold or a guarantee of battery endurance. A full charge is recommended: [Sony's 4.5.2 instructions](https://www.sony.com/electronics/support/wireless-headphones-bluetooth-headphones/wh-1000xm3/downloads/00016733) call for fully charged devices and describe about 60 minutes for their mobile update, potentially longer. Remove the headphones' USB and audio cables, stop playback, and keep both devices nearby. Charge the Mac or connect it to power, keep its lid open and do not interrupt the transfer. The program prevents idle sleep while transferring; it cannot prevent shutdown or loss of power.

To upgrade a headset running **2.0.0**:

```sh
open -n -W -a "$PWD/build/OpenXM.app" --args --firmware-upgrade "$PWD/.work/firmware/xm3-4.5.2.bin" --out "$PWD/.work/xm3-upgrade.txt"
```

To downgrade a headset running **4.5.2**:

```sh
open -n -W -a "$PWD/build/OpenXM.app" --args --firmware-downgrade "$PWD/.work/firmware/xm3-2.0.0.bin" --out "$PWD/.work/xm3-downgrade.txt"
```

The upgrade and downgrade commands require the corresponding numeric version direction. For any supported transition, including a same-version region change, use `--firmware-install /absolute/path/to/package.bin`. The target region and version come from the pinned file hash, not CLI text or its filename. All commands reject a headset already running the exact target version and region. Firmware flags cannot be combined. The confirmation and progress window show the selected target; each confirmation states the actual source/target regions and versions and whether that transition has hardware evidence.

A native confirmation dialog appears **after** checking the file and live headset identity. Cancel is the default. Starting transfers firmware to device storage and may leave the device unusable if it fails; recovery has not been established. Identity and battery are checked again after confirmation, then MDR closes and GAIA discovery/version checks must succeed before upgrade mode starts.

A progress window stays visible through transfer, validation, reboot and commit. The report is saved as progress changes, so it can also be followed from Terminal. Keep the regular OpenXM control session and other headphone-control applications closed during the update. The absolute `-a` app path above ensures macOS runs this build even when another OpenXM copy is installed.

The engine follows device-requested byte counts/relative offsets, sends at most 250 firmware bytes per GAIA packet, waits for each acknowledgement, waits for image validation, requests installation, reconnects for commit, and checks the resulting MDR firmware version. `complete` from the transfer engine is not reported as a verified installation until the headset reads back both the selected target version and its firmware service region. Reading back the source region at the same version cannot count as completion. Transfer percentage describes bytes acknowledged, not overall installation progress.

The physical transfer averaged approximately 370 firmware bytes/second over its roughly 123-minute upload, with an early sample around 410 bytes/second (3.3 kbit/s). RFCOMM carries the protocol over Bluetooth; the updater does not configure a UART baud rate such as 9600 bps. Device-requested block sizes and acknowledgement round trips affect the effective payload rate. Slow but advancing progress is not a timeout. Faster transfer strategies have not been validated. The 4.5.2 package is larger, and its actual Mac transfer duration has not been measured; upgrade support does not change packet pacing.

Missing acknowledgements are never blindly retried. Unknown states, malformed packets, wrong identifiers, low battery and device error codes stop the run. Error codes are acknowledged without overriding them. A different pending update is not automatically aborted or erased.

## Interrupted sessions

Before entering upgrade mode the runner saves an exact device/image session record in `~/Library/Application Support/SoundConnect/firmware-session.json`, with user-only permissions. It contains the Bluetooth address, image hash, versions, source/target service IDs and last phase; do not publish it. Phase changes are saved before device mutations, including a completion checkpoint before the final version read-back. Logs go to `~/Library/Logs/OpenXM` unless `--out` is supplied.

If Bluetooth drops unexpectedly, reconnect the **same** headset in macOS and explicitly resume with the **same** verified image:

For an interrupted upgrade:

```sh
open -n -W -a "$PWD/build/OpenXM.app" --args --firmware-resume "$PWD/.work/firmware/xm3-4.5.2.bin" --out "$PWD/.work/xm3-resume.txt"
```

For an interrupted downgrade, use `xm3-2.0.0.bin` instead. Resume binds the exact source/target version-and-region pairs and verifies the image hash before Bluetooth access. Legacy international 2.0.0 ↔ 4.5.2 journals remain compatible; only those pairs may omit both service IDs. Missing one ID or an unknown/mismatched ID fails closed. A pending session blocks a fresh upgrade or downgrade, including a request in the opposite direction.

This requires a matching saved session, live model/region/battery checks, and another confirmation. It asks the device for its resume point; it does not invent a byte offset. If the selected target version is already running provisionally, only the remaining commit is allowed; a reset resume point cannot trigger another upload. A session already recorded as complete only performs the read-back and clears the journal if verification succeeds, without confirmation, a transfer-level battery requirement, or a new upgrade session. Do not delete the journal to bypass an error. If the device no longer exposes Bluetooth/control services, this program cannot recover it. Factory reset is not firmware rollback.

## Wire format and provenance

### WH-1000XM3 hardware references

[52audio's WH-1000XM3 teardown](https://www.52audio.com/archives/31755.html) identifies the CSR8675 Bluetooth/audio SoC, Sony CXD90050/QN1, STM32L071CZT6 control MCU, and Cirrus audio chips. It also identifies an Atmel ATSAMD21J17A-U on the opposite earcup's board. [TechInsights' public summary for SON-WH-1000XM3](https://www.techinsights.com/products/ddt-1912-813) independently lists CSR8675, CXD90050, CS47L15, CS48L10 and Sony RC-S967 NFC. References checked 2026-10-30; no commercial teardown report was accessed.

These identify components in the over-ear WH model, not a flash partition map. They do not establish which components a particular Sony package updates, the meaning of each PARTDATA record, regional interchangeability, or a safe raw-flash restore procedure. WF-1000XM3 earbud hardware and update packages remain separate. The updater continues to require the exact model, known regional service ID, pinned image hash and explicit source/target version-and-region pair.

### Update protocol references

This Swift implementation uses protocol facts from these pinned research sources; their application code and firmware are not bundled:

- [Sony updater research snapshot](https://github.com/egaebel/sony-headphones-hack/tree/ac1d5f8ff8d82a07e7b07d07ecc67c7b37a7b1ed): `application/update/csr`, `com/csr/gaia/library`, and V1 `UPDT_GET_PARAM`/`UpdateInquiredType`. The decompiled app uses GAIA UUID `7B265B0E-2232-4D45-BEF4-BB8AE62F813D`, CSR vendor `000A`, upgrade connect/control `0640`/`0642`, notification registration `4001 12`, and the last four MD5 bytes as the VMU sync identifier. Sony passthrough commands used for two-earbud updates are not part of this over-ear target.
- [Qualcomm GAIA/VM Upgrade reference](https://github.com/qiu-yongheng/GAIAControl/tree/fb9a492e783172041cc53eeb41143a7ad00eb212): GAIA frame layout, VMU opcodes, resume points, and validation/commit messages. BR/EDR uses `FF 01 flags length vendor(2) command(2) payload [xor]`; VMU uses `opcode length(2, BE) payload`.
- [MDR Proxy firmware archive](https://github.com/lzghzr/MDR_Proxy/tree/2e80d32e05f55ebf354389283e767e5a7c273e27/firmware/2916/MDRID291600): both target packages and regional mapping. The 4.5.2 archive is `HDX-2916_V0452_with_stack.442ac8d9e1fac3f22144316e0f8a41ad3f43a195.bin`.
- [XM3 utility](https://github.com/saccomartin/xm3utilitytool/tree/36f742caeecadcfc6b52a09c670cab256128849b): independent byte-identical 2.0.0 image and historical phone-based downgrade workflow. That workflow is evidence for package selection, not a hardware test of this Mac implementation.

V1 update metadata reads are `36 02` (category) and `36 03` (service), with `37 selector length UTF-8` replies. No V2 commands are used. GAIA's service cannot be passed to an MDR driver.

The physical 4.5.2 headset returned sync bytes `14 00 05 00 8A DE C9 AE 03`: the length counts the resume byte and four-byte identifier, but excludes the trailing protocol-version byte (`03`). The parser accepts this exact sync-extension shape while keeping strict lengths for other messages. Sony's reference reader consumes only the declared bytes and ignores the extension. The fixture is regression-tested. The following start reply was `02 00 03 00 06 66` (ready).

The 2.0.0 package contains `APPUHDR2` (36 bytes, variant `ZARKOV77`), four `PARTDATA` records (1,086,910; 382,180; 47,560; 1,194,584 bytes), and `APPUPFTR` (128 bytes). Its first partition contains `CSR-dfu2` and `HDX-2916_OTA`. Record headers add 12 bytes each, totaling 2,711,470 bytes. This structure was inspected offline; the program's acceptance gate is the exact size plus SHA-256.

The 4.5.2 package has the same container layout and `ZARKOV77` variant: a 36-byte header, four `PARTDATA` records (1,958,358; 456,516; 75,956; 1,285,736 bytes), a 128-byte footer and six 12-byte record headers, totaling 3,776,802 bytes. Its first partition also contains `CSR-dfu2` and `HDX-2916_OTA`.

## Automated validation

```sh
OPENXM_FIRMWARE_FIXTURES="$PWD/firmware/xm3" ./scripts/test.sh
```

The fixture directory is optional for ordinary tests. When provided, both supported images must be present; tests verify their release identities and sync IDs and reject single-byte corruption. The test suite can use the repository archive above or a separate local directory; it never downloads firmware. Session tests cover both directions, model/region/source-version rejection, low battery, mismatched image/journal versions, legacy journal decoding, target-version read-back and conflicting commands. Transfer tests simulate both image identifiers through data upload, restart and commit. No automated test opens Bluetooth or flashes headphones.

The integrated workflow adds catalog and access tests: independently encrypted synthetic metadata, digest/format corruption, region/model/service restrictions, network destination policy, invalid-cache preservation, exact device/image resume planning, completed-session verification, corrupt journals and concurrent-process exclusion. Set `OPENXM_METADATA_FIXTURE` to a previously saved Sony encrypted metadata response to enable the real-envelope regression test. At firmware UI integration, that response and both firmware images enabled 72 passing tests across 13 suites with no skips. The current full-suite count is tracked in [Sony app parity](SONY-APP-PARITY.md).

## Validation still needed

- A physical 2.0.0 → 4.5.2 upgrade, restart, commit and independent version read-back.
- Controlled interruption/resume tests on suitable hardware with a recovery plan.
- Audio, noise control, EQ and battery behavior after downgrade; older firmware may expose fewer capabilities.
- Separate protocol, package and hardware work before enabling XM4 or newer models.
