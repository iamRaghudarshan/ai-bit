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

**The known-good stable version is 2.6.1**, marked by the tag `stable-2.6.1`
(iOS build 83; Android the per-ABI split). When the user asks for "stable",
build from that tag — not from `main` unless they ask for latest — and hand
back `app-arm64-v8a-release.apk` (~73MB) and the iOS build number.


Builds run on GitHub Actions and are triggered by a tag, never by a commit:

```bash
git tag v1.2.3 && git push origin v1.2.3              # iOS -> TestFlight
git tag android-1.2.3 && git push origin android-1.2.3 # APK artifact only
```

The version name comes from the tag with the prefix stripped; the build number
is the Actions run number. `pubspec.yaml` still reads `1.0.0+1` and is not the
source of truth — do not "fix" it. **Identify a build to the user by its build
number**, which is always unique, because several releases can share a version
name. **Never build without the user's explicit approval in that same message**
("build" / "ok build") — not "fix it" or "do it", and not carried over from an
earlier build in the session.

The Android artifact is **split per ABI** (`--split-per-abi`); the arm64 slice
is `app-arm64-v8a-release.apk` (~73MB, nearly every real phone) and a copy is
also named `app-release.apk`. The artifact bundles all three slices, so its zip
is large — the GitHub download to this PC is slow; run `gh run download` in the
background and hand the user the arm64 path.

Testing on the user's device: their phone (a Xiaomi, Android 12, arm64) can be
driven over adb. There is no adb on PATH here — download standalone
platform-tools into the scratchpad, then `adb push` the APK (Xiaomi blocks
`adb install`) for a manual tap-install, and `adb logcat` to read crashes.
Release strips Dart `debugPrint`, but native (Kotlin/PlayerNotificationManager)
logs still show. Several device-only bugs (R8 launch crash, extensionless-URL
playback crash, lock-screen media session) were found exactly this way.

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

## What is built

Playback: single long-lived player, background audio, PiP, speed, sleep timer,
captions, an audio-only mode that plays the video stream with the picture
covered, and a screen-off saving mode that steps down the ladder. The player's
settings sit behind a **"⋮ More" overflow** on the watch page — Quality, Speed
and Captions inline, the rest (Sleep, Audio only, Autoplay, Repeat, Queue, PiP,
Cast, Stats, Save, Share) in the sheet — rather than a sideways-scrolling chip
row.

Quality is the HLS ladder where one exists and muxed renditions where not; the
picker reads live tracks off the manifest, and Settings offers the full ladder
as a saved default.

Browsing: home feed (personalised from search history, or curated in Kids
mode), Shorts, channel pages (Videos, Shorts, Live, Playlists), comments with
replies, local playlists, subscriptions, queue. **Search is not a tab** — it is
the top-bar magnifying glass on Home, opening a focused screen with recent
searches, live completions and combinable filters (YouTube's own layout). The
bottom nav is Home, Shorts, Subscriptions, You.

Watch history is **three tabs — Videos, Shorts, Kids** (`history_page.dart`).
`VideoBrief.isShort` / `isKids` tag each row; `isShort` is set by the Shorts
feed, `isKids` at play time from the current mode. Videos and Shorts exclude
Kids-mode content; the You-page recent shelf shows regular videos only.

Kids mode: a pill toggle in the Home top bar (default off). On, the home feed
and Shorts draw only from curated kid-friendly topics (`_kidsTopics` /
`_kidsShortsTopics` in `yt_repository.dart`) and the category chips hide. It
curates, it does not enforce — the app cannot apply YouTube's own age gating.

Shorts smoothness: only the active page watches the player (siblings are a
static thumbnail behind a `RepaintBoundary`), and `YtRepository.prefetch` warms
the stream cache for the next two shorts so a swipe is a cache hit, not a fresh
resolve. True next-video buffering would need more than the one shared player.

Offline: serial download queue with a **per-download quality picker** (every
real rendition with its size — 360p combined, HD via mux, audio, MP3), a stall
watchdog so a stuck transfer fails visibly instead of spinning, and a storage
screen that measures and clears downloads, cache and history separately.

Platform: lock-screen and notification transport controls including skip,
AirPlay via the system route picker, call and Bluetooth interruption handling.
Android's lock-screen widget needs the media session to carry title/channel/
artwork metadata, not just duration — see PATCHES.md #15/#16.

Deliberately absent, with reasons: Google Sign-In (declined; would put a real
account behind a ToS-violating client), Chromecast (needs the Cast SDK and a
receiver id), live chat, channel About (YouTube returns no parseable data for
it), and pasting non-YouTube links — Instagram and the rest serve a login wall
to anonymous clients, so there is nothing to extract.

**Not publishable.** Guideline 5.2.2 forbids exactly this, and repeated
submissions risk the developer account. TestFlight internal testing and
sideloaded APKs are the distribution model. **Stable baseline is 2.6.1**, tag
`stable-2.6.1` — build from it when the user asks for "stable".

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

`lib/src/data/db.dart` — SQLite at schema **version 6**. Bumping the version
means extending BOTH `onCreate` (new installs) and `onUpgrade` (existing ones),
or the change is missing on one path: `downloads` (v2), `searches` (v3),
`subscriptions` (v4) added whole tables; `history.is_short` (v5) and
`history.is_kids` (v6) added columns via `ALTER TABLE` so existing history
survives. Playlist id 1 is reserved for Watch Later and is seeded at creation.
Everything is device-local: there is no account, no sync, and the YouTube Data
API cannot supply watch history even if sign-in were added.

Per-download quality is persisted as the record's `quality` spec (`360p`,
`1080p`, `Audio`, `MP3`), so a retry or a restore after restart re-fetches the
same rendition without a schema change.

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

**Release Android builds run with R8 off.** The release build crashed on
launch on-device with `NoSuchMethodException: WorkDatabase_Impl.<init>` — R8
stripped a constructor WorkManager (pulled in by the vendored player for its
cache/image workers) creates by reflection. `isMinifyEnabled = false` in
`android/app/build.gradle.kts` fixes it; do not re-enable shrinking on a
sideloaded app. iOS is unaffected because R8 is Android-only, which is the
general shape here: an Android-only crash with iOS fine points at the Android
build config or a plugin's native side, not shared Dart.

**Apple scans the linked binary, not your code.** Upload has been rejected
twice with error 90683 for purpose strings the app never needed: `gal` links
photo-library reads, FFmpeg links AVFoundation capture. Adding a dependency
means checking what it links, and the release workflow's purpose-string step
should gain a line for it — a rejection costs a build number and a round trip.

**Check both platforms.** iOS and Android needed entirely different fixes for
the same symptom every time: lock-screen skip, call interruptions, notification
staleness. One working says nothing about the other.

**The app cannot be run here.** Anything about gestures, calls, Bluetooth, the
lock screen or smoothness is reasoned from the source, not observed. Say which
it is when reporting.

## Other agent configs

An OpenAI Codex config exists at `~/.codex/config.toml`. Reply `/import` to scan
and list what is importable, then `/import --yes=<digest>` to apply it.
