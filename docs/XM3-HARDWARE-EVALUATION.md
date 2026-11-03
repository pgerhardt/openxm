# WH-1000XM3 hardware evaluation

## 2026-10-30: live audio connection display

Signed build `202610301245` adds an Audio Connection card under My Device. On the connected international WH-1000XM3 2.0.0, the native UI showed headphone-reported **AAC**, a matching active Mac output at **44.1 kHz / stereo**, and **headphone mic not in use**. The system default input was nevertheless WH-1000XM3, confirming why default-input selection alone must not be treated as active microphone use. The user was playing Spotify; no playback, volume, routing or microphone command was sent. The user's volume was 10 on reopening, and that value was preserved. Both local history files remained absent.

The reader queries Core Audio device/stream/process properties without capturing audio. Exact Bluetooth UID matching binds input and output to the selected headphones. A running input process must actually use the matching input device. Unknown process/property reads remain unknown. Low-rate mono output (at most 24 kHz) plus active headphone input is labeled **likely** hands-free mode, not proof of an HFP speech codec. AAC/aptX/aptX HD/LDAC labels remain headphone-reported music codecs; local PCM sample rate is not evidence of Bluetooth bitrate, wireless bit depth or source resolution.

Read-only Mac checks run every two seconds; supported codec GETs share the serialized headphone control link every ten seconds and respect update/settings reservations. Five regression tests cover exact identity/direction, active vs selected input, unknown readings, conservative call-mode inference and both codec reply families. The full fixture-enabled suite passed **273 tests in 39 suites**; the signed release, native card and expanded explanation were checked. A subsequent user-controlled Voice Memos check verified the microphone transition in both directions: enabling the XM3 mic changed the Mac output to **16 kHz mono**, set the mic to **In use**, displayed the **Call audio** badge and the hands-free warning; stopping and closing Voice Memos returned **44.1 kHz stereo**, **Not in use**, the **AAC** badge and cleared the warning. AAC remained the reported music codec during microphone use, so it must not be presented as the speech codec. This confirms the transition with Voice Memos; Zoom itself and the exact HFP speech codec were not inspected. The user controlled recording and volume throughout; OpenXM made only read-only diagnostic queries.

