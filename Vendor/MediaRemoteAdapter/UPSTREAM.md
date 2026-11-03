MediaRemote Adapter by Jonas van den Berg and contributors.

Source: https://github.com/ungive/mediaremote-adapter
Revision: `797729d9b16316dc313844476c153d7a107ca0df`
License: BSD-3-Clause (see LICENSE).

The upstream test client and build system are omitted; scripts/build-mediaremote.sh
builds the helper for the host architecture. Existing local changes add playback
progress/process identity and optional reads without artwork or a title.

OpenXM also compiles Helpers/MediaPause into this framework. The Perl launcher
allows its pause_disconnect entry point, invoked only on terminal custom-audio
failure. It brackets playback-state reads with player-identity checks, verifies
the player's Core Audio output, sends explicit Pause, and verifies paused state.
It uses the existing private MediaRemote wrapper and never sends Play, launches
a player, reads song metadata, or changes volume. The original BSD license and
copyright notices are preserved.
