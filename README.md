# AI Tube

A personal, ad-free YouTube client for iOS (and Android) built in Flutter.

Streams are resolved straight from YouTube's player endpoint and handed to a
native player. The web player is never loaded, so there is no ad break to
serve — this is why playback is ad-free, not because anything is being blocked.

> **Personal use only.** Playing YouTube this way is against YouTube's Terms of
> Service. Do not publish this to the App Store or Play Store, and do not
> distribute builds.

---

## Features

| | |
|---|---|
| **Opens straight into a feed** | Home is a YouTube-style feed, personalised from your local watch history and topped up with popular topics. Pull to refresh for a different mix. |
| **No ads** | No ad requests are ever made. |
| **Background playback** | Audio keeps playing when the app is minimised or the screen is locked, with lockscreen / Control Center controls. |
| **Picture-in-Picture** | Native iOS PiP from the player controls or the *PiP* chip. |
| **Search + paste a link** | Live query suggestions; pasting any `youtube.com` / `youtu.be` link opens that video directly. |
| **Offline downloads** | Save video or audio-only to the device. Downloaded videos play with no network and no data use — the player always prefers the local file. |
| **Local playlists** | Unlimited playlists plus a built-in *Watch later*. Play all / shuffle. |
| **Watch history & resume** | Every video remembers where you stopped and resumes there. |
| **Sleep timer** | 5 min – 1 hour, pauses playback when it fires. |
| **Speed control** | 0.25x – 2x, remembered between sessions. |
| **Audio-only mode** | Streams just the audio track — much less data when you are mostly listening. |

Everything is stored on-device in SQLite. There is no account, no sync and no
telemetry.

### There is no sign-in — and what that means

This app never touches your Google account. Consequences worth being clear on:

- Playlists and history here are **local to this device**. They are not your
  YouTube account's playlists or history, and nothing syncs either way.
- A video watched here will not appear in your youtube.com history.
- No subscriptions feed, comments, likes, subscribe button, Shorts, or casting.

Adding official Google OAuth would bring subscriptions and account playlists,
but **not** watch history — Google removed history from the YouTube Data API in
2016 and no third-party app can read it.

---

## Downloads

`⋮` on any video → **Download video** or **Download audio only**. Progress shows
in *Library → Downloads*.

- Files land in the app's Application Support directory, not user-visible
  storage, and are removed with the record when you delete a download.
- Transfers run **one at a time** — YouTube throttles concurrent downloads from
  a single manifest.
- A failed or interrupted transfer deletes its partial file rather than leaving
  a truncated video that would half-play. Restarting the app marks anything
  caught mid-transfer as failed so you can retry it deliberately.
- Once complete, `PlaybackController` plays the local file automatically. If the
  file goes missing, it silently falls back to streaming.
- **Video downloads are 360p** for the same reason streaming is — see below.
  Audio-only downloads are full quality and much smaller.

Verify downloads still work against live YouTube:

```bash
dart run tool/check_download.dart                  # 360p video
dart run tool/check_download.dart dQw4w9WgXcQ --audio
```

---

## Known limitation: video quality is capped at 360p

This is the one thing worth understanding before you build.

A single-URL player (iOS `AVPlayer`) needs a **combined** video+audio stream.
YouTube has almost entirely retired those: it now serves HD as *separate*
video-only and audio-only tracks, and the only combined stream still offered is
the legacy 360p MP4.

Measured against live YouTube with `tool/probe_clients.dart`:

| Client | Combined stream | Best video-only |
|---|---|---|
| `androidVr` | **360p** | 2160p |
| `androidSdkless` | **360p** | 2160p |
| `android` | **360p** | 2160p |
| `ios` | none | 2160p |
| `safari`, `mweb`, `tv`, … | none / error | — |

So today the app plays **360p video with full-quality audio**. Audio-only mode
and background playback are unaffected — those use the high-bitrate audio track
and are full quality.

Getting HD would mean playing the video-only and audio-only tracks together,
which needs a different playback engine (`media_kit` / libmpv). That engine
renders to a texture rather than an `AVPlayerLayer`, so it **cannot** do native
iOS Picture-in-Picture. It is a genuine trade-off:

- **Current build (AVPlayer):** 360p video, native PiP, lockscreen controls.
- **media_kit build:** up to 2160p video, no native iOS PiP, background controls
  need extra wiring.

Re-run `dart run tool/probe_clients.dart` occasionally — if YouTube starts
serving an HLS ladder again, the resolver already prefers it and quality will
improve with no code change.

---

## Building it

Flutter 3.44+ and Dart 3.12+.

```bash
flutter pub get
flutter analyze     # must be clean
flutter test        # unit tests for formatters + persistence
```

### iOS — requires a Mac

**iOS apps cannot be compiled on Windows or Linux.** Signing and building need
Xcode, which is macOS-only. You have three options:

