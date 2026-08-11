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
3. The media session advertised only `ACTION_SEEK_TO`. It now advertises
   `ACTION_SKIP_TO_NEXT` and `ACTION_SKIP_TO_PREVIOUS` as well, via the new
   `MEDIA_SESSION_ACTIONS` constant — without this the lock screen omits the
   buttons even when the notification shows them.

## Dart

4. `VideoEventType` gained `skipToNext` and `skipToPrevious`
   (`lib/src/video_player/video_player_platform_interface.dart`).
5. `method_channel_video_player.dart` parses the two new event names.
6. `video_player.dart` gained `onSkipToNext` / `onSkipToPrevious` callbacks.
   These are one-off signals rather than state, so they cannot ride on `value`
   the way every other event here does.
7. `better_player_event_type.dart` gained matching `BetterPlayerEventType`
   entries, and `better_player_controller.dart` re-posts the callbacks as
   ordinary player events so a host app can listen for them alongside play and
   pause.

## Housekeeping

8. `analysis_options.yaml` included `package:analysis_lints`, which is not a
   dependency of this app and failed `flutter analyze` on a missing include. It
   now includes `flutter_lints`. This is vendored source we do not lint
   ourselves.

`example/` was dropped from the copy; nothing here builds it.
