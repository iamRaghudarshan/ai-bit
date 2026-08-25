# Local patches to better_player_plus 1.3.4

This is a vendored copy of the published package, not a fork with its own
history. It exists for one reason: the plugin hard-disables the notification and
lock-screen skip buttons on both platforms, and exposes no configuration for
them. `BetterPlayerNotificationConfiguration` carries only a title, author,
image and channel name.

On iOS this could be worked around from outside the plugin, because
`MPRemoteCommandCenter` is a process-wide singleton that the app's own
`AppDelegate` can claim back — see `ios/Runner/AppDelegate.swift`. Android has no
such seam: the notification and the media session are both private to the
plugin, so the source itself has to change.

Re-apply these when upgrading. Every patch is marked `PATCH:` in the source.

## Android — `android/src/main/kotlin/uz/shs/better_player_plus/BetterPlayer.kt`

1. `setUseNextAction(false)` / `setUsePreviousAction(false)` became `true`, plus
   the compact-view variants so the buttons survive the collapsed notification.
2. `setPlayer(ForwardingPlayer(exoPlayer))` became `SkipReportingPlayer`, a new
   private class at the end of the file. The plugin hands ExoPlayer a single
   media item, so it has no next or previous of its own and
   `PlayerNotificationManager` greys the buttons out however they are
   configured. `SkipReportingPlayer` claims both commands as available and
   forwards each tap to Flutter instead of trying to seek.
3. `setAudioAttributes(exoPlayer, true)` passed `handleAudioFocus = false`, so
   ExoPlayer ignored audio focus: an incoming call ducked the audio while the
   video played on underneath and ran past the end of the call. Now `false`, so
   focus is handled and playback pauses and resumes with the call.
4. The media session advertised only `ACTION_SEEK_TO`. It now advertises
   `ACTION_SKIP_TO_NEXT` and `ACTION_SKIP_TO_PREVIOUS` as well, via the new
   `MEDIA_SESSION_ACTIONS` constant — without this the lock screen omits the
   buttons even when the notification shows them.

14. `buildMediaSource` inferred the content type with
   `lastPathSegment.split(".")[1]`, which throws IndexOutOfBoundsException on
   any URL whose last path segment has no dot — and a googlevideo stream URL
   has no file extension. Every progressive (non-HLS) video failed to start on
   Android with "IndexOutOfBoundsException: Index: 1, Size: 1". It now takes the
   text after the final dot when there is one and an empty string otherwise,
   which infers CONTENT_TYPE_OTHER — the correct progressive source. This is
   the Android counterpart of the iOS out-of-band MIME patch.

15. `setupMediaSession` was only called when entering PiP, and the media
   session token was never handed to the PlayerNotificationManager. So during
   ordinary background playback no session existed and the notification was a
   plain, controls-less one — the lock screen showed no play/pause or skip at
   all. `setupPlayerNotification` now creates the session if it does not exist, so
   the refresh handler and event listener have a live session to push playback
   state and metadata into — which is what the system's lock-screen media
   widget binds to. (setMediaSessionToken is not used: media3's overload wants
   a token type MediaSessionCompat does not provide.)

16. The media session's metadata only ever carried the duration — no title,
   channel or artwork. The lock-screen media widget renders those from the
   session metadata, so it showed a bare card or, on some launchers, nothing at
   all. `updateMediaSessionMetadata` now fills in title, channel and duration
   when playback starts and on every state change, and adds the artwork once
   the async image load produces a bitmap. This is what makes the Android lock
   screen match what iOS already shows.

## Dart

5. `VideoEventType` gained `skipToNext` and `skipToPrevious`
   (`lib/src/video_player/video_player_platform_interface.dart`).
6. `method_channel_video_player.dart` parses the two new event names.
7. `video_player.dart` gained `onSkipToNext` / `onSkipToPrevious` callbacks.
   These are one-off signals rather than state, so they cannot ride on `value`
   the way every other event here does.
8. `better_player_event_type.dart` gained matching `BetterPlayerEventType`
   entries, and `better_player_controller.dart` re-posts the callbacks as
   ordinary player events so a host app can listen for them alongside play and
   pause.

11b. `stopOtherUpdateListener` skipped the current player's own time observer
   and then wiped the dictionary, losing the handle without removing it. Each
   observer rewrites the now-playing title and artwork it captured once a
   second, so every video left one running and pressing next changed the lock
   screen only for a stale observer to change it straight back.

## iOS — `ios/.../better_player_plus/Sources/better_player_plus/BetterPlayer.swift`

9. `AVURLAsset` was built with headers only. `AVURLAssetOutOfBandMIMETypeKey` is
   now supplied when the data source carries a `videoExtension`, via a new
   `mimeType(forExtension:)` helper. AVURLAsset otherwise works the format out
   from the path extension, and a googlevideo audio URL has none — so every
   audio-only track failed with "Failed to load video: unknown error" while the
   same URL served fine to any other client. This is what makes the screen-off
   audio swap possible on videos with no HLS ladder. Sources with an extension
   or a recognised type are unaffected.

10. `setDataSource` now refreshes the now-playing info. It was only refreshed
   on an explicit `play` call, and autoplaying the next video starts playback
   inside the plugin without one — so the lock screen kept the previous
   video's title and artwork for the whole of the next one.

11. Now-playing artwork was cached in a dictionary keyed by the player's texture
   id. A host app that keeps one long-lived player — which is how background
   audio survives leaving the watch page — never changes that id, so the first
   video's artwork was cached under it and every later video reused it: the
   lock screen showed the first thumbnail for the rest of the session. It is
   keyed by image URL now, which also means a repeated thumbnail is not
   re-downloaded.

12. `setupPlayerNotification` runs for every data source and built a fresh
   `PlayerNotificationManager`, event listener and one-second refresh handler
   each time while leaving the previous set alive. Their adapters capture the
   title and artwork of the video they were built for, so the old ones kept
   rewriting the notification with the previous video's details, and a handler
   leaked per video. It now disposes the previous set first.

17. PiP could only be started by an explicit call, so swiping home mid-video
   just stopped the picture — the floating window people expect from YouTube
   and Safari never appeared unless they first tapped a button. iOS has a flag
   for this, `canStartPictureInPictureAutomaticallyFromInline`, but it only
   affects a controller that already exists while the video plays inline, and
   this plugin built its `AVPlayerLayer` at the moment PiP was requested —
   after the fact — because Flutter renders video into a texture, not a layer.
   A new `setAutomaticPictureInPicture(_:frame:)` therefore creates the layer
   up front and inserts it BEHIND Flutter's view: iOS refuses automatic PiP for
   a hidden or offscreen layer, but the texture draws over it so nothing
   changes visually. Guarded to iOS 14.2+, torn down on dispose, and left
   opt-in from Dart because it cannot be verified without a real device.


## Housekeeping

13. `analysis_options.yaml` included `package:analysis_lints`, which is not a
   dependency of this app and failed `flutter analyze` on a missing include. It
   now includes `flutter_lints`. This is vendored source we do not lint
   ourselves.

`example/` was dropped from the copy; nothing here builds it.