**1. On a Mac**

```bash
open ios/Runner.xcworkspace
```

- Select the *Runner* target → *Signing & Capabilities*.
- Set *Team* to your personal Apple ID (a free account is fine).
- Change the *Bundle Identifier* to something unique, e.g.
  `com.yourname.aitube`.
- Confirm *Background Modes* is checked with **Audio, AirPlay, and Picture in
  Picture** — `Info.plist` already declares it, this just surfaces it in Xcode.

Then:

```bash
flutter build ios --release
# or, with the phone plugged in:
flutter run --release
```

With a free Apple ID the app is signed for **7 days** and must be reinstalled
after that. A paid Apple Developer account ($99/yr) extends it to a year.

**2. Cloud Mac CI (no Mac needed)**

[Codemagic](https://codemagic.io) has a free tier with macOS runners. Push this
repo, add an iOS workflow, supply your Apple ID signing credentials, and
download the `.ipa`. GitHub Actions `macos-latest` runners work the same way.

**3. Sideload the built `.ipa`**

Once you have an `.ipa` from either route, install it with
[AltStore](https://altstore.io) or [Sideloadly](https://sideloadly.io) from
Windows. These still re-sign with your Apple ID, so the same 7-day limit applies.

### Web — UI preview only, not a real target

The app builds and boots in Chrome so the interface can be reviewed without a
Mac or an Android SDK. **Video will not play there**, and that is expected:

- `better_player_plus` has no web implementation, so creating the player throws
  `MissingPluginException`. Everything around the player still renders.
- Browsers block cross-origin requests to YouTube, so the feed and search only
  return data if Chrome is launched with web security disabled.
- Downloads need `path_provider`, which has no web implementation.

```bash
flutter run -d chrome \
  --web-browser-flag "--disable-web-security" \
  --web-browser-flag "--user-data-dir=/tmp/aitube_chrome_profile"
```

The separate `--user-data-dir` is required — Chrome ignores
`--disable-web-security` on a normal profile.

Web support costs one dependency (`sqflite_common_ffi_web`) and one `kIsWeb`
branch in `AppDatabase.open()`, since there is no native SQLite in a browser.
Delete `web/` and that branch if you never want to preview again.

### Android

Needs the Android SDK (install Android Studio, then
`flutter config --android-sdk <path>`).

```bash
flutter build apk --release
```

Background playback, PiP and the media notification are all already declared in
`android/app/src/main/AndroidManifest.xml`.

---

## Project layout

```
lib/
  main.dart                        app bootstrap + providers
  src/
    core/
      format.dart                  view counts, timestamps, "3 days ago"
      theme.dart                   dark/light palette
    data/
      models.dart                  VideoBrief, playlists, history, downloads
      db.dart                      SQLite: history + playlists + downloads
      settings.dart                SharedPreferences-backed prefs
      yt_repository.dart           YouTube extraction, feed, stream resolution
      download_manager.dart        offline download queue + progress
    player/
      playback_controller.dart     the single app-wide player
    ui/
      root_shell.dart              bottom nav + mini player
      home_page.dart               the feed you land on
      search_page.dart             search / suggestions / paste a link
      watch_page.dart              player, metadata, actions, up next
      library_page.dart            downloads + history strip + playlists
      downloads_page.dart          offline library with progress
      playlist_detail_page.dart
      history_page.dart
      settings_page.dart
      widgets/                     tiles, mini player, bottom sheets
tool/
  check_streams.dart               "is playback still working?" diagnostic
  check_download.dart              "are downloads still working?" diagnostic
  probe_clients.dart               which API clients return combined streams
```

### How background playback actually works

Three things have to line up, and all three are already set:

1. `ios/Runner/Info.plist` declares `UIBackgroundModes: [audio]`. Without it
   iOS suspends `AVPlayer` the moment the app backgrounds, and PiP refuses to
   start.
2. `PlaybackController` builds its player with `handleLifecycle: false` and a
   no-op `playerVisibilityChangedBehavior`, so `better_player` does not pause
   on background or when the surface scrolls offscreen.
3. The data source sets `showNotification: true`. In `better_player` a visible
   notification means "the host app manages playback", which disables its
   remaining automatic pause paths and provides the lockscreen controls.

The player is also created with `autoDispose: false` and owned by
`PlaybackController` rather than any screen — that is what lets audio survive
backing out of the watch page, and what the mini player reattaches to.

---

## When playback breaks

YouTube changes its player endpoints every few months. It will break eventually.

```bash
dart run tool/check_streams.dart              # is extraction still working?
dart run tool/probe_clients.dart              # which clients still work?
flutter pub upgrade youtube_explode_dart      # usually the fix
```

If `check_streams.dart` is green but the app still fails, the problem is in
playback, not extraction. If it is red, wait for a `youtube_explode_dart`
release — that package is what tracks YouTube's changes.
