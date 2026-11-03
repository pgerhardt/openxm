# Experimental XM3 codec transport

This unreleased feature adds a Preferred codec menu to My Device → Audio
Connection: Automatic (macOS), SBC, AAC, aptX, aptX HD and LDAC. Automatic uses
the normal macOS audio stack. Custom selections use a separate helper and
OpenXM Headphones, a virtual Core Audio output. Audio is encoded locally and
sent over the Mac's built-in Bluetooth radio; no recording is saved.

For comparison, Apple's Bluetooth AAC typically runs at about 256 kbps, as
described in [Archimago's AAC measurements](https://archimago.blogspot.com/2023/08/).
LDAC High uses 909 kbps at 44.1 kHz or 990 kbps at 48 kHz, about 3.5–3.9 times
that bitrate. The AAC figure is an approximate reference; OpenXM does not measure
the native macOS AAC bitrate in Automatic mode. LDAC Auto can select lower rates.

Preferred codec is saved per headphone, including Automatic. After a new launch,
OpenXM restores a saved custom choice once the same headphones have a live,
initialized XM3 control connection and the audio driver is available. It does not
connect absent headphones. Quit, sleep, disconnect and transport failure preserve
the preference; explicitly choosing Automatic replaces it. The menu shows the
saved choice, while negotiated codec and session status still require live evidence.
After a stopped/failed session, **Use saved codec** offers a manual retry.

Audio Connection keeps the codec, actual rate and bitrate visible. **Advanced**
contains sample-rate/LDAC controls, route/volume/control status and delay details:

- Sample rate: Auto (current Mac output), 44.1 kHz or 48 kHz. Auto does not inspect
  a track's source rate; macOS resamples as needed. A rate change reconfigures the
  stream and can briefly interrupt sound.
- LDAC quality: Auto, High, Medium or Low. Fixed targets are 909/606/303 kbps at
  44.1 kHz and 990/660/330 kbps at 48 kHz. They disable LDAC bitrate adaptation;
  the live packet-throughput meter can still vary.
- Auto retry backoff: Conservative (30–300 s, default) or Fast (1–5 s,
  experimental). This changes only the wrapper's additional failed-probe delay.
  Sony's own clear-queue observation windows and penalties still apply, so Fast
  does not promise recovery within five seconds. Guard time advances with encoded
  audio; carried state is clamped to the chosen policy when recreating an encoder.

These advanced choices also persist and apply to the restored codec. Each live change
has a revision; old same-codec status cannot confirm a newer selection. The helper
reports ready only when the requested rate and encoder settings match the active
configuration. Fixed LDAC quality changes can swap the encoder without Bluetooth
renegotiation.

Advanced-controls validation (build 202610301538): 18 Swift codec/audio/lifecycle
tests, seven volume/AVRCP tests and three real-encoder/settings tests passed. The
encoder tests exercise all six fixed LDAC configurations under synthetic backlog
and confirm actual first-failure backoffs of 1 versus 30 seconds, with carried
state capped at 5 versus 300 seconds. Live UI checks on the XM3 confirmed all six
fixed targets, both Auto policies, and switching 44.1 → 48 → 44.1 kHz. Independent
Core Audio reads matched each rate. The UI withheld stale settings while changing,
and volume stayed linked at AVRCP 42/127 (33%) throughout the controls check.
Playback was paused, so this does not establish audible quality or compare Fast
and Conservative recovery on the actual radio link. That check restored aptX HD,
Auto sample rate (44.1 kHz), Auto LDAC quality and Conservative backoff.

Live-playback follow-up on the same build exercised all six fixed targets:
909/606/303 kbps at 44.1 kHz, then 330/660/990 kbps at 48 kHz. Each fixed mode
played for approximately 20–50 seconds; the confirmed encoder targets stayed
fixed while measured packet throughput varied. Core Audio independently reported
48 kHz and linked volume stayed at AVRCP 42/127 (33%). The user heard a couple of
skips/crackles in an unidentified mode, with most modes sounding fine.

This was not a clean stability pass. During the 44.1 kHz High/Medium interval,
capture drops rose to 187,512 frames (about 4.25 seconds), with substantial socket
backpressure. Sony controls briefly disconnected and recovered automatically.
The streamer's separate dropped-sample and write-failure counters remained zero;
those counters alone therefore do not establish uninterrupted playback. Capture
drops did not increase during the subsequent Low interval. All three fixed
48 kHz intervals showed zero capture drops, streamer drops and write failures,
but this sequential observation does not prove that 48 kHz is more reliable.

After switching from fixed High to Auto/Conservative at 48 kHz, the encoder fell
to 330 kbps, logged a 30-second retry guard and accumulated 6,288 capture drops
(0.13 seconds). Fast Auto then ran for about 54 seconds: initially 660 kbps,
later 492/396 kbps, with no additional capture drops or write failures. Changing
policy recreates the encoder, and this was not a controlled congestion/recovery
comparison; it does not establish that Fast is superior or recovers within five
seconds. Conservative remains the default. The follow-up restored aptX HD,
Auto sample rate at 44.1 kHz, Auto LDAC quality and Conservative backoff, with
playback and linked volume intact.

## Evidence as of 2026-10-30

Host: Apple silicon, macOS 26.6.2 (25G83). Headphones: WH-1000XM3, international
firmware 2.0.0. Tests below describe this combination, not all macOS releases.

| Check | Evidence |
| --- | --- |
| All five codecs advertised | Live AVDTP discovery returned SBC, LDAC, aptX HD, aptX and AAC |
| Offline encoders | All 12 codec/sample-rate combinations passed packet-size/encoding checks; aptX encode/decode round trip passed |
| LDAC connection | SET_CONFIGURATION, OPEN and START accepted, 44.1 kHz stereo |
| LDAC listening | User reported normal audio; 53.1 seconds of audio transmitted, 6,290 packets, no write failures or dropped PCM samples |
| Adaptive LDAC bitrate | Settled at nominal 606 kbps at 44.1 kHz after congestion at 909 kbps; packet overhead is separate |
| Sony control coexistence | Existing OpenXM control link reconnected and independently reported LDAC, battery and settings |
| Automatic handback | CLOSE accepted, native reconnect requested, original output restored; existing OpenXM then reported AAC / 44.1 kHz stereo |
| Latency | XM3 reported 150 ms via AVDTP DELAY_REPORT. Driver advertises a fixed upstream 250 ms estimate. Neither is an end-to-end measurement |
| Integrated dropdown | All five negotiated at 44.1 kHz stereo; the UI cleared confirmation during each transition and showed the accepted codec afterward |
| Listening during switches | User reported normal audio throughout the five-codec cycle, apart from the expected switching gaps |
| Controls during switches | Battery/settings and codec reads remained available after the initial Sony connection was reopened. Build 202610301350 then passed automatic control reconnection on a fresh LDAC takeover after correcting IOBluetooth's stale connected-flag check |
| Integrated Automatic restoration | Custom helper exited, its route journal was removed, Sony controls reconnected automatically and native AAC / 44.1 kHz stereo showed Headphones in use. Headphone volume remained 8 |
| Video lip sync | User reported synchronized talking-head video during a confirmed LDAC session. This is a subjective pass for that player/video, not an end-to-end latency measurement or a guarantee for other players |
| Manual call handoff | Returned from LDAC to Automatic; user activated the XM3 mic. Final build 202610301352 showed mic In use and 16 kHz mono, with Sony controls connected. Releasing the mic returned to AAC / 44.1 kHz stereo and mic Not in use |
| Untested scenarios | Physical power-off/link-loss recovery and forced helper termination on hardware; end-to-end latency and an actual network call. Crash/normal-stop lifecycle tests use a fake helper |

The initial LDAC test used the standalone helper before UI integration. Raw
development logs are local in `.work/codec-prototype`; they are not shipped.
The integrated test used app build 202610301343. Its in-app transport diagnostics
recorded these intervals (the LDAC row is a running snapshot):

| Codec | Audio sent | Packets | Dropped PCM samples / write failures |
| --- | ---: | ---: | ---: |
| SBC | 24.5 s | 1,206 | 0 / 0 |
| AAC | 16.0 s | 691 | 0 / 0 |
| aptX | 39.8 s | 1,968 | 0 / 0 |
| aptX HD | 25.1 s | 1,879 | 0 / 0 |
| LDAC | 30.0 s | 3,230 | 0 / 0 |

SBC targeted 328 kbps, AAC's VBR peak was constrained by the media MTU to about
304 kbps, aptX used 352.8 kbps and aptX HD used 529.2 kbps. LDAC adapted between
363 and 909 kbps during this pass; no fixed high bitrate is promised. Socket
backpressure occurred (especially LDAC) without reported PCM loss/write failure;
those counters do not measure audible quality or end-to-end delay. aptX delay
reports varied from 97.7 to 187.4 ms; other observed initial reports were 150 ms.
A user-issued headset Next command was forwarded to macOS successfully.

Automated validation: all 279 tests in 41 suites passed after integration; the
11 codec/presentation/lifecycle tests passed again after the reconnect correction.
Release builds and app signature verification passed. The later live-bitrate
addition passed 13 targeted tests, including measured/target separation, invalid
and missing values, idle zero, and clearing on switch/stop/crash. Firmware and
history preferences were not changed during codec validation.
The five-codec/call test ended in Automatic, native AAC / 44.1 kHz stereo, mic inactive,
with no custom helper running or pending route journal. The native call volume
temporarily reported 6 and returned to music volume 8 without an app volume write.

Live-bitrate follow-up (build 202610301359): Automatic displayed bitrate unavailable.
After an authorized restart/reconnect, LDAC showed 0 kbps while paused and a
606 kbps encoder target. On user-resumed playback the card showed 931 kbps with
a 909 kbps target, then 618 kbps with a 606 kbps target as the encoder adapted.
Sony controls remained connected. The user-selected LDAC session was left running.

## Behavior and limitations

- A requested codec is distinct from the negotiated codec. Custom selection is
  strict: a rejected or unusable codec ends the session and hands audio back to
  macOS. UI confirmation requires an accepted START, not a selected preference.
- Custom mode shows live media throughput averaged over approximately one second
  and the encoder's current target (AAC VBR uses a peak). The target is sampled on
  the encoding queue and follows adaptive changes, not the initial configuration.
  Throughput includes media packet headers; it excludes lower Bluetooth framing
  and retransmissions. It is not Spotify's source bitrate. Idle shows zero and
  transitions clear old readings. Automatic explicitly reports bitrate unavailable.
- Installation requires administrator authorization and briefly restarts all Mac
  audio. Building does not install the driver. The driver has an OpenXM-specific
  identity and does not overwrite Blue Bloom.
- Custom volume is linked through AVRCP absolute volume. The first headphone
  report initializes the virtual slider without sending the Mac's remembered
  level to the headphones. The virtual output starts silent and becomes audible
  only after this synchronization and successful codec negotiation.
  Mac changes are serialized/coalesced and require accepted replies within two
  seconds. Hardware mode removes the second software attenuation; mute remains
  local. Lost volume control returns to Automatic. In custom mode, the app slider
  uses the same helper/HAL/AVRCP path and displays a percentage from the accepted
  0–127 volume. It never derives that percentage from Sony's separate 0–30 scale.
  Automatic retains Sony's control-protocol slider. Offline tests include 40
  consecutive acknowledged writes without losing the notification subscription,
  app-command forwarding, and rejecting stale or invalid volume evidence.
  Driver version 6 was installed after administrator authentication and its
  installed CDHash matched the staged build. Initial LDAC verification passed:
  Core Audio reports OpenXM Headphones, hardware-volume mode 1, and scalar
  0.25984251 (AVRCP 33/127); Sony's independently read volume stayed at 8/30.
  The app shows Linked to headphones. The user then selected aptX HD and moved
  the Mac slider: Core Audio read 0.44094488 (56/127), Sony independently reported
  14/30, and streaming remained active at 536 kbps with controls connected.
  The initial reverse check exposed that Sony acknowledged MDR SET volume 8 but
  still returned 14 on all three reads. The app slider was then changed to use
  the acknowledged AVRCP path directly. Build 202610301521 passes seven offline
  volume/AVRCP tests and 15 Swift codec/audio tests. After relaunch/reconnection,
  LDAC initialized the app and Core Audio at 33% (AVRCP 42/127), with hardware
  volume enabled. The user confirmed app-slider changes now stick, both sliders
  follow, and the error is gone. Final independent reads matched: app 38%, Core
  Audio scalar 0.37795275 (48/127), hardware mode 1. LDAC remained active at
  614 kbps measured / 606 kbps target with Sony controls connected. Physical
  headset gestures and live failure recovery were not exercised in this check.
- The custom session owns A2DP/HFP/AVRCP interfaces. The headphone microphone is
  unavailable. Return to Automatic before calls. Automatic call detection is not
  reliable when the headset input itself is absent; no automatic handoff is claimed.
- Output recovery (unreleased): the helper journals the previous output and an
  available fallback, then selects the silenced virtual output before the initial
  Bluetooth takeover. This protects the native-to-custom switch from speaker
  bursts. Negotiation and headset volume confirmation are still required before
  custom audio becomes audible. Codec/sample-rate changes retain that output;
  they never invoke speaker fallback just because the stream is reconfiguring.
- A terminal audio failure starts a three-second grace period. After Bluetooth
  cleanup, recovery prefers the original available physical output, then the
  remembered speaker/wired output, then built-in speakers, then another available
  physical wired output. Unrelated wireless and virtual outputs are excluded.
  An explicit return to Automatic allows up to ten
  seconds for the original output to return before falling back. Output selection
  never changes the destination's volume or mute. The app and menu bar report the
  chosen output. A Sony control-channel disconnect alone does not trigger recovery.
- Pause on unexpected loss (unreleased): before returning audio to speakers, the
  helper runs a bounded check through the bundled media adapter. It reads only
  Now Playing process identity/playback state, verifies an active output exclusively
  through OpenXM's virtual device, rechecks identity/routing, and sends explicit
  Pause once. A fresh paused state from the same player is required for success.
  Already-paused players, absent players, and players routed elsewhere receive
  no command. Successful codec switches, manual output changes, Automatic, quit
  and sleep do not request Pause; a failed switch that terminates audio does.
  Reconnection never sends Play.
- The media check has a four-second deadline and its child process a five-second
  limit. Unknown state, a rejected/ignored command or an unverified pause retains
  silence with a **Restore audio anyway** action in My Device and the menu bar.
  This explicit action restores an available output without changing its volume.
  A journal flag protects an in-progress/failed pause check from automatic crash
  recovery. Choosing another output manually always relinquishes ownership.
  Players that do not publish Now Playing state, including some browser players,
  cannot be automatically paused. The private command targets macOS's current
  Now Playing player; identity is checked immediately before and after, but macOS
  provides no atomic public API to bind this command to an arbitrary process.
- Initial connection and reconfiguration have independent helper deadlines of
  45 and 35 seconds; repeated status reports do not extend them. Shutdown has a
  20-second helper bound. Actual recovery time can include Bluetooth teardown,
  not just the three-second grace period. A failed codec switch follows the same
  terminal recovery policy; custom audio does not restart automatically in that run.
- Default-output notifications and polling relinquish ownership after an observed
  output change. Recovery rechecks ownership before each write and leaves a user's
  chosen output alone. Dead-helper recovery uses the same fallback policy and
  process lock. If no usable physical output exists, the journal is retained and
  the UI asks the user to choose an available output. If both app and helper die,
  recovery runs when OpenXM is next launched.
- Route policy has offline tests for power-off, reconnection, codec deadlines,
  native handback, user changes, remembered/unavailable outputs, failed writes and
  crash journals. Physical power-off, battery exhaustion and speaker-burst checks
  for this recovery change are still pending.
- Saved-codec restoration runs at most once per headphone per launch, only after
  initialization and outside firmware/settings work. Recovering a leftover route
  journal cancels automatic restoration for that launch, including after a blocked
  pause is explicitly overridden. Failures and manual output choices do not cause
  retry loops. Firmware operations require Automatic first. History and firmware
  preferences are untouched.
- Private Bluetooth interfaces can break with OS updates. Lower host buffering
  cannot remove the headset's own buffering. Video compensation depends on the
  player; the fixed driver estimate is not proof of lip sync.

## Development

`scripts/build-codec-transport.sh` builds the Objective-C helper, a developer-only
codec test executable, replaceable libfreeaptx.dylib and OpenXMCodec.driver.
`scripts/build.sh` packages and signs them with the app, including all licenses.

Offline tests (no audio playback, Bluetooth connection, driver install or route change):

```sh
scripts/build-codec-transport.sh
scripts/test-codec-volume.sh
scripts/test-codec-settings.sh
scripts/test-codec-routing.sh
scripts/test-disconnect-pause.sh
build/CodecTransport/CodecTests codectest
build/CodecTransport/CodecTests selftest
build/CodecTransport/OpenXMCodecTransport --inspect
swift test --filter 'CodecSelectionTests|CodecTransportLifecycleTests|AudioConnectionTests'
```

The parent/helper protocol uses JSON lines and fresh process generations.
`--stream ADDRESS CODEC JOURNAL [SETTINGS_JSON]` is disruptive and must be an explicit user action.
stdin EOF, a stop command and SIGTERM all request native handback. A journal and
process lock prevent simultaneous ownership. `--recover JOURNAL` only restores a
previously owned virtual route, uses an available physical fallback if necessary,
and refuses to interrupt a live owner. An unfinished/failed pause check keeps the
route protected; only an explicit **Restore audio anyway** action passes
`--allow-playing` to bypass that protection. Recovery never resumes media.

The administrator installer validates the driver's signing hash before replacing
only `/Library/Audio/Plug-Ins/HAL/OpenXMCodec.driver`. To remove it after returning
to Automatic, run `sudo scripts/install-codec-driver.sh --uninstall`; removal also
restarts Mac audio.

## Provenance

Engine/driver based on Blue Bloom v0.1.2 at
`7a9ab6c97d3a575f9d474dec1e636003e8999cca`, MIT. See
[the import record](../Vendor/BlueBloom/OPENXM-PROVENANCE.md) and
[third-party components](../Vendor/BlueBloom/third_party/README.md).
LDAC/SBC are Apache-2.0 and libfreeaptx is LGPL-2.1-or-later; its full source is
included and it is dynamically linked. AAC uses AudioToolbox.
