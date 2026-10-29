# Contributing

Build with `./scripts/build.sh`, run `./scripts/test.sh`, and validate the website with `python3 scripts/check-website.py` and `node --check website/dist/app.js`. All new code is MIT licensed; preserve upstream and vendored notices.

Keep device I/O out of SwiftUI views. Report actual read-back, leave unknown state unknown, and gate controls by capabilities. Never try V2 commands on V1 devices: opcode `0x22` is a V1 power-off command. A transport test is not hardware validation.

Add literal packet regressions for protocol changes and describe their source. Test malformed, fragmented, and unsolicited frames. Preview and replay must never start Bluetooth, run scene automation, or write to headphones.

The website is buildless and accessible without external services. Keep keyboard navigation, labels, reduced motion, narrow layouts, and clearly marked sample data intact. Use `website/dist` as the public document root, not the repository root.

Before a release, run tests, package on each architecture, verify checksums and code signatures, launch the bundle, and record what was actually verified. Ad-hoc signing is not notarization. Never add Apple signing credentials or captured device reports to Git.

Upstream provenance is in THIRD_PARTY_NOTICES.md. Keep changes focused and explain behavior, verification, and remaining hardware limitations in pull requests.
