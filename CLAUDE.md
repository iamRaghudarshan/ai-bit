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

Tests are in two files. `test/unit_test.dart` is pure — no I/O, no device —
covering formatters, the
`VideoBrief` ⇄ SQLite round trip, the "did the video really end" rule, download
target sizing and the media-processor fallback contract, plus the pure helpers
the later waves added — `KidsGuard.daysSinceEpoch`, PIN hashing and its
constant-time compare, `DataUsageService.estimateStreamBytes` and the queue
shuffle's ordering, and the whole recommender. Anything whose answer is only
wrong once a day, or only wrong on a 60fps stream, belongs here: both of those
bugs shipped, and both are now pinned by a test.

`test/db_test.dart` runs the **real SQLite engine** through
`sqflite_common_ffi`, because the one part of this app that had never been
executed anywhere was its SQL — neither platform builds here, so a broken query
would first run on a user's phone. It found three real defects on its first
run, one of which was **an app that would not start**: upgrading from schema v1
created the `downloads` table from the current definition and then ALTERed it
with v7's columns, which threw "duplicate column name" inside `onUpgrade` and
failed the open. `_addColumnIfMissing` guards that shape now, and it should be
used for any future column added to a table an earlier migration may have
created whole. The suite covers every table, the VideoBrief round trip through
all three tables that store one, and a v1-to-current migration. It skips itself
with a reason if sqlite3 cannot be loaded, so a missing system package cannot
block a release.

**Neither platform can be built here.** iOS needs Xcode on macOS; the Android
SDK is not installed. Native code — `ios/Runner/*.swift`, the vendored plugin's
Swift and Kotlin — is therefore written blind and first compiles in CI. Expect
that, and read the CI log rather than guessing when it fails.

### Releasing

**The known-good stable version is 2.6.1**, marked by the tag `stable-2.6.1`
(iOS build 83; Android the per-ABI split). When the user asks for "stable",
build from that tag — not from `main` unless they ask for latest — and hand
back `app-arm64-v8a-release.apk` (~73MB) and the iOS build number.

**Latest release is 2.25.0** — iOS build 131, Android build 132 — published to
`safenesthub.in`. (2.24.0 was tagged but never published; the old host still
advertises 2.23.0/127.) Check `git tag --sort=-creatordate` rather than
trusting this line, which ages.


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
earlier build in the session. **Publishing is a separate, manual step** —
`release.yml` has only an `ios` and an `android` job and no publish step, and
could not have one, because the download site is a tunnel-fronted machine that
CI cannot reach. An approved build therefore means: tag, wait for CI, download
the artifact, and then publish by hand as described below.

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

