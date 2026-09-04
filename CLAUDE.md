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
target sizing and the media-processor fallback contract, plus the pure helpers
the later waves added — `KidsGuard.daysSinceEpoch`, PIN hashing and its
constant-time compare, `DataUsageService.estimateStreamBytes` and the queue
shuffle's ordering. They do no I/O and need no device. Anything whose answer is
only wrong once a day, or only wrong on a 60fps stream, belongs here: both of
those bugs shipped, and both are now pinned by a test.

**Neither platform can be built here.** iOS needs Xcode on macOS; the Android
SDK is not installed. Native code — `ios/Runner/*.swift`, the vendored plugin's
Swift and Kotlin — is therefore written blind and first compiles in CI. Expect
that, and read the CI log rather than guessing when it fails.

### Releasing

**The known-good stable version is 2.6.1**, marked by the tag `stable-2.6.1`
(iOS build 83; Android the per-ABI split). When the user asks for "stable",
build from that tag — not from `main` unless they ask for latest — and hand
back `app-arm64-v8a-release.apk` (~73MB) and the iOS build number.

**Latest release is 2.23.0** — Android build 127, iOS build 128 — published to
the download site. Check `git tag --sort=-creatordate` rather than trusting
this line, which ages.


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
earlier build in the session. **A build the user approves is published to the
download site in the same job** — see below; they should not have to ask twice.

That tag-derived version reaches the user in three places, all fed from the
same `--build-name`/`--build-number` CI passes: the Android **launcher label**
is `AI BIT <version>` via a `manifestPlaceholders["appName"]` in
`android/app/build.gradle.kts` (so `android:label="${appName}"` — a local build
with no `--build-name` shows the pubspec's placeholder 1.0.0, which is fine
since locals never ship), a **Version row in Settings → About**, and the
update dialog. `package_info_plus` is the source for both in-app readings.

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

### Download website and in-app updates

The APK is distributed (no store) from **`safenest.raghudarshan.online`**, which
is a *separate* project at **`D:\AI PRO`** — a SafeNest/FinMate FastAPI storefront
(uvicorn on 127.0.0.1:8080, no `--reload`) behind a Cloudflare tunnel. **Do not
disturb SafeNest** — never restart that server or edit its mobile app.

Publishing is deliberately **restart-free**: the server mounts the built SPA
directory `finmate-react/frontend/dist/` as StaticFiles at `/`, and that dir is
served live (new files appear without a restart). So the AI BIT files live there:

- `dist/ai-bit-<version>.apk` — the build, served at `/ai-bit-<version>.apk`.
- `dist/ai-bit-latest.json` — `{version, build, url, notes}`; the update manifest.
- `dist/aibit-gate.js` — the download password gate (see below).

The download is reached through a **hidden password-gated link**, not a public
page (the "new website" idea was dropped). A faint dot in the SafeNest `/get`
footer (`backend/storefront/index.html`, read live per request, so editing it
needs no restart) has `class="dl-trigger"`; `aibit-gate.js` binds it to a
password modal. Correct password (**hardcoded `10001`**) triggers the APK
download. The gate is a **same-origin .js file**, not inline, because the
storefront sets CSP `script-src 'self'` — inline scripts and `onclick` are
blocked. Client-side only; not a security boundary.

**To publish a new build:** build (tag as usual) → download the arm64 APK →
`cp` it into `dist/ai-bit-<new>.apk` → bump `dist/ai-bit-latest.json`
(`version`, `build`, `url`). That is all: the gate fetches that same manifest
at page load for its download URL and the version line in the modal, so it
follows the JSON automatically. (Its hardcoded APK path is only a fallback —
worth bumping if editing the file anyway, and any edit to `aibit-gate.js`
also needs the `?v=` bumped on its script tag at the bottom of
`finmate-react/backend/storefront/index.html` (NOT `backend/storefront/`),
because Cloudflare edge-caches `.js` for 4 hours but not HTML.)
All live immediately, no restart. Verify **through the public domain**, not
just localhost: `curl https://safenest.raghudarshan.online/ai-bit-latest.json`
and the new `/ai-bit-<new>.apk`.

