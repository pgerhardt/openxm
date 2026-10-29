# Compatibility and hardware validation

Snapshot: 2026-10-29. OpenXM 0.2.0 prioritizes WH-1000XM3 and WH-1000XM4. Capability discovery, rather than a model-name guess, controls the UI. Bluetooth service discovery selects the V1/V2 transport. The V1 battery inquiry is `10 00`; `22` means POWER OFF on V1 and must never be used as a battery probe.

## Evidence

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