> **STATUS, 25 September 2026 — the move is done for new builds. Read this
> before touching updates.**
>
> The host is **`safenesthub.in`**, and it is **this machine**
> (`DESKTOP-6KK3ELO`) — check `$env:COMPUTERNAME` before assuming you need
> remote access, because an earlier note here claimed otherwise and sent two
> sessions looking for a machine they were already sitting at.
>
> It serves `/ai-bit-latest.json`, `/aibit-gate.js` and `/ai-bit-2.25.0.apk`,
> verified through the public domain. An earlier version of this note claimed
> the same thing while all three were in fact 404 — verify with `curl` against
> the real domain rather than trusting this paragraph.
>
> **The files live in `finmate-react/frontend/dist/`, served by the StaticFiles
> mount at `/` in `backend/app/main.py`.** There are NO explicit routes and no
> `finmate-react/aibit/` directory; a previous note described both and neither
> exists. Dropping a file in `dist/` publishes it with no restart, which is the
> whole mechanism — `packaging/build_exe.py` even has `FOREIGN_DIST_PREFIXES =
> ("ai-bit", "aibit")` to keep these files out of a customer's build, which is
> the clearest confirmation that staging them there is intended.
>
> **`npm run build` EMPTIES `dist/`.** That is what deleted the whole download
> site on 25 September, and from a phone it looks like a network fault rather
> than a missing file. After any web rebuild, re-publish the three AI BIT files.
>
> **Every install up to 2.24 still polls `safenest.raghudarshan.online`**,
> which is a genuinely different machine and is NOT reachable from here. It
> still advertises 2.23.0/build 127, so **no existing install can discover
> 2.25.0 on its own** — they need the APK by hand, or that host's manifest
> updated. 2.25.0 and later ask `safenesthub.in`, so this is the last release
> with the gap. Do not retire the old address until installs have moved; that
> is what stranded a SafeNest customer in August.
>
> **The hidden web download link does not exist on the new host.** The served
> storefront (`backend/storefront/index.html`) was redesigned and lost the
> `dl-trigger` dot and the `#aibit-gate` modal; the older `index-classic.html`,
> `index-dark.html` and `index-new.html` still carry both. `aibit-gate.js` is
> published and now reads its download URL from `ai-bit-latest.json` instead of
> hardcoding it — the deployed copy had drifted to three different versions in
> three places — but nothing on the page calls it. Re-adding the markup means
> editing SafeNest's live storefront, so **ask first**.
>
> **To publish a build:** tag → wait for CI → download the `aibit-android`
> artifact → copy the arm64 slice to `dist/ai-bit-<version>.apk` → write
> `dist/ai-bit-latest.json` (`version`, `build` = the Android CI run number,
> `url`, `notes`). No restart. Then verify through the public domain, not
> localhost.

The APK is distributed (no store) from the SafeNest storefront, a *separate*
project at **`D:\AI PRO`** (uvicorn on 127.0.0.1:8080, no `--reload`) behind a
Cloudflare tunnel. **Do not disturb SafeNest** — never restart that server or edit
its mobile app. Its own handover notes are in `D:\AI PRO\finmate-react\CLAUDE.md`
section 14.

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
just localhost. During the move that means BOTH hosts:
`curl https://safenesthub.in/ai-bit-latest.json` (the new one, which new builds
use) and `curl https://safenest.raghudarshan.online/ai-bit-latest.json` (the old
one, which every already-installed copy still polls)
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