In-app: **Settings → About → Check for updates** (`update_service.dart`) fetches
`ai-bit-latest.json`, reads the running build from `package_info_plus`
(`buildNumber` = the CI run number, the real installed build), and offers the
newer one. Android's Download button opens the APK URL via `url_launcher`
(needs the `<queries>` https VIEW intent in the manifest, Android 11+); iOS is
told to update through TestFlight, since it cannot install an APK.

### Diagnostics — run these before debugging playback code

YouTube changes its player endpoints every few months, and that breaks the app
without any code change. These scripts hit live YouTube and isolate whether the
problem is upstream or ours:

```bash
D:/flutter/bin/dart.bat run tool/check_streams.dart [videoId]    # is extraction working?
D:/flutter/bin/dart.bat run tool/check_download.dart [videoId] [--audio]
D:/flutter/bin/dart.bat run tool/check_chunked.dart [videoId]    # does the ranged chunked download complete?
D:/flutter/bin/dart.bat run tool/probe_clients.dart              # which API clients still return combined streams
D:/flutter/bin/dart.bat run tool/check_takeout.dart <playlists dir> # does the Takeout parser match a real export
D:/flutter/bin/dart.bat run tool/takeout_to_backup.dart <takeout dir> # Takeout -> one importable backup file
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

Privacy is three settings that people conflate, so keep them distinct. **App
lock** holds a shield over the whole app until a PIN — or the device's
biometric — is accepted (`app_lock_service.dart`, `app_lock_page.dart`, and the
`_AppLockGate` in `main.dart`, which sits in `MaterialApp.builder` so it wraps
the Navigator and covers every pushed route). It raises the shield on `paused`,
not on the way back in, because the recents thumbnail is captured on the way
out and a lock that still lets the task switcher show your watch history is
theatre; the *prompt* then waits for `resumed`, since a biometric sheet raised
while backgrounded comes back as a failure the user never caused. **Incognito**
stops recording — and it skips the *search* history as well as the watch
history, which is not tidiness: recorded queries are what personalise the home
feed, so an incognito search would have surfaced in the recommendations
afterwards. It skips resume positions too, which is the deliberate price of the
mode. **History retention** auto-deletes rows older than N days, run once per
launch from a post-frame callback in `main.dart` so nothing on screen waits for
it; 0 means keep forever and is both the default and the old behaviour.

None of it is a security boundary, and the code says so out loud: the PIN is a
sha256 digest in SharedPreferences, which is a plain XML file that anyone with
root or an adb backup can read — and clear. It is hashed anyway because people
reuse PINs.

Kids mode: a pill toggle in the Home top bar (default off). On, the home feed
and Shorts draw only from curated kid-friendly topics (`_kidsTopics` /
`_kidsShortsTopics` in `yt_repository.dart`) and the category chips hide. It
still only *curates* the content — the app cannot apply YouTube's own age
gating — but the mode itself is now **enforceable**: an optional PIN is asked
for on the way out, and an optional daily allowance stops playback once it is
spent (`kids_guard.dart`, with a countdown bar and a time's-up panel on Home).

Turning Kids mode ON is free; only turning it OFF is guarded, because a child
switching it *on* is not the threat. That asymmetry is a `&&` short-circuit at
**one** write site — `home_page.dart`, inside `_ModeSwitch.onChanged` — and
`grep -rn "kidsMode = " lib/` outside `settings.dart` must keep returning
exactly that one line. A second path into the setter is a second way out of the
mode. All three Kids-PIN asks (leave the mode, remove the PIN, set or change
it) go through the same `AppLockPage.confirmKidsPin`, which returns true when
no PIN is set, so an unset guard blocks nothing.

The same reasoning is why `StorageService.clearAll` deliberately does **not**
clear preferences. Wiping every table and leaving the prefs looks like an
oversight and is not: prefs hold `kidsPinHash` and `appLockPinHash`, so
clearing them would turn "Clear all app data" into the escape hatch from Kids
mode for exactly the person the PIN was meant to stop. Content is device-local
and re-obtainable; the guards are the point.

Shorts smoothness: only the active page watches the player (siblings are a
static thumbnail behind a `RepaintBoundary`), and `YtRepository.prefetch` warms
the stream cache for the next two shorts so a swipe is a cache hit, not a fresh
resolve. True next-video buffering would need more than the one shared player.

Offline: serial download queue with a **per-download quality picker** (the full
144p–1080p AVC ladder with each size, plus 360p combined, audio, MP3),
pause/resume/reorder, ranged chunked transfers, and a storage screen that
measures and clears downloads, cache and history separately — plus a **"Clear
all app data"** full reset.

Added since the 2.6.1 baseline (all in later builds, on `main`): **SponsorBlock**
auto-skip, **backup & restore** of the library to a JSON file
(`backup_service.dart`), an **audio-track / dub-language picker**, a **Data
saver** setting (streams the lowest rendition; reuses the audio-only low-quality
path), per-channel remembered speed, an **A–B loop**, chapter ticks on the seek
bar, a Continue-watching shelf, AMOLED-black + accent-colour theming, and a
channel **Subscribe button + subscriber count** on the watch page. Note the
streaming quality floor: most videos now expose only the 360p combined stream,
so Data saver and the quality picker cannot go below 360p while *watching* even
though *downloads* reach 144p.

**Big screens get a multi-column feed** (2.17.0). `feedColumnsFor(width)` in
`lib/src/ui/widgets/responsive_feed.dart` is the single breakpoint rule — 2
columns from 600dp (Material's tablet boundary; an earlier 640 cutoff left
small portrait tablets on the stretched phone list), 3 from 1000, 4 from 1400 —
and `ResponsiveVideoFeed` wraps it, taking a *list* builder and a *grid*
builder because phone and tablet items are different widgets, not one widget
resized: Home shows `VideoCard`s and Subscriptions/channel tabs show compact
`VideoRow`s, but every surface converges on `VideoCard(inGrid: true)` in the
grid. `FeedSkeleton` follows the same rule so the loading state does not
announce a phone layout and then jump. Phones under 600dp keep the exact
single-column `ListView` they always had; a phone in landscape does cross the
threshold, which matches the real app. Used by Home, Subscriptions and the
channel Videos/Shorts/Live tabs; search results stay rows, as on YouTube.

Also in the later wave, each in the surface it belongs to: Home's category
chips gained a **Subscribed** feed built from the local `subscriptions` table
(newest first, and deliberately taking no refresh token — every other feed
rotates its topic window on pull-to-refresh because it is *assembling* a
selection, but this one has a single correct order, so shifting the window
would only hide the newest upload the user pulled down to find); a **Surprise
me** tile on the You page that opens a random *unwatched* video from those same
channels, random rather than newest so tapping twice is worth doing; **search
and bulk delete** in watch history, the search filtered in SQL per tab rather
than fetched wide and split in Dart; and a queue that can be **shuffled**
reversibly — the pre-shuffle order is kept, so the button is a toggle and not a
one-way door — or **saved as a playlist**.

Data usage (`data_usage_service.dart`, its own screen) bills bytes to the
channel that spent them, and every row is labelled `exact` or `estimated`
because the two are not the same kind of number. Downloads are exact: every
byte passes through our own download manager. Streams cannot be — the native
player opens the googlevideo URL itself, so no Dart code ever sees that
traffic, and what gets stored is watched-duration times an approximate bitrate
for the rendition. A 30% error either way is entirely possible, and
re-buffering, seeking and prefetch are invisible to it. Keep that distinction
on screen: presented as a carrier figure it would simply be wrong, and someone
would eventually reconcile it against a real bill.

Platform: lock-screen and notification transport controls including skip,
AirPlay via the system route picker, call and Bluetooth interruption handling.
Android's lock-screen widget needs the media session to carry title/channel/
artwork metadata, not just duration — see PATCHES.md #15/#16.

Casting is **DLNA/UPnP in pure Dart** (`dlna_client.dart`, `cast_sheet.dart`),
and it is what Chromecast turned into. The Cast SDK was ruled out because it
needs a registered receiver application id and a Google dependency; DLNA asks
nothing of us, since discovery is an SSDP M-SEARCH datagram and control is a
handful of SOAP posts, and nearly every smart TV of the last decade answers it.
The renderer is handed the resolved stream URL, so the same one-URL constraint
as the in-app player applies. **iOS 14+ gates the multicast that discovery
needs behind `com.apple.developer.networking.multicast`**, an entitlement Apple
grants only on request; without it the datagram is silently dropped and a scan
finds nothing. So "no devices found" on an iPhone is very likely the platform
rather than a bug in the client — reproduce on Android before debugging it.
That is also why the cast button does not offer the DLNA sheet on iOS at all:
AirPlay through the system route picker is the answer there.

**Playlists, subscriptions and watch history come in from a Google account
through Takeout, not a sign-in**
(`takeout_import.dart` + `takeout_service.dart`, Library top bar). Takeout is
the one route that reaches *private* playlists without authenticating, which
is why it was chosen over Google Sign-In - the objection to signing in was
never the code, it was putting a real account behind a ToS-violating client.
The parser is deliberately tolerant and pure: Takeout's layout is undocumented
and has shifted between exports, so it prefers the column a `Video ID` header
names and otherwise scans each row for something id-shaped, and a test pins
every shape seen so far (header row, BOM, CRLF, blank lines, no header). The
anchored 11-character id pattern exists to REJECT the timestamp column, which
is the trap. Importing is slow and serial by nature: Takeout stores ids and
nothing else, so every title and duration is its own lookup, and firing them
concurrently gets throttled - the same reason the download queue is serial.
Videos that are deleted, private or region-locked are counted and reported
("40 imported - 3 unavailable") rather than dropped silently. An import
**merges into a playlist of the same name** instead of creating a second one:
the app seeds a playlist called exactly "Watch later" and Takeout exports
`Watch later-videos.csv`, so a plain create would split those videos across two
identically named playlists. That was found by running
`tool/check_takeout.dart` over a real export, which is also the only way these
layouts have ever been confirmed rather than guessed.

**The easiest route is `tool/takeout_to_backup.dart`**, which converts a whole
export into ONE file in the app's own backup format, doing the playlist video
lookups on a desktop instead of on the phone. The user then moves one file and
uses Settings → Import & export → Import library. It sets `reserved: true` on a
playlist named "Watch later", which is what makes restore merge it into the
seeded one rather than creating a duplicate. The in-app Takeout importer still
exists for importing the raw export directly.

**Subscriptions and history need no network at all**, unlike playlists:
`subscriptions.csv` already carries the channel id and title, and
`watch-history.html` carries the video id, title, channel and timestamp - so
those two imports are instant while a playlist import of the same size takes
minutes. Three traps, all found only by running the parser over a real export:
the timestamp's space before AM/PM is U+202F, a NARROW no-break space, so
splitting on `' '` silently fails every row; channel titles carry commas, so a
naive `split(',')` tears them apart (hence `splitCsvLine`); and
`subscriptions.csv` was read as a *playlist* of four videos, because channel
names like "CodingPhase" and "Geekyranjit" are exactly eleven characters of the
same alphabet a video id uses — only the header can tell them apart, which is
what `_foreignHeaders` is for. History import reads a bounded 6 MB prefix and
keeps 500 rows: a real export was 28 MB and 28,000 entries, it is newest-first,
and the history table caps itself anyway, so reading it all would spend a
phone's memory producing rows that are trimmed away. It writes through
`AppDatabase.importWatch`, which takes the REAL watched time — `recordWatch`
stamps `now`, which would collapse years of history onto today.

Deliberately absent, with reasons: Google Sign-In (declined; would put a real
account behind a ToS-violating client - see Takeout above for how playlists
arrive instead), the Google Cast SDK (needs a registered
receiver id — DLNA replaced it, above), live chat, channel About (YouTube
returns no parseable data for it), and pasting non-YouTube links — Instagram
and the rest serve a login wall to anonymous clients, so there is nothing to
extract.

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

### Floating the video out of the app

"Keep playing while I use another app" is one sentence with two completely
different implementations, and `lib/src/player/floating_player.dart` holds both
behind `FloatingPlayer.isSupported`.

**Android** gets a real overlay window: `SYSTEM_ALERT_WINDOW` plus a foreground
service holding a view in the `WindowManager` at `TYPE_APPLICATION_OVERLAY`,
driven over the `ai.bit/floating_player` channel. Until the latest wave that
window could only ever be a title and a close button, because nothing let the
host app render the plugin's video anywhere but the Flutter texture. It now
shows the real picture, and it does so by **moving the one ExoPlayer's output
surface** — not by starting a second player. A second decoder would decode the
same stream twice and fight the first for audio focus, and every stale
notification bug in this project came from assuming a player per video.
`BetterPlayerSurfaceBridge` (PATCHES.md #18) is the seam, and it speaks **only**
`android.view.Surface` and `Boolean` on purpose: `BetterPlayer` is `internal`
and media3 is `implementation`-scoped in the plugin module, so putting either
type in the signature would break the *app's* build, not the plugin's.

The handoff is reversible for exactly one reason, and it is the property to
preserve through any edit here: `attachExternalSurface` never writes to the
`surface` field. That field is Flutter's, assigned once in `setupVideoPlayer`;
the borrowed surface lives in a separate `externalSurface`. Detaching is
therefore a re-set of a field still held, not a reconstruction. Restore fires
from three independent places — `surfaceDestroyed`, the first line of
`onDestroy`, and a Dart-side lifecycle observer that stops the overlay on
`resumed` — because a user who comes back through the launcher instead of
tapping the bubble must still get the picture back.

The in-app surface goes blank while the overlay is up. One decoder has one
output; system PiP behaves identically and the audio never stops. That is the
intended behaviour, not the bug to fix.

The foreground service can be *refused* rather than merely fail: Android 14
requires a `foregroundServiceType`, and a `mediaPlayback` service is only
allowed to start while something is actually playing. So both Dart and Kotlin
gate on playback being active, `startInForeground` returns a boolean, and a
failure reports over the channel and then calls `stopSelf()`. That `stopSelf`
is not tidying up — it is what cancels the `ForegroundServiceDidNotStartInTime`
watchdog `startForegroundService` armed, so a soft refusal does not become a
crash five seconds later.

**iOS cannot have an app-drawn overlay at all, and it is not worth
re-attempting.** A third-party app has no window level above another app's —
`UIWindowLevel` is per-application and the sandbox simply has no such thing —
and an app that found a way would be rejected for it. Picture-in-Picture is
Apple's deliberate answer to the same need, so `isSupported` is false on iOS
and the pop-out button falls back to
`PlaybackController.enterPictureInPicture()` rather than pretending there is an
overlay to ask for.

New in this wave and **opt-in**: iOS can now enter PiP *automatically* when the
app is left mid-video, which is what people expect from YouTube and Safari.
`canStartPictureInPictureAutomaticallyFromInline` only affects a controller
that already exists while the video plays inline, and the plugin built its
`AVPlayerLayer` at the moment PiP was requested — after the fact — because
Flutter renders video into a texture, not a layer. PATCHES.md #17 therefore
creates the layer up front and inserts it *behind* Flutter's view: iOS refuses
automatic PiP for a hidden or offscreen layer, but the texture draws over it so
nothing changes on screen. Guarded to iOS 14.2+ and left off by default,
because it touches the main playback path and cannot be verified here.

### The services `main.dart` hangs off the tree

Everything below is constructed once in `main.dart` and handed down by
provider, each taking its dependencies by injection the way `DownloadManager`
and `PlaybackController` always have — so there is still exactly one
`AppDatabase` and one `SettingsService` for the whole app, and a test can hand
any of them a throwaway database.

- `app_lock_service.dart` — hashes and verifies the PIN, and raises the
  biometric prompt. Every biometric unhappy path (cancelled, no sensor, nothing
  enrolled, plugin missing on the web target) collapses to `false` rather than
  an exception, because the caller's only sensible reaction to all of them is
  the same one — fall back to the PIN — and collapsing keeps that decision in
  one place instead of spreading platform error codes through the UI. It is
  logged, not silently swallowed.
- `kids_guard.dart` — today's Kids-mode watch seconds and whether the allowance
  is spent, upserting one `kids_usage` row per day. A session that crosses
  midnight re-reads the new day's row mid-flight, so a child watching at
  11:58pm is not still blocked the next morning.
- `data_usage_service.dart` — the per-channel byte accounting described above.
- `network_service.dart` — whether the active transport is cellular, so "mobile
  data saver" and "audio only on mobile data" can tell Wi-Fi from a metered
  connection. Not inferable from Dart alone, which is why `connectivity_plus`
  is a dependency.
- `battery_service.dart` — charge level, so battery saver can step quality down
  before the phone dies rather than after. `isLow` excludes charging on
  purpose: a phone on a charger at 15% is filling up, and degrading playback
  there is pure annoyance.
- `dlna_client.dart` — casting, above.

`NetworkService` and `BatteryService` both subscribe in `start()` and **must**
cancel in `dispose()`, or the stream and poll timer outlive the notifier and
keep firing into a disposed object.

**`KidsGuard.daysSinceEpoch` keys on the LOCAL calendar day, and both new
tables bucket through it.** It re-reads the local y/m/d as a UTC instant before
dividing by a day. Dividing the raw local timestamp instead — the obvious
version — rolls the day over at local midnight *minus the UTC offset*, so in
IST (+5:30) a child's allowance would reset at 5:30am and every evening would
be charged to the following day. `DataUsageService` borrows the same function
rather than reimplementing it, because the two tables must bucket identically
and a trap that is invisible until midnight is worth solving exactly once.

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
retried deliberately. Downloads can be **paused/resumed/reordered** (pause ends
the active transfer through a private `_PauseSignal` so the catch path keeps the
partial file instead of failing it; resume re-fetches from the start).

**Transfers are pulled in bounded ranged chunks, not one open request** —
`YtRepository._rangedDownload` requests ~8 MB at a time with a per-chunk timeout
and retry-from-where-it-stopped. A single sustained googlevideo request gets
throttled to nothing after the first burst, which surfaced on-device as
"download stalled — no data received" and a dead transfer; the chunking keeps
each request short enough to run at full speed. Verify with
`tool/check_chunked.dart`. The manager's stall watchdog is 120s so it only fires
when the transfer is genuinely dead, not mid-retry.

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

**HD downloads prefer H.264/AVC** (`_downloadableVideos`): YouTube serves 1440p
and 2160p ONLY as AV1, which Apple's Photos and AVPlayer reject on most iPhones
— a 4K download saved and then failed with `GalException NOT_SUPPORTED_FORMAT`
and would not play. Preferring AVC caps HD at a universally compatible 1080p
(AV1 only when a video offers nothing else). Same "playable beats bigger" rule
as `_bestPlayableAudio` uses for Opus. The picker offers the full 144p–1080p
AVC ladder plus the 360p combined stream. Per-height codecs re-checked live with
a throwaway probe; `avc1` exists up to 1080p, `av01` only above.

MP3 is the one real re-encode — YouTube serves AAC, so the conversion is a
genuine quality loss and exists only for players that refuse `.m4a`. Both are
off by default; both are no-ops where the native library is unavailable, and
downloads fall back to the 360p combined file.

### Persistence

`lib/src/data/db.dart` — SQLite at schema **version 8**. Bumping the version
means extending BOTH `onCreate` (new installs) and `onUpgrade` (existing ones),
or the change is missing on one path: `downloads` (v2), `searches` (v3),
`subscriptions` (v4) added whole tables; `history.is_short` (v5) and
`history.is_kids` (v6) added columns via `ALTER TABLE` so existing history
survives; `downloads`/`playlist_items` got `is_short`/`is_kids` (v7);
`data_usage` and `kids_usage` arrived as whole tables in v8. Both of those are
keyed by a *day index*, not a timestamp — one row per day, so the tables stay
tiny and yesterday's total can never leak into today's allowance — and that
index comes from `KidsGuard.daysSinceEpoch`, for the local-calendar reason
given above.

**A row is persisted through `VideoBrief.toMap()`, which is shared across the
`history`, `downloads` and `playlist_items` tables** — so a column added to
`VideoBrief` must be added to ALL THREE tables, not just the one you had in
mind. v7 existed because `is_short`/`is_kids` were added to history's table but
not the other two, and every `saveDownload`/`addToPlaylist` then threw "table
downloads has no column named is_short" and failed silently as a failed
download. When you extend `VideoBrief`, grep for `...video.toMap()`. Playlist id 1 is reserved for Watch Later and is seeded at creation.
Everything is device-local: there is no account, no sync, and the YouTube Data
API cannot supply watch history even if sign-in were added.

Per-download quality is persisted as the record's `quality` spec (`360p`,
`1080p`, `Audio`, `MP3`), so a retry or a restore after restart re-fetches the
same rendition without a schema change.

**Installing a new APK over an old one never touched user data** — the database
and prefs survive an update by themselves. *Uninstalling* is what wipes them,
and that is what Android Auto Backup is for. It was nominally enabled but had
no rules, so it tried to include the downloaded videos, blew Google's ~25 MB
backup quota, and Android then **silently skipped the whole backup** — a
reinstall came back empty with nothing to show why. `android/app/src/main/res/
xml/backup_rules.xml` (Android 11 and below) and `data_extraction_rules.xml`
(12+) now exclude `downloads/` from cloud backup and device transfer, leaving
the database and settings — far under quota — to restore. Both files are
needed; they are the same intent in two formats Android picked at different
versions. Videos are re-downloadable, the library is not. Note the rules only
help a reinstall that happens *after* a build carrying them, and only with
Google backup switched on, so Settings → Backup & restore
(`backup_service.dart`) stays the reliable manual path.

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

### Settings that override each other say so

`lib/src/core/settings_rules.dart` holds one pure function per case where a
setting quietly makes another inert — Data saver beating the quality picker,
Audio only beating anything with a picture, a battery saver stopping feed
previews, a PIN-less app lock locking nothing, a Kids time limit with no Kids
PIN behind it. The screen used to show all of these as equally live switches,
and flipping one to watch nothing happen is indistinguishable from a bug: that
is exactly how feed previews were reported broken when the real answer was
"you are on mobile data". Each rule returns null or a sentence to show under
the row, and each has a test, because this is the kind of logic that rots
silently the next time a setting is added beside it.

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

**Native changes can be verified from the built APK — do that instead of
shrugging.** Nothing Android compiles here, and "CI went green" only proves it
built, not that a manifest placeholder resolved or a resource was included. The
downloaded artifact answers both. `unzip` it, then decode `AndroidManifest.xml`
as UTF-16LE and substring-search for the value you expect (this is how
`AI BIT 2.18.0` was confirmed as the launcher label). For resources, note that
AAPT2 **renames files in release builds** — `res/xml/backup_rules.xml` ships as
something like `res/Qq.xml` — so search the compiled XML by *content*
(`full-backup-content`, `downloads/`) rather than by path, or conclude wrongly
that the file was dropped. Cheap, and it converts "reasoned" into "verified".

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
`local_auth` is the third instance and the worst of them: it links
LocalAuthentication, so the scanner demands `NSFaceIDUsageDescription`, and a
missing one does not merely fail the upload — iOS kills the app the instant the
prompt is raised on a Face ID device. (Touch ID uses the system's own text and
needs no key, but one binary covers both, so the key is unconditional. There is
no `NSBiometricUsageDescription`; that string is the whole of it.) The workflow
now checks all three before it builds.

**Parse the label you actually get, not the one you pictured.** The data-usage
estimator read a rendition's height by stripping every non-digit from the
quality spec and parsing what was left. `1080p` works, so it looked correct.
But `youtube_explode` reports any 60fps stream as `1080p60`, which became
**108060**, and an HLS track label is `1280x720`, which became 1280720 — both
then snapped to the nearest ladder rung, 2160p, charging a 1080p60 stream 4x
and a 720p track 7x what they really cost. The fix reads the two real shapes
explicitly: `WIDTHxHEIGHT` first, because a "first run of digits" rule would
return the width, then a leading digit run with any suffix ignored. The lesson
is not about resolutions. A string coming out of someone else's API has more
shapes than the one in front of you, and "strip everything that isn't a digit"
quietly assumes you have seen them all. Write the shapes down, then write a
test per shape — this one is now pinned by a test asserting `1080p60` costs the
same as `1080p` and *not* the same as `2160p`.

**Check both platforms.** iOS and Android needed entirely different fixes for
the same symptom every time: lock-screen skip, call interruptions, notification
staleness. One working says nothing about the other.

**The app cannot be run here.** Anything about gestures, calls, Bluetooth, the
lock screen or smoothness is reasoned from the source, not observed. Say which
it is when reporting.

## Other agent configs

An OpenAI Codex config exists at `~/.codex/config.toml`. Reply `/import` to scan
and list what is importable, then `/import --yes=<digest>` to apply it.
