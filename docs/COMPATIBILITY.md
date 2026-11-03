# Compatibility and hardware validation

Snapshot: 2026-10-30. OpenXM prioritizes WH-1000XM3 and WH-1000XM4. Current local changes extend the published 0.2.0 release. Capability discovery, rather than a model-name guess, controls the UI. Bluetooth service discovery selects the V1/V2 transport. The V1 battery inquiry is `10 00`; `22` means POWER OFF on V1 and must never be used as a battery probe.

Firmware is a separate compatibility claim: the [experimental native updater](FIRMWARE.md) accepts ten pinned WH-1000XM3 packages: international 2.0.0/4.1.1/4.2.2/4.5.2, Japan 4.1.1/4.2.2/4.5.2, and China 4.1.3/4.2.2/4.5.2. It supports distinct catalog pairs, including same-version region changes, with explicit regional warnings and source/target region checks on resume and final verification. Only international 4.5.2 → 2.0.0 has a completed physical installation result (2026-10-29). Other transitions and interruption/recovery remain hardware-unverified; automated coverage does not establish physical compatibility. XM4/XM5/XM6 remain unsupported for flashing.

## Evidence

- This fork has now exercised core WH-1000XM3 controls on firmware 4.5.2: 23 hardware checks passed after a local fix for the Off-to-active noise transition. This includes restoration and scene steps, not 23 separate features. See the [XM3 evaluation](XM3-HARDWARE-EVALUATION.md) for exact coverage, untested controls, and the ambient-level restoration limitation. Audible behavior remains unverified; the fix is not in the published 0.2.0 release.
- On 2.0.0, reversible native checks passed for button assignment/reconnection, Arena VPT, Front sound position, DSEE, automatic power off, Bright/Off and edits to Manual/Custom 1/Custom 2. All-slot EQ backup/restoration passed, with independent before/after exports matching all nine saved settings and curves exactly except timestamp. Build `202610300837` also passed live international firmware identity reads and preserve-selection/reconnect UI retests. The 2.0.0 button list has Ambient Sound Control and Google Assistant; Alexa, touch-panel toggle and voice-guidance controls were not advertised. This is scoped read-back evidence, not full audio, lifecycle or firmware-installation verification.
- Native macOS build, signature, protocol fixtures, and preview write gates are covered locally.
- The imported Open Sound Connect README reports XM4 hardware checks on firmware 2.6.0. This is **upstream evidence**, not a claim that this fork has been tested on the device.
- SonyBridge and sony-device-center independently document V1 packet layouts for XM3/XM4. Matching fixtures support the parser implementation, not radio operation.
- XM5/XM6 V2 support is inherited and experimental. Model-specific noise and battery behavior still needs hardware checks. XM6 uses ten EQ bands without a separate Clear Bass slider.
- XM3 does not support Speak-to-Chat. Other controls depend on reported functions and firmware.

## Required hardware pass

For each model and firmware, record macOS version, architecture, build commit, and the following results. A blank or failed check is not verification.

- [ ] Pair and connect; allow the expected Bluetooth prompt.
- [ ] Read model, firmware, battery, and codec; compare battery with an independent display.
- [ ] Switch ANC → ambient → off; confirm both the audible result and returned state.
- [ ] Set ambient level 12, switch to ANC, then back to ambient; confirm level is retained.
- [ ] Change a preset and a custom EQ band / Clear Bass; verify read-back and audible change.
- [ ] Toggle DSEE if advertised; record whether only the switch or processing state is confirmed.
- [ ] XM4: Speak-to-Chat on/off and configured timeout.
- [ ] Save and apply a scene; check results when some settings are unsupported.
- [ ] Power the headphones off/on; verify reconnection and no stale controls.
- [ ] Quit during connection, rapid slider movement, and reconnect; check for hangs or unintended writes.
- [ ] Menu-bar controls, window reopen, optional login item, and scene trigger behavior.

Power-off, NC Optimizer, multipoint, button assignments, and connection-priority changes should be tested separately because they may stop audio or reconnect the headset. These are never exercised by normal preview tests.

## Report a result

Open a repository issue with model, firmware, macOS, commit, and the exact checks that passed or failed. Attach only redacted Activity or `--probe` output. Remove device addresses, unique IDs, media metadata, user paths, and nearby-device names. Do not mark an entire model verified because one control worked.