Browsing: home feed (ranked against local watch history, searches and
subscriptions — see "Recommendations are two-stage" below — or curated in Kids
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

### Recommendations are two-stage, like the real thing

`lib/src/data/recommender.dart` is a local reimplementation of the shape
described in Covington, Adams & Sargin, *Deep Neural Networks for YouTube
Recommendations* (RecSys '16): **candidate generation** pulls a few hundred
plausible videos from every source the app can reach, then **ranking** scores
that much smaller set. `YtRepository.homeFeed` does the first stage;
`recommender.dart` is the second and is **pure** — no I/O, no network, `now` is
always passed in — so every rule in it is pinned by a test.

Before this, the feed had no ranking at all. Sources were round-robined by
`_interleave` and shown in the order they were assembled, so a video's position
was decided by *which source fetched it*, nothing more. Four specific
consequences, each of which the ranker addresses:

- **Opening a video was the entire signal.** A video abandoned after ten
  seconds counted exactly as much as one watched to the end. `TasteProfile`
  weights every watch by its **completion ratio**, which is this app's version
  of the paper's central finding — rank on expected watch time, not on clicks,
  because optimising for clicks promotes clickbait. `position_ms / duration_ms`
  was already in the `history` table and was simply never read.
- **Nothing decayed.** A profile built over months behaved as though every
  month were now. Interest now halves every 14 days, searches every 7.
- **Already-watched videos came back to the top.** They now sink.
- **Refreshing shifted a window modulo the list length**, which cycles back to
  the same rows. The paper lists *number of previous impressions* among its
  most important features, for exactly this reason: a video shown repeatedly
  and never opened should stop being shown. The `feed_impressions` table (v9)
  is that feature, decayed and forgotten after a fortnight.

The strongest candidate source is **`_browse.related()` on recently watched
videos** — YouTube's own co-watch list, built from what everyone else watched
next. It existed already but was fetched only on the watch page and never used
to build the feed. `feedSeeds().videoIds` was likewise already returned and
never consumed; it feeds this now.

Sources carry a **prior, not a quota** (`CandidateSource.prior`), so a strong
search result can outrank a weak subscription upload — which the old fixed-slot
interleave could not express. Diversity is a greedy pass in `rankFeed`: each
additional video from a channel already emitted costs `_channelRepeatCost`, so
the channel the profile likes most leads the feed without owning it. Greedy
rather than a sort because the penalty is not knowable until the earlier picks
are made.

**"Up next" is ranked too** (`rankUpNext`, via
`YtRepository.personalisedUpNext`). YouTube's related order is kept as a strong
positional prior — it is the co-watch signal and throwing it away to re-derive
something from local history alone would discard the only view of what everyone
else does — and the viewer is layered on top: watched videos sink, followed and
well-watched channels rise, and **the channel already on screen is damped**, so
autoplay stops walking down one uploader's back catalogue. The same ordering
feeds the visible list and the queue, so autoplay plays what the list promised.

Two things deliberately do **not** go through it. **Kids mode** ranks nothing —
it curates from a fixed topic list and consults no personal signal, and ranking
it against a profile built from the adult's viewing is precisely what must not
happen; `watchSignals()` excludes `is_kids` rows for the same reason. And a
**cold-start profile** falls back to the round-robin, because with every
personal term at zero the order would collapse onto source prior and
popularity, which is not a mix.

**An impression means "was on screen", not "was fetched"** — and getting that
wrong is easy. The first cut recorded every video in the loaded feed, about a
hundred and twenty rows of which a scrolling user sees ten, which penalised
good videos for never having been reached: the ranker would have learnt to bury
whatever it ranked highly enough to fetch. `FeedImpressionRecorder`
(`widgets/feed_impressions.dart`) counts from the feed's visibility detector
instead, at half the card on screen, deduplicated so scrolling up and down is
one impression, and batched so a fling does not wait on SQLite.
`FeedPreviewSlot` deliberately serves both previews and impressions from **one**
`VisibilityDetector` rather than nesting two per card.

Never counted in incognito or Kids mode, and only on the personalised feed — a
topic chip, Trending and Subscribed are not recommendations, so nothing in them
should be demoted for appearing. The table exists solely to shape
recommendations, so a mode that promises not to record what you watched must
not quietly record what you were shown. `clearHistory()` clears it alongside
history for the same reason.

### The second pass: satisfaction, bias, dismissals, diversity, exploration

The ranker above reproduces the 2016 candidate-generation/ranking paper. The
2019 successor — Zhao et al., *Recommending What Video to Watch Next: A
Multitask Ranking System* — is where the rest of it comes from, plus YouTube's
own published list of signals. Five additions, each fixing something the first
pass got wrong:

**1. Engagement and satisfaction are predicted separately.** The 2019 paper's
central point is that a system trained on engagement alone learns to promote
whatever gets clicked, which is the definition of clickbait; it therefore
predicts two families of objective and combines them. Here `channelAffinity`
is the engagement half and `channelSatisfaction` — recency-weighted mean
completion per channel — is the satisfaction half. The case this exists for:
a channel opened nine times and abandoned after a tenth of each video
accumulates *exactly the same affinity* as one opened once and watched through,
because affinity is completion × recency summed. A test pins that equality
first, so the test below it is genuinely testing satisfaction and not affinity
wearing its clothes.

Satisfaction is applied as a **multiplier** (`satisfactionGate`, 0.45–1.25),
not a summand. Added, a large enough engagement score simply drowns it and the
clickbait channel still wins — which is the failure being designed against.
Channels with thin evidence are shrunk towards a neutral prior, so one
abandoned video does not condemn a channel and one finished video does not
crown it. Note the deliberate limit, which has its own test: a much-watched
unsatisfying channel is **demoted, not banished** — opening something nine
times is still engagement, and the app cannot tell sampling from regret.
Banishing is what the explicit control is for.

**2. Impressions are discounted by position.** The 2019 paper trains a
*shallow tower* on the position a video was shown at, so the main model can
have that bias subtracted — a video shown at the top and skipped is real
evidence of disinterest, one glimpsed at the bottom of a fling is almost none.
`attentionAtRank` is the local stand-in: a fixed attention curve rather than a
learned scalar, accumulated into `feed_impressions.attention` at record time.
Same intent, much simpler mechanism, and no training loop to feed it — worth
being plain about rather than calling it the same thing.

**3. Explicit dismissals.** *Not interested* and *Don't recommend channel* are
on the video menu and in the `not_interested` table. YouTube names both as
first-class signals, and they are the only ones here the user states outright
rather than having inferred — so they are **absolute**: a match is dropped from
the candidate pool, not demoted. A dismissed video's title words generalise
weakly (capped) so the dismissal means slightly more than one id. The snackbar
offers Undo, and that is not politeness: a channel dismissal is a permanent
hard exclusion, so a mis-tap would otherwise remove a channel from the feed for
good with nothing in the UI to reverse it. `onDismissed` is deliberately
separate from the menu's `onRemove`, which means "take it out of this
playlist" — firing that would delete the video.

**4. Topic diversity, not just channel diversity.** Four *different* channels
covering the same phone launch crowd the feed exactly as effectively as one
channel posting four times, and the user experiences both as "it keeps showing
me the same thing". `rankFeed` now does Maximal Marginal Relevance over title
tokens alongside the channel-repeat cost — relevance minus similarity to what
is already picked.

**5. Exploration.** A purely greedy ranker is a trap: with no training loop to
correct it, it can never discover that the user has taken up something new, and
the feed narrows until it is the same channels for ever. Two defences — a
reserved share of slots for channels the profile has never seen, and softmax
(Plackett–Luce) sampling over a short head instead of a strict argmax, so
near-ties resolve differently between refreshes. That is also why the feed no
longer looks identical every time the app opens. `seed` comes from the refresh
token; `explore: false` turns both off and makes ranking deterministic, which
is what the tests assert against.

**Up next is a different surface from the home feed, and now says so.**
YouTube's wording is the design brief: the home feed "primarily relies on your
watch history", while for suggested videos "our system uses the video you're
currently watching as the main signal". So `score` takes `contextTokens`, the
current video's words, as its **own term** — folded into the topic term it
could never be worth more than the topic weight and would lose to a strong
channel affinity every time, which is exactly the bug the test
"what is playing now beats what the profile says overall" caught. While
something is playing, the long-run topic preference is damped to 0.4 and
`upNextContextWeight` puts the current video above any single other term.
`PlaybackController.playedThisSession` is kept separate from `_playHistory`
(which `playPrevious` *consumes*) so autoplay can avoid circling back through
the same videos and channels.

### The third pass: it learns, and it has a collaborative signal

The two passes above reproduce YouTube's published *architecture* with
hand-tuned constants. This closes the two things that were still missing.

**The weights are learned now** (`ranker_trainer.dart` + `RankerWeights`).
Every constant in the ranker was chosen by hand, which was the largest
remaining difference from a real recommender: a fixed set of constants cannot
notice it is wrong about somebody. There is now a real training loop —
**weighted logistic regression with watch time as the positive weight**, which
is the objective from the 2016 paper and is chosen for the same reason, that
training on clicks alone promotes whatever gets clicked. A card that was seen
and ignored is a negative of weight 1; one that was opened is a positive
weighted by how much was watched.

Three guards, and they are why this ships on by default:

- **Blended, never replacing.** `RankerWeights.blend` caps the learned share at
  half, growing with evidence, so the priors always hold at least half the
  decision. They encode things a single user's data cannot easily show — that
  popularity is a tiebreak, that a subscription is intent — and a model free to
  discard them would, given one quiet week.
- **Every weight clamped**, so one strange session cannot drive a feature to
  dominate or invert. A test throws 5000 lopsided examples at it and asserts
  the bounds hold.
- **Nothing applied below 40 observations.** A linear model fitted to four data
  points is worse than an honest guess.

Feature vectors are captured **at ranking time** (`featuresOut`), not
recomputed when the user acts — by then the profile has moved and the numbers
would describe a different world from the one they reacted to.
`markExampleOpened` only ever updates a row that already exists, so a video
reached from search or a channel page is never trained on as though the ranker
had suggested it. Settings → Recommendations shows the learned share and can
reset it, because a switch that might or might not be doing something is the
kind of feature this codebase keeps rediscovering was broken for months.

**The `covisit` table is a local item-to-item graph**, and it is the one
genuinely collaborative signal an account-less app can build. YouTube's
candidate generator is trained on what millions of people watched next; that
data is unreachable here — but every related list the app fetches is a *sample*
of it, because that is how YouTube builds those lists. Accumulating them turns
a series of one-off lookups into something queryable that **transfers**: a
video found by a plain topic search still gets credit for being strongly
co-visited with three things watched last night. Edges from a related list are
position-weighted; an edge from the user's own A→B transition is weighted four
times higher, because a related list is what YouTube believes about everybody
while that is what this person actually did. It is borrowed collaborative
filtering rather than computed, and it only covers videos the app has happened
to see — both worth saying out loud.

**Two more satisfaction signals, and one negative.** Saving to a playlist or
downloading now floors a channel's satisfaction: those are the local stand-in
for YouTube's likes and shares, and arguably stronger, since spending storage
on something is not the reflex a thumb tap is. And opening a video then leaving
within 8% of it (`WatchSignal.bailedOut`) now contributes **nothing** to
affinity rather than the small positive its completion implies — a four-second
visit is the user saying the title lied, and counting it as weak engagement is
exactly how clickbait accumulates.

**The Shorts feed is ranked** like everything else. It was the last surface
still ordered by `shuffle()`, which meant the one people scroll fastest made
the least use of what the app knew. Exploration and the rotating seed keep it
different on every visit — the only thing shuffling was buying.

Candidate generation was widened from three co-watch seeds to five. Worth
remembering why that matters more than it looks: **ranking can only ever order
what candidate generation found**, so the size of the net is the ceiling on the
whole system, and it is the cheapest thing to raise.

**What is still not YouTube, and cannot be from here.** No corpus access, so
candidates come from a few hundred fetched videos rather than billions. No
cross-user data, so the collaborative signal is borrowed rather than computed.
No satisfaction surveys. The learning loop is one user's linear model, not a
network retrained continuously and validated by live experiment. Say so plainly
rather than implying parity.

### The user gets to say, not only to be inferred from

Everything above watches behaviour and draws conclusions. `interests.dart` is
the other half, and it earns its place on the one occasion inference cannot
help at all: **cold start**. A fresh install has no behaviour to infer from, so
the feed fell back to a fixed list of evergreen topics — music, gaming,
cooking, football — that describe nobody in particular, and stayed generic
until enough history accumulated to displace it. Asking takes ten seconds.

**Settings → Recommendations → Your interests** is a chip picker over a
catalogue of about twenty topics (Technology, AI, News, Programming, Cricket,
Devotional, …). Chosen interests do two things:

- They become a **candidate source** with its own prior
  (`CandidateSource.interest`, between subscriptions and searches: weaker than
  subscribing, because ticking a box is broad rather than a commitment to
  anyone in particular; stronger than a one-off search, because it was
  deliberate and it persists). They keep a real share of the feed rather than a
  single filler slot — somebody who ticked "AI" did not mean "until you have
  watched enough for me to stop asking".
- They **seed `topicWeights`** in the taste profile, at the weight of a strong
  search. Seeded rather than kept as a separate override, and that is the whole
  design: a declared interest then behaves exactly as though the user had
  already searched for it, so the feed is relevant on the first launch and real
  behaviour is weighed *alongside* it rather than behind it. A test pins both
  ends — a matching video leads a profile that knows nothing, and a month of
  watching something else moves past the declaration.

Empty is the default and means "no opinion", not "nothing": the feed behaves
exactly as it did before. Requiring a choice before the app is usable would be
a worse first launch than a generic feed. Kids mode never consults it, for the
same reason it never consults history.

**Language and region were hardcoded to `hl=en, gl=US`** in all four
youtubei clients, which quietly decided a great deal — `gl` governs what is
popular and what is even *available*, `hl` governs what comes back as text. An
app used in India was asking America what was worth watching and then asking
for it in English. **Settings → Language & region** sets both, and they are two
settings on purpose: somebody in India who reads English wants IN and en, and
one combined "locale" gets that person the wrong feed.

Both default to **empty, meaning "match my device"**, resolved against the
platform locale at read time rather than at write time — so changing the
phone's language changes the feed instead of pinning whatever it was on the day
of install. `_LocaleBinding` in `main.dart` is a `ProxyProvider` rather than a
one-shot call at startup, so switching region takes effect on the next
pull-to-refresh rather than the next launch. `YtRepository.setLocale` fans out
to all four clients in one call because they must agree: a search answered in
Hindi beside a browse answered in English is a feed that looks like two
different apps stitched together.

### The screen is kept awake by the player, not by a widget

`PlaybackController._syncWakelock` owns the screen wakelock. `better_player`
used to, and got it wrong in a way that took a while to see: it armed the lock
in exactly **one** place — the transition *into* its fullscreen route — and
released it **unconditionally** on the way out and from widget teardown. Three
things followed, all reported as the same sentence, "the screen turns off while
I am watching":

- Inline playback and the Shorts tab never held it at all. Only fullscreen was
  ever protected.
- Picture-in-Picture enters and leaves fullscreen *programmatically* — the
  plugin calls `enterFullScreen()` when PiP starts and `exitFullScreen()` when
  it stops — so leaving PiP ran the unconditional release while the video
  carried on playing inline. This app arms PiP automatically (PATCHES #17,
  #19), so it happened with the user touching nothing.
- Nothing ever re-armed it. Being a one-shot on a route change, once anything
  dropped it, it stayed dropped for the rest of the video.

A widget is the wrong owner for a process-wide lock in an app whose whole
architecture is one player outliving every widget that renders it. All four
call sites are removed from the vendored copy (PATCHES.md #23) and the
controller derives the lock from playback state instead: **playing, with a
picture, in the foreground**. Audio-only and a dropped video track are excluded
on purpose rather than by oversight — that mode exists to listen with the
screen off, and holding the screen on there burns the battery it was meant to
save.

It is re-asserted from the position listener rather than only on transitions,
which is what makes it **self-healing**: it costs a bool comparison when
nothing has moved, and anything that drops the lock behind its back is
corrected within a tick instead of lasting the rest of the video.
`allowedScreenSleep` is now inert and is left in the config only to say so.

### Persistence

`lib/src/data/db.dart` — SQLite at schema **version 11**. Bumping the version
means extending BOTH `onCreate` (new installs) and `onUpgrade` (existing ones),
or the change is missing on one path: `downloads` (v2), `searches` (v3),
`subscriptions` (v4) added whole tables; `history.is_short` (v5) and
`history.is_kids` (v6) added columns via `ALTER TABLE` so existing history
survives; `downloads`/`playlist_items` got `is_short`/`is_kids` (v7);
`data_usage` and `kids_usage` arrived as whole tables in v8, and
`feed_impressions` in v9; v10 added `not_interested` and gave
`feed_impressions` its positional `attention` column; v11 added `covisit` and
`ranking_examples`.
`data_usage` and `kids_usage` are keyed by a *day
index*, not a timestamp — one row per day, so the tables stay tiny and
yesterday's total can never leak into today's allowance — and that index comes
from `KidsGuard.daysSinceEpoch`, for the local-calendar reason given above.
`feed_impressions` keeps a real timestamp instead, because the ranker asks
"how long ago" rather than "which day" and forgets a row entirely once it is
a fortnight old.

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
