# Releasing SoundConnect

1. Update `CFBundleShortVersionString` in `Resources/Info.plist` and document meaningful changes.
2. Run `./scripts/test.sh`, `./scripts/package.sh`, `python3 scripts/check-website.py`, and `node --check website/dist/app.js`.
3. Verify `codesign --verify --deep --strict build/SoundConnect.app` and the ZIP's SHA-256 file.
4. Inspect a native launch, menu bar, and the disconnected state; use `--demo` for a labeled offline preview. Record hardware verification separately.
5. Commit and push. The macOS workflow tests and packages Apple silicon and Intel independently.
6. Download the successful workflow's two architecture artifacts. Create a GitHub release at the exact tested commit with the ZIPs and checksum files. Do not relabel a binary built from another commit.

The app deliberately has no signing credentials. Ad-hoc signatures are useful for local integrity checks, but do not satisfy Developer ID/Gatekeeper distribution trust. A future notarized release requires the maintainer's own Apple Developer account, certificate, hardened-runtime evaluation, and notarization workflow.

GitHub Pages deploys the buildless website independently. Source links and download destinations point to this fork, never the upstream commercial distribution.
