# Blue Bloom components in OpenXM

Source: https://github.com/jonathanlu98/bluebloom

Pinned revision: `7a9ab6c97d3a575f9d474dec1e636003e8999cca` (v0.1.2).
Imported 2026-10-30: Engine, Driver, third_party, CLI/main.m and LICENSE.
The CLI is built only as a development codec test tool; it is not shipped in OpenXM.
The helper's user-button forwarding adapts the MediaKeys command mapping from
`App/Sources/Services/Services.swift` at the same revision (MIT).
The helper's HAL volume-control discovery/property access adapts
`App/Support/VolumeSync.h` and `VolumeSync.m` (MIT). Its coordinator is changed to
adopt the headphones' initial volume, serialize/coalesce writes, require accepted
volume replies, and return to native audio if synchronization fails.

Blue Bloom's engine and driver are MIT licensed. Preserve LICENSE and the
per-component license/version files in third_party. LDAC and SBC are Apache-2.0;
libfreeaptx is LGPL-2.1-or-later. OpenXM builds libfreeaptx as a replaceable dynamic
library. The complete library sources and build recipe are included here.

OpenXM changes are marked in the affected files:

- Separate driver/device identity so an installed Blue Bloom driver is unaffected.
- Display the virtual output as OpenXM Headphones (driver bundle version 6);
  retain its original OpenXM device UID so saved routes still resolve.
- Disable the upstream guard's automatic changes to system input/output defaults;
  OpenXM owns output routing and never silently chooses a different microphone.
- The driver retains the upstream 250 ms *estimate*. This is not a measurement of
  WH-1000XM3 latency or a guarantee of video synchronization.
- Expose the termination reason and opt-in native handback on stop/failure.
- Notify the helper when audio has actually stopped, before native handback
  completes, so it can clear stale streaming evidence and bound route recovery.
- Report negotiation status during reconfiguration/recovery so the previous
  configuration cannot be mistaken for a currently active stream.
- Publish an atomic encoder-target bitrate snapshot from the streaming queue and
  clear old throughput on resume; clarify that media throughput includes packet
  headers, not lower Bluetooth framing or radio retransmissions.
- Expose bounded AVRCP absolute-volume acknowledgements and their returned values
  so OpenXM never assumes that sending a volume command confirms it. Preserve
  active notification transaction labels across repeated writes and match reply
  command IDs before accepting a response.
- Expose LDAC's existing fixed quality presets and apply requested rate/options
  together. Add a per-encoder Fast backoff option (1–5 seconds) to the wrapper's
  extra failed-probe guard; retain Conservative (30–300 seconds) as the default.
  Clamp carried guard state when changing policies. Sony's ABR queue thresholds,
  observation windows and penalty logic are unchanged.

Private bluetoothd interfaces are experimental and can change with macOS updates.
Compilation and offline encoder tests do not prove hardware compatibility.
