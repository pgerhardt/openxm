# OpenXM

OpenXM is a free, open-source Mac app for Sony XM headphones.

- **LDAC and aptX HD on your Mac.** macOS normally uses AAC at about 256 kbps. OpenXM adds LDAC and aptX HD playback on WH-1000XM3. At its highest setting, LDAC runs at 909 kbps at 44.1 kHz or 990 kbps at 48 kHz—about 3.5–3.9 times AAC's bitrate. See [codec settings and bitrate comparison](docs/CODEC-TRANSPORT.md).
- **Firmware downgrades.** Install older XM3 firmware, including 2.0.0, the version before Alexa support. Some owners prefer its noise cancellation. See [available firmware](docs/FIRMWARE.md).
- **Headphone controls without Sony telemetry.** Configure noise canceling, ambient sound, EQ, and device settings over Bluetooth. OpenXM does not send listening history, location data, or usage telemetry to Sony. Optional listening history and saved places stay on your Mac. No Sony account required.

[Website](https://pgerhardt.github.io/openxm/) · [Download](https://github.com/pgerhardt/openxm/releases/latest) · [Compatibility](docs/COMPATIBILITY.md) · [Contribute](CONTRIBUTING.md)

> Independent community fork of [Open Sound Connect by rolottr](https://github.com/rolottr/open-sound-connect), with its MIT license and credits preserved. Not affiliated with Sony, Apple, or the upstream distribution.

![OpenXM native Mac app, shown with clearly labeled sample data](docs/screenshots/app.png)

## What it does

- **Noise control:** noise canceling, wind reduction, ambient level, and Focus on Voice where the headset supports them.
- **Equalizer:** presets, Clear Bass, and locally saved curves. XM3/XM4 use five bands plus bass. Find Your Equalizer on XM3 guides you through listening comparisons and saves the result to Custom 2; canceling restores your original settings.
- **Sound and device settings:** DSEE, Speak-to-Chat (XM4), wearing detection, automatic power off, and other reported capabilities.
- **Audio connection:** view the codec, sample rate, bitrate, and microphone activity. On XM3, choose SBC, AAC, aptX, aptX HD, or LDAC, or use Automatic for the standard macOS connection. Your codec and quality settings are saved per headphone. Custom codecs use a helper and virtual audio driver; see [setup and details](docs/CODEC-TRANSPORT.md).
- **Scenes:** save combinations of settings and apply them manually, on connection, on a schedule, or when opening an app. [Location scenes](docs/LOCATION-SCENES.md) apply settings when you arrive at or leave a saved place, with your permission.
- **XM3 settings:** NC/AMBIENT button assignment, Surround/VPT, and Sound Position Control. Sound effects can also be saved in scenes.
- **Listening history:** optional playback-time estimates, sessions, charts, and searchable song history. Song recording has its own switch and starts off. See [recording and retention](docs/LISTENING-HISTORY.md).
- **Backups:** export scenes, saved places, listening history, headphone settings, and supported custom EQ slots. Review what to restore before applying it. Backups are local files in OpenXM's format.
- **Menu bar:** quick controls, battery, EQ, and scenes without leaving your current app.
- **Voice language:** view supported languages and download original Sony voice packages. XM3 installation and recovery are experimental; see [voice guidance](docs/VOICE-GUIDANCE.md).
- **Headphone firmware:** install or resume XM3 firmware upgrades and downgrades from Settings. Ten original international, Japanese, and Chinese packages are available. See [firmware instructions](docs/FIRMWARE.md) for supported versions and regions.
- **Mac integration:** keyboard shortcuts, reconnection, optional launch at login, and local Now Playing controls.
- **Audio recovery:** if custom-codec audio disconnects, OpenXM attempts to pause the active player before restoring another output. If it cannot confirm the pause, it asks you to restore audio manually.
- **Activity log:** see which setting changes succeeded, failed, or could not be confirmed.

Features depend on the model and firmware. See [compatibility](docs/COMPATIBILITY.md) and [Sony app feature coverage](docs/SONY-APP-PARITY.md). The website demo uses sample data.

## Install

Requires **macOS 15+**, Apple silicon or Intel, and compatible headphones paired in System Settings → Bluetooth.

The feature list above describes the current source. Codec selection, firmware tools, and other recent additions require a [source build](#build-from-source); they are not included in release 0.2.0.

1. Download the ZIP matching your Mac from [Releases](https://github.com/pgerhardt/openxm/releases/latest): `arm64` for Apple silicon or `x86_64` for Intel.
2. Unzip it and move **OpenXM.app** into Applications.
3. Connect the headphones in macOS Bluetooth settings, open OpenXM, and allow Bluetooth access.

Community builds are **ad-hoc signed, not Apple notarized**. macOS may block a downloaded app. Building locally is the supported alternative; do not disable system security settings. Developer ID signing requires a maintainer's own Apple credentials, which are not included.

## Build from source

Install Xcode or the Xcode Command Line Tools (`xcode-select --install`), then:

```sh
git clone https://github.com/pgerhardt/openxm.git
cd openxm
./scripts/build.sh
open build/OpenXM.app
```

No third-party Swift packages or build-time downloads. Swift 6+, SwiftPM, Apple system frameworks, and a small BSD-licensed vendored media helper. The build script makes the bundle, draws the icon, includes licenses, and ad-hoc signs it. Launch the `.app`, rather than the executable inside it, so Bluetooth permission belongs to the app.

```sh
./scripts/test.sh                  # Protocol, state, preview, playback, updates
./scripts/package.sh               # Architecture-specific ZIP + SHA-256
./scripts/install.sh               # Install to ~/Applications and launch
CONFIG=debug ./scripts/build.sh    # Debug bundle
```

`SDKROOT` can override the selected SDK. The scripts never change `xcode-select` globally. Open `Package.swift` in Xcode for editing.

### Explore without headphones

```sh
open -n build/OpenXM.app --args --demo
```

The persistent **PREVIEW · SAMPLE DATA** banner identifies the built-in sample. Headphone writes, media controls, and scene automation are disabled. Quit and reopen normally to connect. Local scene and preference edits still save to your Mac.

### Run the website

```sh
python3 -m http.server 4173 --directory website/dist
```

Open `http://localhost:4173`. The website is buildless HTML/CSS/JavaScript, with no framework, external fonts, trackers, or runtime dependencies. `python3 scripts/check-website.py` validates internal links and assets; `node --check website/dist/app.js` checks JavaScript syntax.

GitHub Pages publishes `website/dist` on pushes to `main`. A separate private Sites deployment can be used for preview; its manifest is under `website/.openai/`.

## Compatibility

| Model | This project's status |
| --- | --- |
| **WH-1000XM4** | Primary target. The upstream project reports hardware-tested V1 controls on firmware 2.6.0; this fork needs its own hardware pass. |
| **WH-1000XM3** | Core controls tested on firmware 4.5.2: noise modes, EQ, DSEE HX, touch panel, voice guidance, auto-off settings, and scenes. Requires the local Off-to-active noise fix, not yet in release 0.2.0. See the [hardware evaluation](docs/XM3-HARDWARE-EVALUATION.md) for exact coverage and limitations. |
| **WH-1000XM5 / XM6** | Experimental inherited V2 implementation; not hardware verified here. |
| Other Sony models | No compatibility promise. Controls appear only for reported capabilities. |

Tests and a successful build do **not** establish physical-headphone compatibility. See [the hardware checklist](docs/COMPATIBILITY.md) before reporting a model as verified. XM3 has no Speak-to-Chat. Model and firmware differences matter.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘1–⌘5 | My Device, Sound, Scenes, Settings, Activity |
| ⌘K / ⇧⌘K | Connect / disconnect controls |
| ⌘R | Refresh status |
| ⌃⌘1–⌃⌘9 | Apply a scene |
| ⌘, | Preferences |

Closing the window keeps OpenXM in the menu bar when enabled. Use ⌘Q or Quit to stop it and its automations.

## Privacy

Sony's [Sound Connect privacy policy](https://policies.songpal.sony.net/headphones/pp/na/20241001/pp/hpc_pp_na_en.html) describes collecting listening details, including song titles, artists, and timestamps, and using them for listening history and a usage profile when Listening History is enabled. OpenXM configures the headphones locally, without sending Sony listening history, location data, or usage telemetry. Its optional history and saved places stay on your Mac.

Headphone communication is local Bluetooth. Scenes live in `~/Library/Application Support/SoundConnect/scenes.json`; preferences use the separate `io.github.pgerhardt.SoundConnect` defaults domain. The storage names are internal identifiers from early development. This fork does not overwrite the original upstream app's preferences or scenes.

Update checks are **off by default**. If enabled, the app reads the public GitHub Releases API for `pgerhardt/openxm` at most daily, without sending headphone data. Manual update checks use the same endpoint. No automatic download or installation occurs.

Headphone firmware checks and downloads are separate, explicit actions. They read Sony's public metadata and packages for the selected XM3 region, or the pinned MDR Proxy GitHub archive for international 2.0.0, without sending device identifiers or credentials. Verified packages are cached under `~/Library/Application Support/SoundConnect/Firmware`. Installation requires a further confirmation and live device checks.

Now Playing reads local macOS metadata with the bundled MediaRemote Adapter. Track details are saved only when the separate song-history option is enabled; daily/session history does not enable it. The helper uses a private macOS interface and may break after OS updates. Diagnostics can contain Bluetooth addresses and media metadata: redact before sharing.

## Troubleshooting

- Connect the headphones to macOS first; audio and the app's RFCOMM control connection are separate.
- If Bluetooth was denied, enable OpenXM in System Settings → Privacy & Security → Bluetooth, then reopen.
- Close other headphone control apps if the control channel is busy.
- Check Activity when a setting is unavailable or a write fails. Do not interpret an unconfirmed change as success.
- Use a read-only report when filing a hardware issue:

```sh
open -n -W build/OpenXM.app --args --probe --out "$HOME/Desktop/openxm-probe.txt"
```

Close the regular instance first. Replay a report locally with `--replay /absolute/path/to/report.txt`; the replay banner clearly marks it as non-live. Do not post an unredacted report.

## Open-source foundation

This project is built on the substantial work in [Open Sound Connect](https://github.com/rolottr/open-sound-connect). [SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge) and [Sony Device Center](https://github.com/marconvcm/sony-device-center) informed the protocol review and regression fixtures. The app is native Swift/SwiftUI using IOBluetooth; the website is plain web technology. Blender sources for the headphone illustration are included.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for exact upstream revisions, authors, modifications, and licenses. Released under [MIT](LICENSE); the media helper retains its BSD-3-Clause license.