Sources: [Apple's explanation of reduced Bluetooth quality during microphone use](https://support.apple.com/en-us/102217), [Sony's XM3 music codecs](https://helpguide.sony.net/mdr/wh1000xm3/v1/en/contents/TP0001703175.html), and [Spotify's source-quality and connection limitations](https://support.spotify.com/us/article/lossless-audio-quality/). The installed Core Audio SDK documents the virtual stream format as the local IO format and process device lists as scoped input/output routes. These do not expose the negotiated speech codec in this implementation.

## 2026-10-30: remaining 2.0.0 preset and power matrix

Signed build `202610301203` was checked against the connected international WH-1000XM3 2.0.0, with playback paused. The existing authorization covered reversible settings checks and restoration. A fresh native all-slot backup was saved before testing as `.work/xm3-before-remaining-core-matrix.json`. This baseline has the user's current volume **13/30**; older reports' volume values were not reapplied.

| Check | Physical result |
| --- | --- |
| VPT | Off → each of Arena, Club, Outdoor Festival and Concert Hall → Off; all selections returned the requested value. |
| Sound position | Off → each of Front Left, Front Right, Front, Rear Left and Rear Right → Off; all selections returned the requested value. |
| EQ selection | All twelve advertised selections were read: Off, eight factory presets, Manual, Custom 1 and Custom 2. Every non-Off selection was followed by Off. The factory curves, including negative bands/Clear Bass, displayed correctly. No band values were written. |
| Automatic power off | 30 minutes → each of 5 minutes, 1 hour, 3 hours and Don't turn off → 30 minutes; all selections returned the requested value. The Never reply was `F7 04 01 11 01`: its final byte retains the 30-minute timer, while the selected option is Never. Actual timed shutdown was not tested. |
| Connection quality | Sound Quality → Stable Connection confirmed. A fresh backup review identified the difference; all other restore selections, including volume and EQ, were unchecked. Restore Selected returned to Sound Quality, reported confirmation and completed its independent final read. No control-channel disconnect or headset restart occurred in either direction during this paused test. Reconnect/power-cycle behavior remains unverified. |

A fresh all-slot read/export after testing, `.work/xm3-after-remaining-core-matrix.json`, matches the original baseline exactly after removing only `createdAt`: all nine saved settings and every custom curve. Hashes and comparison results are in `.work/core-matrix-restoration-verification.json`. ANC, EQ Off, original curves, VPT/position Off, DSEE on, 30-minute power-off, Ambient button assignment, Sound Quality and volume 13 were preserved. Both history files remained absent and the saved scenes hash was unchanged. The app was returned to My Device, connected, with playback paused.

Native raw protocol exports are `.work/xm3-core-matrix-eq.txt`, `.work/xm3-core-matrix-effects.txt` and `.work/xm3-core-matrix-power-connection.txt`. They are private local evidence. `Tests/OpenXMTests/Fixtures/xm3-2.0.0-core-matrix.json` preserves 27 unchanged SET/RET pairs for public settings, with no identifiers, media, battery, calibration or personal custom EQ curves. Each pair was matched to a subsequent RET before another SET for the same setting. Four replay tests cover every effect/position, the full signed factory EQ curves, the retained-timer Never reply and both connection priorities.

The UI's connection-quality copy now says that changing it **may** reconnect, rather than promising a disconnect that did not occur here. These checks establish settings read-back and selective connection-quality restoration. They do not establish audible effects, power-cycle persistence, all other backup restoration paths, firmware 4.5.2 behavior or full Sony-app parity. No playback/volume command, ambient-preference change, optimizer run or firmware installation was performed.

Final signed release `202610301220` passed native inspection of the revised row and confirmation text; the confirmation was cancelled without another setting write. All three history recording switches remained off, with zero song intervals. The full fixture-enabled suite passed **268 tests in 38 suites**; signature verification and `git diff --check` passed. The release was left connected on My Device with AAC, ANC, EQ Off, DSEE on, volume 13 and playback paused.

## 2026-10-30: Find Your Equalizer on 2.0.0

Native builds `202610301022` and `202610301028` were exercised on the same connected international WH-1000XM3. A fresh all-slot settings export was saved before testing (`.work/xm3-before-equalizer-guide.json`). The guide successfully captured every original curve, applied a balance choice to Manual, switched back to the original Off setting, and cancelled with verified restoration of the complete EQ bank.

A complete second run selected balance Sound 3, bass Sound 4 and detail Sound 2. Back navigation and original/result switching were checked. Save confirmed Custom 2 with bands `[-1, 0, 0, 1, 1]` and Clear Bass `1`. A fresh independent bank capture at the start of the next session confirmed that result, Manual remained flat with bass 0, and Custom 1 remained `[5, 3, 1, 3, -1]` with bass 4. That capture is preserved in `.work/xm3-equalizer-guide-after-save.json` (includes a private device address; not a public fixture).

For recovery, Sound 2 was applied to Manual, then the app process was terminated while the guide was idle, with no request in flight. On relaunch, the original bank was recovered from disk, other headphone settings and scenes stayed disabled, and Settings exposed Restore Original EQ. The quit warning was also displayed and dismissed with Keep OpenXM Running. Restoration completed with a fresh read and full-bank verification, returning to the Custom 2 setting that preceded this session. This establishes physical app-restart recovery after an idle audition, not recovery from a power loss or disconnect during a write.

The pre-test EQ bank was then restored through an EQ-only settings restore. After relaunching final signed build `202610301032`, a new all-slot export (`.work/xm3-after-equalizer-guide.json`) matched the pre-test backup exactly after removing only `createdAt`: all nine settings and every curve. The comparison and file hashes are recorded in `.work/equalizer-guide-restoration-verification.json`. No EQ recovery file remains. Final state is ANC, EQ Off, original Manual/Custom 1/Custom 2 curves, DSEE on and volume 8/30; the app is connected on the Sound page. A follow-up UI fix keeps connection status distinct from write availability and exposes a recovery banner across pages.

No music was started, volume changed, calibration run or firmware installed. These are UI and device read-back checks; audible preference quality and firmware 4.5.2 remain unverified. Eight new tests bring the full suite to 225 tests in 32 suites; failure tests cover partial captures, unconfirmed writes and interrupted saves. The comparison curves are independently designed, with no claim to reproduce Sony's proprietary algorithm.

## 2026-10-30: international firmware 2.0.0

The user made the headset available and explicitly authorized reversible button, sound-effect, EQ and core-setting checks with the headphones off their ears. Firmware installation and playback/volume changes were excluded. A read-only probe at 08:14 MDT identified WH-1000XM3 firmware **2.0.0**, protocol **V1 0x4000**, AAC and 100% battery. The corrected firmware identity view subsequently read **HP001 / MDRID291600** directly from the connected headset. Sony's live metadata listed 4.5.2 as the update target from 2.0.0; no installation was started.

The native 2.0.0 capability list contains Ambient Sound Control and Google Assistant for the NC/AMBIENT button. It does not advertise Alexa, the later touch-panel toggle or voice-guidance controls. VPT and Sound Position Control are advertised and readable. `Tests/OpenXMTests/Fixtures/xm3-2.0.0-public-replies.json` preserves 28 unchanged, filtered receive payloads with no device address/unique ID, media, battery or measured calibration results. The original local probe report is `.work/xm3-live-parity-readonly.txt` and contains device identifiers; it is not a public fixture.

| Hardware check | Observed result |
| --- | --- |
| Button assignment | Ambient Sound Control → Google Assistant → Ambient Sound Control; accepted the headset's prompts and verified each selection after the actual Bluetooth restart. Repeated on corrected build `202610300837`. |
| VPT surround | Off → Arena → Off, with fresh device read-back. Other advertised presets were not individually exercised. |
| Sound Position Control | Off → Front → Off, with fresh device read-back. Other positions were not individually exercised. |
| DSEE HX | On → Off → On; the processing indicator returned after effects/EQ were turned off. No audio-quality measurement. |
| Automatic power off | 30 minutes → 1 hour → 30 minutes; actual timed shutdown not exercised. |
| EQ presets | Off → Bright → Off, with the reported Bright curve displayed. |
| Manual EQ | 400 Hz 0 → 1 → 0 and Clear Bass 0 → 1 → 0; returned to Off. |
| Custom 1 and Custom 2 | Temporarily incremented each slot's 400 Hz band, confirmed that the selected slot stayed unchanged, then restored its original value. Custom 1's non-flat curve and bass were preserved. |
| All-slot backup and restore | Captured Manual/Custom 1/Custom 2, returned to Off, then restored the saved EQ bank after a deliberate one-step Manual change. Only EQ was selected for restoration. The restore completed with device confirmation and final verification. A separate full read/export matched all nine original saved settings and every curve exactly, excluding the timestamp. |

The original and post-test files are `.work/xm3-2.0.0-before-hardware-checks.json` and `.work/xm3-2.0.0-after-hardware-checks.json`. These are actual device setting backups, not synthetic fixtures. Ambient level/voice changes were deliberately left untested because ANC does not expose the saved inactive ambient preference. NC Optimizer, playback, volume, connection priority and firmware installation were not changed. Audible effects, physical assistant-button operation, phone activation, timed shutdown, sleep/wake and power-cycle persistence remain unverified. These results do not establish the same behaviors on firmware 4.5.2 or V2 devices.

The live session exposed and fixed three app issues: an expected disconnect could precede the confirmation ACK and display an error; refreshing a restore review reselected unchecked settings; and the firmware identity checker unnecessarily closed a working control connection and timed out reopening it. Build `202610300837` arms expected reconnection before sending known restart confirmations, preserves explicit restore selections, and requests fresh identity on the current exclusive channel when available. Installation keeps its separate connection and identity checks. The complete suite passes **209 tests in 30 suites**; the signed build and whitespace checks pass without compiler warnings.

Final native retest of `202610300837` confirmed the informative reconnect message in both assignment directions, the correct assignment after each reconnect, a successful fresh international firmware identity read and Sony's 2.0.0 → 4.5.2 metadata rule. An EQ-only selection stayed EQ-only after Review; volume and the seven other settings remained unchecked. The final independent all-slot export, `.work/xm3-2.0.0-final-build-202610300837.json`, again matched the original backup exactly after removing only `createdAt`. OpenXM was left connected in My Device with ANC, EQ Off, DSEE on and volume 8. Build/test logs are `.work/live-xm3-final-build.txt` and `.work/live-xm3-final-tests.txt`.

## 2026-10-29: firmware 4.5.2 baseline

Tested 2026-10-29 on a physical WH-1000XM3, firmware **4.5.2**, with macOS **26.6.2 (25G83)** on Apple silicon. Sony control protocol **V1, 0x4010**, RFCOMM channel 15. Battery reported **100%** in both macOS and OpenXM; codec reported **AAC**.

Source baseline: `d5042a200fda6f12a2e473d14a7a0ffe44e3d884`. Initial bundle: `202610291144`. Fixed local bundle: `202610291358`, with the V1 noise transition change described below. This change is not part of the published 0.2.0 release.

## Results

The initial exercise produced **22 passes and 1 failure**. After fixing the Off-to-active noise transition, the same physical-headphone exercise produced **23 passes and 0 failures**. These counts include restoration steps and scene checks, not 23 distinct features. All 16 software tests also passed, and the rebuilt app passed signature verification.

Writes below were confirmed by fresh replies from the headphones. Audible effects, physical touch gestures, and timed shutdown were not independently verified by a person.

| Feature | Result | Scope of verification |
| --- | --- | --- |
| ANC, wind reduction, ambient, off | Passed | Switched through all four modes; read-back matched. Off → Ambient passed after the fix. |
| Ambient level and Focus on Voice | Passed | Tested level 10 with voice focus on, then level 20 with voice focus off. Headset advertises levels 1–20. |
| EQ presets | Passed for tested presets | Bright, Manual, and Off selected and confirmed. Custom 1/2 and the other factory presets were advertised but not individually exercised. |
| Five-band EQ and Clear Bass | Passed | Manual first band +2/bass +1, plus a scene curve `[1, 2, 3, 2, 1]` with bass +2. Original Manual curve restored to all zeroes. Advertised range: −10…+10. |
| DSEE HX | Passed | Off/on setting confirmed; final processing indicator reported active. Processing quality was not measured. |
| Auto-off timer | Passed | 30 minutes → 1 hour → 30 minutes. Also advertises 5 minutes, 3 hours, and never. Actual timed shutdown not exercised. |
| Touch Sensor Control Panel | Passed | Disabled and enabled; both returned states matched. |
| Voice guidance | Passed | Disabled and enabled; both returned states matched. |
| Scenes | Passed | Temporary scene applied noise, Manual EQ, curve/bass, and DSEE; 4/4 operations confirmed. Restoring the original scene also confirmed 4/4. No user scenes were saved or edited. |
| Battery, firmware, codec | Read successfully | 100%, 4.5.2, AAC. |
| Playback status and volume | Read successfully; writes untested | Stopped, volume 8/30. Playback and volume were not changed. Track/album/artist requests timed out with no media playing. |
| Connection priority | Read successfully; write untested | Prioritize Sound Quality. Changing it can reconnect the headset. |
| NC Optimizer | Advertised; execution untested | Idle status and pressure value were readable. Calibration tones were not started. |
| Custom button assignment | Gap in OpenXM | XM3 advertises a list setting (`ASSIGNABLE_KEY_SETTING`); the current generic-settings implementation only edits booleans. No assignment was changed. |
| Speak-to-Chat, wearing auto-pause, paired-device management | Unavailable in this session | Not advertised to this driver. |
| Remote power off | Unavailable in OpenXM for this capture | The driver did not recognize a power-off capability. This does not establish that the hardware lacks a remote power command. |

## Noise transition bug and fix

On XM3 4.5.2, effect `0x01` means resume the last active noise mode. The headset ignores new mode/level fields in that command. The failing sequence started with Wind Reduction, switched Off, then requested Ambient 20:

```text
SET 68 02 01 02 00 01 00 14   # request on + ambient 20
RET 67 02 01 02 01 01 00 00   # headset instead resumes wind reduction
```

The driver now reads back the activation and, only if it resumed a different setting, sends an adjustment-completion command inside the same exclusive transaction:

```text
SET 68 02 11 02 00 01 00 14   # commit ambient 20 after activation
RET 67 02 01 02 00 01 00 14   # confirmed ambient 20, voice focus off
```

The full hardware exercise, including the previously failing transition, passed with this change. XM4 and newer models were not retested during this session.

## Final state and limitations

The final state was ANC, Focus on Voice off, EQ Off, Manual curve/bass zeroed as originally stored, DSEE HX on, 30-minute auto-off, touch panel on, voice guidance on, sound-quality priority, and volume 8/30. A separate read-only connection after the exercise confirmed the active settings persisted.

The headset began in ANC and returned zero for the ambient-level field. Its previous saved ambient level was therefore unknown: **the test left ambient level at 20**, the app's fallback. The original active ANC mode was restored. Exact preservation of an unknown saved ambient level cannot be claimed.

The initial Mac connection dropped before diagnostics could initialize. After the user made the headset available, repeated control connections and both exercise runs completed. This is not a long-duration reliability, power-cycle, menu-bar, login-item, or scene-automation test.

Raw captures remain in ignored local `.work/xm3-*.txt` files because they contain device identifiers. This report omits those identifiers and records only the capability and control evidence needed for review.

## Board references and limits

The user's WH-1000XM3 teardown references are [52audio](https://www.52audio.com/archives/31755.html) and [TechInsights DDT-1912-813](https://www.techinsights.com/products/ddt-1912-813). TechInsights' public summary independently identifies the Qualcomm CSR8675, Sony CXD90050 noise-cancelling processor and RC-S967 NFC part, and Cirrus CS47L15/CS48L10 codec/DSP parts. The user's STM32L071CZT6 identification comes from 52audio; its component section was not successfully retrieved in this follow-up. These are board references, separate from this Mac's protocol captures.

[Qualcomm documents GAIA V2 support for the CSR8675](https://www.qualcomm.com/audio/products/csr8675). This supports researching the Qualcomm update path, but does not establish which Sony package partitions target each processor, the board's inter-chip routing, debug access, or arbitrary button reassignment. The captured Sony button list supplies Ambient Sound Control, Google Assistant and Alexa; pairing is not advertised as an assignment. The Mac sends supported assignment changes through Sony's Bluetooth protocol without replacing firmware. New behavior such as pairing on that button would require further command or firmware evidence.
