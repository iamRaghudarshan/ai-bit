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

Tests are pure unit tests (`test/unit_test.dart`) covering formatters, the
`VideoBrief` ⇄ SQLite round trip, the "did the video really end" rule, download
target sizing and the media-processor fallback contract. They do no I/O and need
no device.

**Neither platform can be built here.** iOS needs Xcode on macOS; the Android
SDK is not installed. Native code — `ios/Runner/*.swift`, the vendored plugin's
Swift and Kotlin — is therefore written blind and first compiles in CI. Expect
that, and read the CI log rather than guessing when it fails.

### Releasing

Builds run on GitHub Actions and are triggered by a tag, never by a commit:

```bash
git tag v1.2.3 && git push origin v1.2.3              # iOS -> TestFlight
git tag android-1.2.3 && git push origin android-1.2.3 # APK artifact only
```

The version name comes from the tag with the prefix stripped; the build number
is the Actions run number. `pubspec.yaml` still reads `1.0.0+1` and is not the
source of truth — do not "fix" it. **Identify a build to the user by its build
number**, which is always unique, because several releases can share a version
name. Never tag without the user asking for a build in that message.

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

`lib/src/data/media_processor.dart` defines `MediaProcessor` — an interface, so
the ~70-100 MB FFmpeg dependency stays replaceable. `FfmpegMediaProcessor` is
the real one, `UnavailableMediaProcessor` declines everything, and
`DownloadManager` takes one by injection and never names FFmpeg itself.
Implementations must not throw: a transfer that already completed is worth
keeping even when post-processing fails. YouTube retired combined streams
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

### Vendored player plugin

`third_party/better_player_plus` is a **patched copy** of 1.3.4, wired in by a
path dependency in `pubspec.yaml`. It is not a fork with its own history.

Every edit is marked `PATCH:` in the source and listed in
`third_party/better_player_plus/PATCHES.md`. They cover the lock-screen and
notification skip buttons (disabled outright upstream, on both platforms),
Android audio focus, iOS out-of-band MIME types for extensionless URLs, and two
staleness bugs in the now-playing info. **`flutter pub upgrade` will not
reapply any of them** — re-apply by hand from PATCHES.md when bumping.

### Navigation

`RootShell` keeps three tabs alive in an `IndexedStack`. Because every tab is
built once at startup, anything that should happen "on arrival" must be driven
from `_onTabSelected` via a `GlobalKey` — `SearchPage.focusInput()` and
`LibraryPage.reload()` both work this way. Do not use `initState` for it.

The watch screen is a non-opaque route that slides up, so the feed stays visible
while the player is dragged down to minimise into the mini player.

## Working on this codebase

Things learned the hard way here, most of them more than once:

**Probe before building.** `youtube_explode_dart` has failed in at least seven
distinct ways — search, suggestions, channel uploads, channel playlists — and
each was found by hitting the live API from a `tool/` script rather than by
reading code. When something returns nothing, write a probe first. Every
`tool/check_*.dart` exists because a guess was wrong.

**A silent catch hides a dead feature.** Search suggestions were empty for
months because a broken package call was caught and turned into an empty list.
If a `catch` returns a neutral value, say why in a comment or log it.

**The player is one long-lived instance.** Several plugin bugs come from
assuming a player per video: the lock-screen artwork cache was keyed by player
id, and its periodic now-playing observer was never removed for the current
player. Both showed the first video's details forever. When something in the
notification or lock screen is stale, look for per-player caching.

**Never rebuild the data source on a lifecycle change.** `inactive` fires for a
notification banner or the app switcher, not just for backgrounding. Swapping
the source there stopped playback and lost the position. Quality changes are
track selections where a ladder exists; only a progressive source needs
`setResolution`, and that is a full rebuild which also makes the outgoing
player report that it ended.

**Check both platforms.** iOS and Android needed entirely different fixes for
the same symptom every time: lock-screen skip, call interruptions, notification
staleness. One working says nothing about the other.

**The app cannot be run here.** Anything about gestures, calls, Bluetooth, the
lock screen or smoothness is reasoned from the source, not observed. Say which
it is when reporting.

## Other agent configs

An OpenAI Codex config exists at `~/.codex/config.toml`. Reply `/import` to scan
and list what is importable, then `/import --yes=<digest>` to apply it.
