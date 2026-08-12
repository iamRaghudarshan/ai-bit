# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal, ad-free YouTube client in Flutter, targeting iOS and Android. Stream
URLs are resolved directly from YouTube's player endpoint and handed to a native
player — the web player never loads, which is why there are no ads. Personal use
only; it violates YouTube's ToS and must not be published to a store.

## Commands

**Flutter is not on PATH on this machine.** Use the absolute path:

```bash
D:/flutter/bin/flutter.bat analyze          # must be clean before declaring done
D:/flutter/bin/flutter.bat test
D:/flutter/bin/dart.bat run tool/<script>.dart
```

Single test by name:

```bash
D:/flutter/bin/flutter.bat test test/unit_test.dart --plain-name "compactCount"
```

Tests are pure unit tests (`test/unit_test.dart`) covering formatters and the
`VideoBrief` ⇄ SQLite round trip. They do no I/O and need no device.

### Diagnostics — run these before debugging playback code

YouTube changes its player endpoints every few months, and that breaks the app
without any code change. These scripts hit live YouTube and isolate whether the
problem is upstream or ours:

```bash
D:/flutter/bin/dart.bat run tool/check_streams.dart [videoId]    # is extraction working?
D:/flutter/bin/dart.bat run tool/check_download.dart [videoId] [--audio]
D:/flutter/bin/dart.bat run tool/probe_clients.dart              # which API clients still return combined streams
```

If `check_streams.dart` fails, the fix is usually
`flutter pub upgrade youtube_explode_dart`, not a code change.

### Running it

**iOS cannot be built on Windows** — it requires Xcode on macOS. Android needs
an SDK that is not installed here. The only runnable target on this machine is
the browser preview:

```bash
D:/flutter/bin/flutter.bat run -d chrome --web-port 5555
```

## Architecture

### Stream resolution is the fragile core

`lib/src/data/yt_repository.dart` wraps `youtube_explode_dart`. The critical
constraint: **the player takes exactly one URL**, so only a *combined*
video+audio stream is playable. YouTube has retired nearly all of them — as of
this build the only one left is the legacy 360p MP4, and only the Android-family
clients return it. The iOS client returns separate video-only and audio-only
tracks with no HLS ladder.

Consequences baked into the code:

- `_clientChain` is ordered by which clients actually yield combined streams.
  Do not reorder it from first principles; re-measure with `probe_clients.dart`.
- `resolve()` walks the whole chain before falling back to audio-only, and flags
  that fallback via `PlaybackSources.videoUnavailable` so the UI can say so.
  An earlier version returned audio on the first client that had it, which
  silently played every video as audio.
- Getting HD would require playing the two tracks together, which needs a
  different engine (`media_kit`/libmpv) that cannot do native iOS PiP.

### One player for the whole app

`lib/src/player/playback_controller.dart` owns a single long-lived
`BetterPlayerController`. Screens attach a render surface to it; they never own
it. This is what lets audio survive leaving the watch page.

Background playback needs three things aligned, and removing any one breaks it:

1. `ios/Runner/Info.plist` declares `UIBackgroundModes: [audio]` — without it
   iOS suspends AVPlayer on background and PiP refuses to start.
2. The player config sets `handleLifecycle: false`, `autoDispose: false`, and a
   no-op `playerVisibilityChangedBehavior`.
3. The data source sets `showNotification: true`. In `better_player` a visible
   notification means "the host app manages playback", which disables its
   remaining automatic pause paths.

`autoDispose: false` matters specifically because `BetterPlayer`'s widget
`dispose()` calls `controller.dispose()` unconditionally; the flag makes that a
no-op so popping the watch page does not tear down the native player.

Playback always prefers a completed download over the network — see
`_offlineFile()`.

### better_player_plus is vendored, not a pub dependency

`third_party/better_player_plus` is a patched copy of 1.3.4, wired in through a
path dependency. The published plugin hard-disables the notification and
lock-screen skip buttons on both platforms and offers no setting for them.

iOS is fixed from outside the plugin — `ios/Runner/AppDelegate.swift` reclaims
`MPRemoteCommandCenter`, which is a process-wide singleton, and re-arms the
commands after every video because the plugin resets them on each
`setupDataSource`. Android has no equivalent seam, so the plugin source itself
carries the change.

`third_party/better_player_plus/PATCHES.md` lists every edit, and each one is
marked `PATCH:` in the source. Re-apply them when upgrading; `flutter pub
upgrade` will not.

### Downloads

`lib/src/data/download_manager.dart` runs a **serial** queue; YouTube throttles
concurrent downloads from a single manifest. A failed or cancelled transfer
deletes its partial file rather than leaving a truncated video that half-plays.
Anything caught mid-transfer at startup is marked failed by `restore()` so it is
retried deliberately.

### HD downloads need two files joined

`lib/src/data/media_muxer.dart` wraps FFmpeg. YouTube retired combined streams
above 360p, so anything HD is a video-only track plus a separate audio track:
`downloadTarget(hd: true)` returns both, the manager fetches them in turn, and
the muxer copies them into one MP4 without re-encoding. A failed join keeps the
video-only file rather than discarding a finished transfer.

MP3 is the one real re-encode — YouTube serves AAC, so the conversion is a
genuine quality loss and exists only for players that refuse `.m4a`. Both are
off by default; both are no-ops where the native library is unavailable, and
downloads fall back to the 360p combined file.

### Persistence

`lib/src/data/db.dart` — SQLite at schema **version 2**. Adding a table means
bumping the version and extending `onUpgrade`, not just `onCreate`; `downloads`
was added that way. Playlist id 1 is reserved for Watch Later and is seeded at
creation. Everything is device-local: there is no account, no sync, and the
YouTube Data API cannot supply watch history even if sign-in were added.

### Web is a preview target, not a platform

A cross-cutting `kIsWeb` concern threads through several files. In a browser:

- `youtube_explode_dart` fails under dart2js (`NoSuchMethodError: 'getT'`) and
  browsers block youtube.com, so `YtRepository.isPreview` serves hardcoded rows
  from `lib/src/data/preview_data.dart`.
- `PlaybackController.play()` returns early — there is no native player plugin.
- `WatchPage` renders a placeholder surface instead of `BetterPlayer`.
- `main.dart` wraps the app in a 390×844 iPhone frame with overridden
  `MediaQuery` insets, so layout matches a real phone instead of stretching.
- `AppDatabase.open()` swaps in `databaseFactoryFfiWeb`.

When touching these paths, keep the iOS/Android behaviour the source of truth
and the web branch clearly subordinate.

### Navigation

`RootShell` keeps three tabs alive in an `IndexedStack`. Because every tab is
built once at startup, anything that should happen "on arrival" must be driven
from `_onTabSelected` via a `GlobalKey` — `SearchPage.focusInput()` and
`LibraryPage.reload()` both work this way. Do not use `initState` for it.

The watch screen is a non-opaque route that slides up, so the feed stays visible
while the player is dragged down to minimise into the mini player.

## Other agent configs

An OpenAI Codex config exists at `~/.codex/config.toml`. Reply `/import` to scan
and list what is importable, then `/import --yes=<digest>` to apply it.
