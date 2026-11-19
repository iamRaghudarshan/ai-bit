import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// YouTube links handed to the app from outside — a tap in WhatsApp or a
/// browser, or "Share → AI BIT" from anywhere, including the YouTube app.
///
/// Until this existed the app never told Android it could open a YouTube
/// link, so every one of them went to the YouTube app, which from inside AI
/// BIT reads as "some videos open in YouTube". The manifest now declares the
/// `youtu.be` / `youtube.com` / `vnd.youtube:` links and a plain-text SEND
/// filter; `MainActivity` hands the link over on this channel, both for the
/// intent that launched the app and for one arriving while it is running.
///
/// Android only. iOS cannot claim another site's `https://` links at all —
/// universal links need a file on youtube.com — so there the YouTube app
/// keeps them, and the Share sheet is the way in.
///
/// Two realities to know about Android 12+, where the test phone lives.
/// The YouTube app's links are *verified*, which means a tapped link opens
/// YouTube directly with no chooser as long as that app is allowed to open
/// them (Settings → Apps → YouTube → Open by default). AI BIT cannot verify
/// youtube.com, so it appears in the chooser only once the user turns that
/// off — a system rule, not something an app can change. **Share → AI BIT
/// works regardless**, which is why the SEND filter is the one that matters.
class IncomingLinks {
  IncomingLinks._();

  static const _channel = MethodChannel('ai.bit/incoming');

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// The link the app was launched with, if any. Asked once, at startup.
  static Future<String?> initial() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('initial');
    } catch (e) {
      debugPrint('AI BIT: could not read the launch link — $e');
      return null;
    }
  }

  /// Links arriving while the app is already running.
  static void listen(void Function(String link) onLink) {
    if (!isSupported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLink' && call.arguments is String) {
        onLink(call.arguments as String);
      }
    });
  }
}

/// The YouTube reference inside something shared or tapped, or null.
///
/// Shared text is rarely just a link — "Watch this! https://youtu.be/x" is
/// the common shape — so the first YouTube URL in it is taken. `vnd.youtube:`
/// is the YouTube app's own scheme, which some apps use for "open in
/// YouTube"; its payload is a bare video id. A tapped link arrives as itself.
String? youtubeReferenceIn(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  final appScheme = RegExp(r'^vnd\.youtube:(?://)?([\w-]{11})', caseSensitive: false)
      .firstMatch(trimmed);
  if (appScheme != null) return appScheme.group(1);

  final url = RegExp(
    r'https?://(?:[\w-]+\.)?(?:youtube\.com|youtu\.be|youtube-nocookie\.com)/\S+',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (url != null) {
    // Trailing punctuation from the sentence around it, not from the URL.
    return url.group(0)!.replaceFirst(RegExp(r'[).,!?\]]+$'), '');
  }
  return null;
}
